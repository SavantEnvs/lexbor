/*
 * mayhem/kat/kat_encoding.c -- known-answer probe for the character-encoding decoder
 * (lxb_encoding_decode_init / encoding->decode), the same API mayhem/encoding-decode fuzzes.
 * Compiled with NORMAL flags into a dynamically-linked binary (see kat_html.c).
 *
 * Fixed input: the 6 bytes CF F0 E8 E2 E5 F2, which is the Cyrillic word "Привет" encoded as
 * windows-1251. Decoding with LXB_ENCODING_WINDOWS_1251 must produce exactly the 6 codepoints
 * U+041F U+0440 U+0438 U+0432 U+0435 U+0442.
 */
#include <lexbor/encoding/encoding.h>
#include <stdio.h>

int
main(void)
{
    lxb_status_t status;
    const lxb_char_t *start, *end;
    const lxb_encoding_data_t *encoding;
    lxb_codepoint_t cp[32];
    lxb_encoding_decode_t decode = {0};
    size_t n;

    /* "Привет" in windows-1251 */
    static const lxb_char_t data[] = { 0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2 };

    start = data;
    end = data + sizeof(data);

    encoding = lxb_encoding_data(LXB_ENCODING_WINDOWS_1251);
    if (encoding == NULL) {
        fprintf(stderr, "kat_encoding: no windows-1251 encoding data\n");
        return 1;
    }

    status = lxb_encoding_decode_init(&decode, encoding, cp,
                                      sizeof(cp) / sizeof(cp[0]));
    if (status != LXB_STATUS_OK) {
        fprintf(stderr, "kat_encoding: decode_init failed: %d\n", (int) status);
        return 1;
    }

    status = encoding->decode(&decode, &start, end);
    if (status != LXB_STATUS_OK) {
        fprintf(stderr, "kat_encoding: decode failed: %d\n", (int) status);
        return 1;
    }

    n = lxb_encoding_decode_buf_used(&decode);
    printf("NCP=%zu\n", n);

    for (size_t i = 0; i < n; i++) {
        printf("CP=0x%04X\n", cp[i]);
    }

    return 0;
}
