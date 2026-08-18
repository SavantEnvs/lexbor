#!/usr/bin/env bash
#
# mayhem/test.sh -- RUN lexbor's upstream unit-test suite (built by mayhem/build.sh in
# build-tests/ via LEXBOR_BUILD_TESTS=ON, normal flags) PLUS 3 direct KAT probes, and emit one
# CTRF summary. exit 0 iff nothing failed.
#
# Two layers, and the SECOND is the load-bearing one for verify-repo's anti-reward-hack sabotage
# check (docs/netnew-worker-prompt.md 4):
#
#  1) Every unit-test binary under build-tests/test/lexbor/**, invoked DIRECTLY from bash (NOT
#     through `ctest`). Each is upstream's own known-answer test aggregator (test/unit/test.c's
#     test_run()): it asserts EXACT values (test_eq/test_ne/... over parsed trees, tokens,
#     decoded codepoints, ...) and prints its own
#         Failed: <F>
#         Total: <T>
#     summary lines, exiting EXIT_FAILURE iff F>0. We do NOT use `ctest`'s own pass/fail count as
#     the oracle: `ctest` itself only checks each child's EXIT CODE, and every one of these test
#     binaries is a plain dynamically-linked clang executable living under /mayhem -- so
#     verify-repo's LD_PRELOAD sabotage shim can neuter the binary's main() via its constructor
#     BEFORE it prints a single "Total:" line, and `ctest`/`meson test`-style runners would then
#     report 100% passed having run zero assertions (the same exit-code-only trap proven on
#     pkgconf). Running each binary directly and requiring its OWN "Failed:"/"Total:" lines to be
#     present fixes this: a neutered binary produces NO such lines, which this script treats as an
#     unconditional FAILURE for that binary (never a skip).
#
#  2) Direct KAT probes (mayhem/kat/{kat_html,kat_css,kat_encoding}.c, built by build.sh into
#     $SRC/kat_html, $SRC/kat_css, $SRC/kat_encoding -- normal flags, dynamically linked): fixed
#     input -> exact asserted stdout, compared here in bash so the comparison happens where
#     sabotage cannot hide behind any runner process.
#
# This script only RUNS things; mayhem/build.sh did the building.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

TESTROOT="$SRC/build-tests/test/lexbor"
if [ ! -d "$TESTROOT" ]; then
  echo "test.sh: $TESTROOT missing -- mayhem/build.sh must run first" >&2
  emit_ctrf "lexbor-unit+kat" 0 1
  exit 1
fi

PASSED=0
FAILED=0
BINARIES_RUN=0

# arg_name -> fixture path (relative to $SRC), mirroring the CMake `set(<arg_name>_arg ...)`
# lines in test/lexbor/{html,encoding,url,css}/CMakeLists.txt (upstream passes these as ctest's
# add_test() argv[1]; we pass them the same way when invoking directly).
declare -A FIXTURE_ARG=(
  [tokenizer_tokens]="$SRC/test/files/lexbor/html/tokenizer"
  [tree_builder]="$SRC/test/files/lexbor/html/html5_test"
  [tokenizer_html5lib_tests]="$SRC/test/files/lexbor/html/html5lib_tokenizer"
  [encoding_html5lib_tests]="$SRC/test/files/lexbor/html/html5lib_encoding"
  [serialize_ext]="$SRC/test/files/lexbor/html/serialize_ext"
  [buffer_big5]="$SRC/test/files/lexbor/encoding/big5_map_decode.txt"
  [buffer_euc_jp]="$SRC/test/files/lexbor/encoding/euc_jp_map_decode.txt"
  [buffer_euc_kr]="$SRC/test/files/lexbor/encoding/euc_kr_map_decode.txt"
  [buffer_iso_2022_jp]="$SRC/test/files/lexbor/encoding/iso_2022_jp_map_decode.txt"
  [buffer_shift_jis]="$SRC/test/files/lexbor/encoding/shift_jis_map_decode.txt"
  [buffer_gb18030]="$SRC/test/files/lexbor/encoding/gb18030_map_decode.txt"
  [single_big5]="$SRC/test/files/lexbor/encoding/big5_map_decode.txt"
  [single_euc_jp]="$SRC/test/files/lexbor/encoding/euc_jp_map_decode.txt"
  [single_euc_kr]="$SRC/test/files/lexbor/encoding/euc_kr_map_decode.txt"
  [single_iso_2022_jp]="$SRC/test/files/lexbor/encoding/iso_2022_jp_map_decode.txt"
  [single_shift_jis]="$SRC/test/files/lexbor/encoding/shift_jis_map_decode.txt"
  [single_gb18030]="$SRC/test/files/lexbor/encoding/gb18030_map_decode.txt"
  [parser]="$SRC/test/files/lexbor/url"
  [syntax_tokenizer]="$SRC/test/files/lexbor/css/syntax/tokenizer"
  [syntax_parser]="$SRC/test/files/lexbor/css/syntax/parser"
  [syntax_style]="$SRC/test/files/lexbor/css/lexbor.css"
  [declarations]="$SRC/test/files/lexbor/css/declarations"
)

# html/perf is a TIMING BENCHMARK (test/lexbor/html/perf.c) -- it takes "<dir> <repeat_count>",
# makes no correctness assertion at all (it just times repeated parses), and is excluded here
# deliberately (not a dropped oracle -- there is nothing behavioral to assert).
declare -A SKIP_BIN=( [perf]="benchmark tool, no correctness assertion" )

# ── 1) every upstream unit-test binary, invoked directly ──────────────────────────────────────
# lexbor's test/unit/test.c framework (TEST_INIT/TEST_ADD/TEST_RUN/TEST_RELEASE) is used by MOST
# unit-test binaries and prints a "Failed: <F>\nTotal: <T>" summary with T>0 -- rule (a) below.
# A handful of binaries drive their own ad-hoc fixture-directory walk (html5lib/WPT-style
# corpora) instead and print their OWN summary shape while STILL going through TEST_INIT/RUN/
# RELEASE for unrelated boilerplate (which emits a spurious, always-0 "Failed: 0\nTotal: 0"
# BEFORE their real "Results: N total, F failed" line -- seen empirically on
# html/serialize_ext and html/tree_builder) -- rules (b)/(c)/(d) below take priority over (a) for
# exactly this reason. The remainder (test/lexbor/{html/tokenizer_tokens,html/tree_builder's
# helper functions,unicode/idna,unicode/idna_codepoints}-style probes) have no TEST_ framework at
# all: they call `return EXIT_FAILURE` the instant one fixture mismatches and only reach their
# final print on full success -- rule (e) treats their exit code + substantial stdout (proof the
# sabotage shim did not neuter them before they did real work) as the oracle.
while IFS= read -r -d '' bin; do
  rel="${bin#"$TESTROOT"/}"          # e.g. "html/tokenizer_tokens" or "css/syntax/tokenizer"
  group="${rel%%/*}"                 # e.g. "html", "css", "encoding", "url", "core", ...
  after_group="${rel#"$group"/}"     # e.g. "tokenizer_tokens" or "syntax/tokenizer"
  arg_name="${after_group//\//_}"    # e.g. "tokenizer_tokens" or "syntax_tokenizer"

  if [ -n "${SKIP_BIN[$arg_name]+x}" ]; then
    echo "$rel: SKIPPED (${SKIP_BIN[$arg_name]})"
    continue
  fi

  BINARIES_RUN=$(( BINARIES_RUN + 1 ))

  if [ -n "${FIXTURE_ARG[$arg_name]+x}" ]; then
    out="$("$bin" "${FIXTURE_ARG[$arg_name]}" 2>&1)"; rc=$?
  else
    out="$("$bin" 2>&1)"; rc=$?
  fi

  p="" ; f=""

  # (b) "Results: <N> total, <F> failed[, <P> passed]" (serialize_ext, tree_builder,
  #     encoding_html5lib_tests, tokenizer/html5lib_tests).
  line="$(printf '%s\n' "$out" | grep -m1 -E 'Results: [0-9]+ total, [0-9]+ failed')"
  if [ -n "$line" ]; then
    t="$(printf '%s' "$line" | sed -E 's/.*Results: ([0-9]+) total.*/\1/')"
    f="$(printf '%s' "$line" | sed -E 's/.*total, ([0-9]+) failed.*/\1/')"
  fi

  # (c) "Total: <N>" + "Errors: <F>" as two SEPARATE lines (url/parser).
  if [ -z "$f" ]; then
    tline="$(printf '%s\n' "$out" | grep -m1 -E '^Total: [0-9]+$')"
    eline="$(printf '%s\n' "$out" | grep -m1 -E '^Errors: [0-9]+$')"
    if [ -n "$tline" ] && [ -n "$eline" ]; then
      t="$(printf '%s' "$tline" | sed -E 's/^Total: ([0-9]+)$/\1/')"
      f="$(printf '%s' "$eline" | sed -E 's/^Errors: ([0-9]+)$/\1/')"
    fi
  fi

  # (d) "Total <name> tests: <N>" (unicode/normalization_forms{,_code_points}) -- this line is
  #     only reached on a clean run (an early mismatch takes `return EXIT_FAILURE` first), so its
  #     mere presence means F=0; its absence (with rc!=0) falls through to rule (e).
  if [ -z "$f" ]; then
    line="$(printf '%s\n' "$out" | grep -m1 -E '^Total [A-Za-z]+ tests: [0-9]+$')"
    if [ -n "$line" ]; then
      t="$(printf '%s' "$line" | sed -E 's/^Total [A-Za-z]+ tests: ([0-9]+)$/\1/')"
      f=0
    fi
  fi

  # (a) the common case: test/unit/test.c's "Failed: <F>\nTotal: <T>" with T>0.
  if [ -z "$f" ]; then
    fa="$(printf '%s\n' "$out" | sed -n 's/^Failed: \([0-9]\+\)$/\1/p' | tail -1)"
    ta="$(printf '%s\n' "$out" | sed -n 's/^Total: \([0-9]\+\)$/\1/p' | tail -1)"
    if [ -n "$fa" ] && [ -n "$ta" ] && [ "$ta" -gt 0 ]; then
      f="$fa"; t="$ta"
    fi
  fi

  if [ -n "$f" ]; then
    p=$(( t - f ))
    PASSED=$(( PASSED + p ))
    FAILED=$(( FAILED + f ))
    echo "$rel: $p/$t passed"
    continue
  fi

  # (e) fallback for binaries with no TEST_ framework and no recognized summary line: their own
  #     code takes `return EXIT_FAILURE` immediately on a mismatch, so exit code IS a real
  #     assertion here -- but ONLY when paired with substantial stdout, so a sabotage-neutered
  #     binary (which prints NOTHING before _exit(0)) cannot pass by producing empty output.
  nlines="$(printf '%s\n' "$out" | grep -c .)"
  if [ "$rc" -eq 0 ] && [ "$nlines" -ge 3 ]; then
    PASSED=$(( PASSED + 1 ))
    echo "$rel: PASS (exit 0, $nlines lines of fixture-driven output, no framework summary line)"
  else
    echo "test.sh: FAIL $rel -- rc=$rc, $nlines lines of output (neutered, crashed, or a real mismatch)" >&2
    printf '%s\n' "$out" | tail -20 >&2
    FAILED=$(( FAILED + 1 ))
  fi
done < <(find "$TESTROOT" -type f -perm -u+x -print0 | sort -z)

[ "$BINARIES_RUN" -gt 0 ] || { echo "test.sh: found 0 test binaries under $TESTROOT -- build-tests is broken" >&2; emit_ctrf "lexbor-unit+kat" 0 1; exit 1; }
echo "=== ran $BINARIES_RUN upstream unit-test binaries: $PASSED passed, $FAILED failed ==="

# ── 2) direct KAT probes (sabotage-detecting; see header) ────────────────────────────────────
kat_expect_exact() {
  local label="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then
    echo "KAT PASS: $label"; PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label -- want [$expected] got [$got]" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

# kat_html: fixed HTML -> title text + text content of #greet (mayhem/kat/kat_html.c)
if [ -x "$SRC/kat_html" ]; then
  out="$("$SRC/kat_html" 2>&1)"
  title="$(printf '%s\n' "$out" | sed -n 's/^TITLE=//p')"
  text="$(printf '%s\n' "$out" | sed -n 's/^TEXT=//p')"
  kat_expect_exact "kat_html TITLE" "Lexbor KAT" "$title"
  kat_expect_exact "kat_html TEXT (#greet)" "Hello, World!" "$text"
else
  echo "test.sh: FAIL $SRC/kat_html missing" >&2; FAILED=$(( FAILED + 2 ))
fi

# kat_css: fixed CSS ".kat{color:red;width:12px}" -> exact token count + lossless echo of spans
if [ -x "$SRC/kat_css" ]; then
  out="$("$SRC/kat_css" 2>&1)"
  tokens="$(printf '%s\n' "$out" | sed -n 's/^TOKENS=//p')"
  echoed="$(printf '%s\n' "$out" | sed -n 's/^ECHO=//p')"
  kat_expect_exact "kat_css TOKENS" "12" "$tokens"
  kat_expect_exact "kat_css ECHO (lossless span reconstruction)" ".kat{color:red;width:12px}" "$echoed"
else
  echo "test.sh: FAIL $SRC/kat_css missing" >&2; FAILED=$(( FAILED + 2 ))
fi

# kat_encoding: windows-1251 bytes for "Привет" -> exact 6 codepoints
if [ -x "$SRC/kat_encoding" ]; then
  out="$("$SRC/kat_encoding" 2>&1)"
  ncp="$(printf '%s\n' "$out" | sed -n 's/^NCP=//p')"
  cps="$(printf '%s\n' "$out" | sed -n 's/^CP=//p' | paste -sd, -)"
  kat_expect_exact "kat_encoding NCP" "6" "$ncp"
  kat_expect_exact "kat_encoding codepoints (windows-1251 'Привет')" "0x041F,0x0440,0x0438,0x0432,0x0435,0x0442" "$cps"
else
  echo "test.sh: FAIL $SRC/kat_encoding missing" >&2; FAILED=$(( FAILED + 2 ))
fi

emit_ctrf "lexbor-ctest+kat" "$PASSED" "$FAILED"
