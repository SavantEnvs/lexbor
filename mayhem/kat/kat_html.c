/*
 * mayhem/kat/kat_html.c -- known-answer probe for the HTML tree-construction parser
 * (lxb_html_document_parse). Compiled with NORMAL flags (no sanitizer/DWARF3) against the
 * SAME clean, dynamically-linked liblexbor_static.a used by build-tests/, so verify-repo's
 * LD_PRELOAD sabotage shim can neuter this binary's main() -- a neutered run prints nothing,
 * which mayhem/test.sh's exact-string comparison catches (see test.sh header).
 *
 * Fixed input -> exact asserted values (checked in bash, not here, so the comparison happens
 * where sabotage cannot hide):
 *   TITLE = the <title> text content ("Lexbor KAT")
 *   TEXT  = the text content of the element whose id="greet" ("Hello, World!")
 */
#include <lexbor/html/html.h>
#include <lexbor/dom/interfaces/document.h>
#include <lexbor/dom/interfaces/element.h>
#include <stdio.h>

int
main(void)
{
    lxb_status_t status;
    lxb_html_document_t *document;
    lxb_dom_element_t *body, *p;
    const lxb_char_t *title, *text;
    size_t title_len, text_len;

    static const lxb_char_t html[] =
        "<html><head><title>Lexbor KAT</title></head>"
        "<body><p id=\"greet\">Hello, World!</p></body></html>";
    size_t html_len = sizeof(html) - 1;

    document = lxb_html_document_create();
    if (document == NULL) {
        fprintf(stderr, "kat_html: document create failed\n");
        return 1;
    }

    status = lxb_html_document_parse(document, html, html_len);
    if (status != LXB_STATUS_OK) {
        fprintf(stderr, "kat_html: parse failed: %d\n", (int) status);
        return 1;
    }

    title_len = 0;
    title = lxb_html_document_title(document, &title_len);
    printf("TITLE=%.*s\n", (int) title_len, title != NULL ? (const char *) title : "");

    body = lxb_dom_interface_element(document->body);
    if (body == NULL) {
        fprintf(stderr, "kat_html: no <body>\n");
        return 1;
    }

    p = lxb_dom_element_by_id(body, (const lxb_char_t *) "greet", 5);
    if (p == NULL) {
        fprintf(stderr, "kat_html: element #greet not found\n");
        return 1;
    }

    text_len = 0;
    text = lxb_dom_node_text_content(lxb_dom_interface_node(p), &text_len);
    printf("TEXT=%.*s\n", (int) text_len, text != NULL ? (const char *) text : "");

    lxb_html_document_destroy(document);

    return 0;
}
