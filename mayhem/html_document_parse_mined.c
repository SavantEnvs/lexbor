#include <lexbor/html/html.h>

/*
 * html-document-parse, extended to also drive the fragment-chunk API
 * (lxb_html_document_parse_fragment_chunk_*). Byte 0 selects the mode, byte 1
 * the fragment context element and chunk size; the rest is the HTML.
 */
static const char *const contexts[] = {
    "div", "table", "tbody", "tr", "select", "title", "textarea", "template",
    "body", "html", "head", "frameset", "p", "span", "script", "style"
};

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t length)
{
    lxb_status_t status;
    lxb_html_document_t *document;

    if (length < 2) {
        return -1;
    }

    document = lxb_html_document_create();
    if (document == NULL) {
        return EXIT_FAILURE;
    }

    if (data[0] & 1) {
        status = lxb_html_document_parse(document, data + 1, length - 1);
        lxb_html_document_destroy(document);
        return status == LXB_STATUS_OK ? EXIT_SUCCESS : EXIT_FAILURE;
    }

    const char *name = contexts[(data[1] >> 4) % (sizeof(contexts) / sizeof(contexts[0]))];
    size_t chunk = (data[1] & 0x0f) + 1;
    const uint8_t *html = data + 2;
    size_t size = length - 2;

    lxb_dom_element_t *element = lxb_dom_document_create_element(&document->dom_document,
                                                                 (const lxb_char_t *) name,
                                                                 strlen(name), NULL);
    if (element == NULL) {
        lxb_html_document_destroy(document);
        return EXIT_FAILURE;
    }

    status = lxb_html_document_parse_fragment_chunk_begin(document, element);
    if (status != LXB_STATUS_OK) {
        lxb_html_document_destroy(document);
        return EXIT_FAILURE;
    }

    while (size > 0) {
        size_t n = size < chunk ? size : chunk;

        status = lxb_html_document_parse_fragment_chunk(document, html, n);
        if (status != LXB_STATUS_OK) {
            lxb_html_document_destroy(document);
            return EXIT_FAILURE;
        }

        html += n;
        size -= n;
    }

    lxb_html_document_parse_fragment_chunk_end(document);
    lxb_html_document_destroy(document);

    return EXIT_SUCCESS;
}
