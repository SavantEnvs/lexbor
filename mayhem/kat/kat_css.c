/*
 * mayhem/kat/kat_css.c -- known-answer probe for the CSS syntax tokenizer
 * (lxb_css_syntax_token / lxb_css_syntax_tokenizer_*, the same API mayhem/css-tokenizer
 * fuzzes). Compiled with NORMAL flags into a dynamically-linked binary (see kat_html.c).
 *
 * Fixed input ".kat{color:red;width:12px}" -> exact asserted values:
 *   TOKENS = the total number of tokens the tokenizer produces (including the terminal EOF)
 *   ECHO   = the raw source spans of every token concatenated back together -- the tokenizer
 *            is lossless over its own input, so this must equal the fixed input byte-for-byte.
 */
#include <lexbor/css/css.h>
#include <stdio.h>
#include <string.h>

static char outbuf[4096];
static size_t outlen = 0;
static int ntok = 0;

static void
collect(lxb_css_syntax_token_t *token)
{
    lxb_css_syntax_token_base_t *base;
    size_t len;

    /*
     * base->begin/length is the token's full raw source span -- for a DIMENSION token
     * (e.g. "12px") that already includes the unit, so (unlike examples/lexbor/css/syntax/
     * tokenizer/print_raw.c, which additionally appends lxb_css_syntax_token_dimension_string())
     * we do NOT re-append the dimension string here, or the unit would be duplicated.
     */
    base = lxb_css_syntax_token_base(token);
    len = base->length;

    if (outlen + len < sizeof(outbuf)) {
        memcpy(outbuf + outlen, base->begin, len);
        outlen += len;
    }

    ntok++;
}

int
main(void)
{
    lxb_css_syntax_token_t *token;
    lxb_css_syntax_tokenizer_t *tkz;
    lxb_css_syntax_token_type_t type;

    static const lxb_char_t css[] = ".kat{color:red;width:12px}";
    size_t css_len = sizeof(css) - 1;

    tkz = lxb_css_syntax_tokenizer_create();
    if (tkz == NULL) {
        fprintf(stderr, "kat_css: tokenizer create failed\n");
        return 1;
    }

    if (lxb_css_syntax_tokenizer_init(tkz) != LXB_STATUS_OK) {
        fprintf(stderr, "kat_css: tokenizer init failed\n");
        return 1;
    }

    lxb_css_syntax_tokenizer_buffer_set(tkz, css, css_len);

    do {
        token = lxb_css_syntax_token(tkz);
        if (token == NULL) {
            fprintf(stderr, "kat_css: tokenize failed\n");
            return 1;
        }

        collect(token);

        type = lxb_css_syntax_token_type(token);

        lxb_css_syntax_token_consume(tkz);
    }
    while (type != LXB_CSS_SYNTAX_TOKEN__EOF);

    lxb_css_syntax_tokenizer_destroy(tkz);

    printf("TOKENS=%d\n", ntok);
    printf("ECHO=%.*s\n", (int) outlen, outbuf);

    return 0;
}
