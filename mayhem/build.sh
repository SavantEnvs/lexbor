#!/usr/bin/env bash
#
# mayhem/build.sh -- build the lexbor fuzz targets + the upstream test suite + the KAT probes.
#
#   /mayhem/css-tokenizer(-standalone)        sanitized + libFuzzer  -> target `css-tokenizer`
#   /mayhem/encoding-decode(-standalone)      sanitized + libFuzzer  -> target `encoding-decode`
#   /mayhem/html-document-parse(-standalone)  sanitized + libFuzzer  -> target `html-document-parse`
#   build-tests/                              normal flags           -> upstream ctest unit suite
#   $SRC/kat_html, $SRC/kat_css, $SRC/kat_encoding    normal flags    -> known-answer probes
#
# The three harnesses are upstream's own fuzzers (test/fuzzers/lexbor/{css/syntax,encoding,html}),
# linked against a sanitized static liblexbor so ASan/UBSan (+SanitizerCoverage) instrument the
# LIBRARY itself, not just the harness TU -- see the -fsanitize=fuzzer-no-link note below.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. Uses the base's build
# contract: CC/CXX, LIB_FUZZING_ENGINE, SANITIZER_FLAGS, DEBUG_FLAGS, SRC. cmake/clang/make already
# ship in the base -- lexbor has zero external deps for our purposes (no FetchContent/vcpkg/conan),
# so the air-gapped re-run (SPEC 6.5) needs no vendoring.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) -- must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# Always ensure the LIBRARY gets SanitizerCoverage instrumentation, regardless of the base image's
# default or an empty override -- without this, $LIB_FUZZING_ENGINE only instruments the harness TU
# and Mayhem would see 0 edges from liblexbor itself.
case "$SANITIZER_FLAGS" in
  *fuzzer-no-link*) ;;  # already present
  *) SANITIZER_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link" ;;
esac
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS COVERAGE_FLAGS

: "${SRC:=/mayhem}"
cd "$SRC"

# ── 1) Sanitized static library (the fuzzed code must be instrumented, not just the harness) ──
cmake -B build-fuzz \
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
      -DLEXBOR_BUILD_SHARED=OFF -DLEXBOR_BUILD_STATIC=ON .
cmake --build build-fuzz -j"$MAYHEM_JOBS"

LIB="$SRC/build-fuzz/liblexbor_static.a"
[ -f "$LIB" ] || { echo "FATAL: $LIB was not produced by the sanitized cmake build" >&2; exit 1; }
INC="-I$SRC/source"
DEFS="-DLEXBOR_STATIC -DLEXBOR_HAVE_FUZZER"

# Standalone driver object, built once, linked into every harness's -standalone binary. Compiled
# as C (-x c) so a future C++ harness would not mangle its LLVMFuzzerTestOneInput reference.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c -x c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

# ── 2) Each harness twice: libFuzzer binary -> /mayhem/<target>, standalone reproducer ─────────
# name -> (upstream harness source, output target name)
declare -A HARNESS=(
  [css-tokenizer]="$SRC/test/fuzzers/lexbor/css/syntax/tokenizer.c"
  [encoding-decode]="$SRC/test/fuzzers/lexbor/encoding/decode.c"
  [html-document-parse]="$SRC/test/fuzzers/lexbor/html/document_parse.c"
)

pids=()
for name in "${!HARNESS[@]}"; do
  src="${HARNESS[$name]}"
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $DEFS $INC "$src" "$LIB" -lm \
      -o "/mayhem/$name" &
  pids+=($!)
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS /tmp/standalone_main.o $DEFS $INC "$src" "$LIB" -lm \
      -o "/mayhem/$name-standalone" &
  pids+=($!)
done
rc=0; for p in "${pids[@]}"; do wait "$p" || rc=1; done
[ "$rc" -eq 0 ] || { echo "build.sh: a harness failed to build" >&2; exit 1; }

# ── 3) Per-target dictionary ─────────────────────────────────────────────────────────────────
# css-tokenizer's Mayhemfile references /mayhem/css-tokenizer.dict; a referenced-but-absent dict
# makes libFuzzer exit 1 at 0 edges, so copy it explicitly (never leave it unwired-but-present).
cp -f "$SRC/mayhem/css-tokenizer/css-tokenizer.dict" /mayhem/css-tokenizer.dict
echo "copied dictionary /mayhem/css-tokenizer.dict"

# ── 4) NORMAL-flags build: upstream's own ctest unit suite (mayhem/test.sh only RUNS it) ──────
# Independent tree, NO $SANITIZER_FLAGS/$DEBUG_FLAGS -- a clean functional-oracle build so a
# benign UB flagged by the sanitized build never false-fails the oracle. Static link is fine here
# (LEXBOR_BUILD_STATIC only affects how the TEST binaries link liblexbor -- each unit-test
# executable itself is a plain clang-produced ELF that still links libc dynamically, which is what
# lets verify-repo's LD_PRELOAD sabotage shim neuter it; see mayhem/test.sh).
cmake -B build-tests \
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" \
      -DLEXBOR_BUILD_TESTS=ON \
      -DLEXBOR_BUILD_SHARED=OFF -DLEXBOR_BUILD_STATIC=ON .
cmake --build build-tests -j"$MAYHEM_JOBS"

TESTLIB="$SRC/build-tests/liblexbor_static.a"
[ -f "$TESTLIB" ] || { echo "FATAL: $TESTLIB was not produced by the test cmake build" >&2; exit 1; }

# ── 5) KAT probes: exact known-answer values through the SAME clean, dynamically-linked build ──
# See mayhem/kat/*.c and mayhem/test.sh for what each asserts and why this layer exists (the
# ctest-runner-is-exit-code-only trap, SPEC 6.3 / docs/netnew-worker-prompt.md 4).
for kat in kat_html kat_css kat_encoding; do
  $CC -O0 -g $COVERAGE_FLAGS $INC "$SRC/mayhem/kat/$kat.c" "$TESTLIB" -lm -o "$SRC/$kat"
  if ! file "$SRC/$kat" | grep -q 'dynamically linked'; then
    echo "FATAL: $SRC/$kat is not dynamically linked -- the sabotage check could not neuter it," >&2
    echo "       which would make mayhem/test.sh a reward-hackable oracle." >&2
    file "$SRC/$kat" >&2
    exit 1
  fi
  echo "built $SRC/$kat (dynamically linked KAT probe)"
done

echo "build.sh complete:"
ls -la /mayhem/css-tokenizer /mayhem/encoding-decode /mayhem/html-document-parse \
       /mayhem/css-tokenizer-standalone /mayhem/encoding-decode-standalone \
       /mayhem/html-document-parse-standalone /mayhem/css-tokenizer.dict \
       "$SRC/kat_html" "$SRC/kat_css" "$SRC/kat_encoding"
