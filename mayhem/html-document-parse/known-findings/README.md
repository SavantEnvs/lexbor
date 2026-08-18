# html-document-parse: use-after-poison (container-overflow) in option attribute-change callback

Found by local fork-mode fuzzing of `/mayhem/html-document-parse` (upstream's own
`test/fuzzers/lexbor/html/document_parse.c` harness, unmodified) against ASan+UBSan during
integration QA. Real bug in upstream lexbor at commit `1c9970f5` (the `master` HEAD this repo is
pinned to as of this port) — not a harness artifact: it reproduces through the harness's plain
`lxb_html_document_parse()` entry point with no crafted API misuse.

## Reproducer

`crash-option-selected-in-foreign-content.html` (457 bytes; libFuzzer `-minimize_crash`-reduced
from an original 2196-byte fork-mode fuzzer finding). Replay it against the standalone
reproducer built by `mayhem/build.sh`:

```
./html-document-parse-standalone mayhem/html-document-parse/known-findings/crash-option-selected-in-foreign-content.html
```

## Crash

```
==ERROR: AddressSanitizer: use-after-poison on address 0x... (Container overflow)
    #0 lxb_html_option_attr_steps_change  source/lexbor/html/interfaces/option_element.c:240:30
    #1 lxb_dom_element_attr_append        source/lexbor/dom/interfaces/element.c:405:16
    #2 lxb_html_tree_append_attributes    source/lexbor/html/tree.c:497:9
    #3 lxb_html_tree_create_element_for_token  source/lexbor/html/tree.c:439:18
    #4 lxb_html_tree_insert_foreign_element     source/lexbor/html/tree.c:408:15
    #5 lxb_html_tree_insertion_mode_foreign_content_anything_else
                                          source/lexbor/html/tree/insertion_mode/foreign_content.c:99:15
    #6 lxb_html_tree_insertion_mode       source/lexbor/html/tree.c:297:12
```

ASan reports the poison kind as **Container overflow** (shadow byte `0xfc`), and this exact
14-artifact-in-45s fork-mode run found ONLY this one signature — but coverage kept climbing
throughout (`cov: 2331 -> 2474`, corpus 1700 -> 2450+), so per the integration playbook's
crash-vs-hang classification this is the HEALTHY case (finding a real bug while still exploring),
not a target to disable.

## Root cause (best-effort read of the code, not upstream-confirmed)

`lxb_html_option_attr_steps_change()` (`source/lexbor/html/interfaces/option_element.c:229-243`)
unconditionally casts its `lxb_dom_element_t *element` argument to
`lxb_html_option_element_t *` and, when the changed attribute is `selected`, writes
`option->selectedness = true` — a field that only exists in the *HTML* `<option>` interface
struct, past the end of the generic `lxb_dom_element_t` base.

The crash path goes through `lxb_html_tree_insertion_mode_foreign_content_anything_else()`
(`tree/insertion_mode/foreign_content.c`), i.e. the HTML tree builder is inside **foreign content**
(an SVG or MathML subtree) when it sees a start tag named `option` with a `selected` attribute.
lexbor's tag-to-interface/callback dispatch appears to be keyed on the tag's local name alone
(`option`), independent of the element's *namespace* — so a `<option selected>` created as a
*foreign* (SVG) element still gets wired to the HTML `option` element's `attr_steps_change`
callback, but is allocated with the SMALLER foreign/generic element layout (or a pool-allocated
region only container-annotated for the base struct's size). Setting `selected` then writes into
the poisoned "extra" bytes that a genuine `lxb_html_option_element_t` would occupy but this object
never had.

## Impact

A memory-safety bug (ASan container-overflow / effectively an out-of-bounds write) reachable by
parsing **untrusted HTML** through the public `lxb_html_document_parse()` API — no special build
flags or internal API needed. In a non-ASan production build this is a real OOB write of a `bool`
field into adjacent pool memory, not merely a diagnostic-only report.

## Suggested upstream fix (not applied here — SPEC forbids editing upstream files in this port)

Either (a) make `lxb_html_tree_create_element_for_token()` only allocate/attach the HTML
`option`-interface object (and its callback table) when the element's resolved namespace is
actually HTML, falling back to a generic foreign-element interface otherwise, or (b) have
`lxb_html_option_attr_steps_change()` verify `element->node.ns == LXB_NS_HTML` (or equivalent)
before touching `option->selectedness`.

## Notes for the next person

- Not masked/guarded in the harness — per the integration playbook, crashes are real findings and
  must not be suppressed. `mayhem/html-document-parse/document_parse.c`-equivalent harness (in
  `test/fuzzers/lexbor/html/document_parse.c`, upstream, unmodified) is used as-is.
- The reproducer is kept here, NOT under `mayhem/html-document-parse/testsuite/`, so it is never
  replayed as a starter seed (a crashing seed would fail every future Mayhem run's seed-replay
  step).
