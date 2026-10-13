#include <lexbor/html/html.h>

/*
 * html-document-parse, extended to also drive the fragment-chunk API
 * (lxb_html_document_parse_fragment_chunk_*). Byte 0 selects the mode, byte 1
 * the fragment context element and chunk size; the rest is the HTML.
 */
static const lxb_tag_id_t contexts[] = {
    LXB_TAG_DIV, LXB_TAG_TABLE, LXB_TAG_TBODY, LXB_TAG_TR, LXB_TAG_SELECT,
    LXB_TAG_TITLE, LXB_TAG_TEXTAREA, LXB_TAG_TEMPLATE, LXB_TAG_BODY,
    LXB_TAG_HTML, LXB_TAG_HEAD, LXB_TAG_FRAMESET, LXB_TAG_P, LXB_TAG_SPAN,
    LXB_TAG_SCRIPT, LXB_TAG_STYLE
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

    lxb_tag_id_t tag = contexts[(data[1] >> 4) % (sizeof(contexts) / sizeof(contexts[0]))];
    size_t chunk = (data[1] & 0x0f) + 1;
    const uint8_t *html = data + 2;
    size_t size = length - 2;

    lxb_dom_element_t *element = lxb_dom_interface_element(
        lxb_html_interface_create(document, tag, LXB_NS_HTML));
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
