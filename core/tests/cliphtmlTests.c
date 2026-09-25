/*
 * Clipboard HTML tests: plain HTML against "HTML Format", built from core/src/cliphtml.c directly
 * Usage: cliphtmlTests <test name>; CTest registers every test separately
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cliphtml.h"

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

/* The offsets a header of "HTML Format" gives, read the way a Windows program reads them */
typedef struct Offsets {
    long startHtml;
    long endHtml;
    long startFragment;
    long endFragment;
} Offsets;

static long offsetAfter(const char* data, const char* name)
{
    const char* found = strstr(data, name);
    return found ? strtol(found + strlen(name), NULL, 10) : -2;
}

static Offsets readOffsets(const char* data)
{
    const Offsets offsets = {
        offsetAfter(data, "StartHTML:"),
        offsetAfter(data, "EndHTML:"),
        offsetAfter(data, "StartFragment:"),
        offsetAfter(data, "EndFragment:"),
    };
    return offsets;
}

static bool sliceIs(const char* data, long start, long end, const char* expected)
{
    CHECK(end - start == (long)strlen(expected));
    CHECK(memcmp(data + start, expected, strlen(expected)) == 0);
    return true;
}

/* HTML without a body is wrapped, and the fragment is exactly what was copied */
static bool testWrapsHtmlWithoutBody(void)
{
    const char html[] = "<b>Жирный</b> текст";
    uint8_t* windows = NULL;
    size_t length = 0;

    CHECK(vrcHtmlToWindows(html, strlen(html), &windows, &length));
    const char* data = (const char*)windows;
    CHECK(windows[length - 1] == 0);
    CHECK(strncmp(data, "Version:0.9\r\n", 13) == 0);

    const Offsets offsets = readOffsets(data);
    CHECK(offsets.startHtml == 105);
    CHECK(offsets.endHtml == (long)length - 1);
    CHECK(sliceIs(data, offsets.startFragment, offsets.endFragment, html));
    CHECK(sliceIs(data, offsets.startHtml, offsets.endHtml,
                  "<html><body><!--StartFragment--><b>Жирный</b> текст<!--EndFragment--></body></html>"));
    free(windows);
    return true;
}

/* A whole page keeps its head and styles; the markers go inside its body, whatever the case of the tag */
static bool testMarksTheBodyOfAPage(void)
{
    const char html[] = "<html><head><style>p{color:red}</style></head><BODY class=\"x\"><p>a</p><p>b</p></Body></html>";
    uint8_t* windows = NULL;
    size_t length = 0;

    CHECK(vrcHtmlToWindows(html, strlen(html), &windows, &length));
    const char* data = (const char*)windows;
    const Offsets offsets = readOffsets(data);
    CHECK(sliceIs(data, offsets.startFragment, offsets.endFragment, "<p>a</p><p>b</p>"));
    CHECK(sliceIs(data, offsets.startHtml, offsets.endHtml,
                  "<html><head><style>p{color:red}</style></head><BODY class=\"x\"><!--StartFragment-->"
                  "<p>a</p><p>b</p><!--EndFragment--></Body></html>"));
    free(windows);
    return true;
}

/* A tag that only begins like body is not the body */
static bool testBodyNeedsTheWholeTagName(void)
{
    const char html[] = "<bodyguard>x</bodyguard>";
    uint8_t* windows = NULL;
    size_t length = 0;

    CHECK(vrcHtmlToWindows(html, strlen(html), &windows, &length));
    const char* data = (const char*)windows;
    const Offsets offsets = readOffsets(data);
    CHECK(sliceIs(data, offsets.startFragment, offsets.endFragment, html));
    free(windows);
    return true;
}

/* What the Mac sends comes back from Windows as the page around it */
static bool testRoundTrip(void)
{
    const char html[] = "<i>round</i>";
    uint8_t* windows = NULL;
    size_t length = 0;
    char* back = NULL;
    size_t backLength = 0;

    CHECK(vrcHtmlToWindows(html, strlen(html), &windows, &length));
    CHECK(vrcHtmlFromWindows(windows, length, &back, &backLength));
    CHECK(strcmp(back, "<html><body><!--StartFragment--><i>round</i><!--EndFragment--></body></html>") == 0);
    CHECK(backLength == strlen(back));
    free(back);
    free(windows);
    return true;
}

/* "HTML Format" as a Windows program writes it: other header lines, CRLF, a zero at the end */
static bool testReadsWindowsHtml(void)
{
    const char page[] = "<html><body>\r\n<!--StartFragment--><p>Привет</p><!--EndFragment-->\r\n</body></html>";
    const int fragmentStart = (int)(strstr(page, "<!--StartFragment-->") - page) + 20;
    const int fragmentEnd = (int)(strstr(page, "<!--EndFragment-->") - page);
    char data[512];
    /* The header below with ten digits for each offset */
    const int headerLength = 137;
    const int written =
        snprintf(data, sizeof(data),
                 "Version:0.9\r\nStartHTML:%010d\r\nEndHTML:%010d\r\nStartFragment:%010d\r\n"
                 "EndFragment:%010d\r\nSourceURL:https://example.com/\r\n%s",
                 headerLength, headerLength + (int)strlen(page), headerLength + fragmentStart,
                 headerLength + fragmentEnd, page);
    CHECK(written == headerLength + (int)strlen(page));

    char* html = NULL;
    size_t htmlLength = 0;
    CHECK(vrcHtmlFromWindows((const uint8_t*)data, (size_t)written + 1, &html, &htmlLength));
    CHECK(strcmp(html, page) == 0);
    free(html);
    return true;
}

/* Without the HTML part the fragment is taken; offsets outside the data are refused */
static bool testFragmentAndBrokenOffsets(void)
{
    const char body[] = "<p>frag</p>";
    char data[256];
    const int headerLength = 105;
    int written = snprintf(data, sizeof(data),
                           "Version:1.0\r\nStartHTML:-000000001\r\nEndHTML:-000000001\r\nStartFragment:%010d\r\n"
                           "EndFragment:%010d\r\n%s",
                           headerLength, headerLength + (int)strlen(body), body);
    CHECK(written == headerLength + (int)strlen(body));

    char* html = NULL;
    size_t htmlLength = 0;
    CHECK(vrcHtmlFromWindows((const uint8_t*)data, (size_t)written, &html, &htmlLength));
    CHECK(strcmp(html, body) == 0);
    free(html);

    written = snprintf(data, sizeof(data),
                       "Version:0.9\r\nStartHTML:0000000105\r\nEndHTML:0000009999\r\nStartFragment:0000000105\r\n"
                       "EndFragment:0000009999\r\n<p>x</p>");
    CHECK(!vrcHtmlFromWindows((const uint8_t*)data, (size_t)written, &html, &htmlLength));
    return true;
}

/* A program that puts plain HTML without a header still gets its page across */
static bool testHtmlWithoutHeader(void)
{
    const char data[] = "<p>raw</p>";
    char* html = NULL;
    size_t htmlLength = 0;

    CHECK(vrcHtmlFromWindows((const uint8_t*)data, sizeof(data), &html, &htmlLength));
    CHECK(strcmp(html, "<p>raw</p>") == 0);
    free(html);

    CHECK(!vrcHtmlFromWindows((const uint8_t*)"Version:0.9\r\n", 13, &html, &htmlLength));
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "wrapsHtmlWithoutBody", testWrapsHtmlWithoutBody },
    { "marksTheBodyOfAPage", testMarksTheBodyOfAPage },
    { "bodyNeedsTheWholeTagName", testBodyNeedsTheWholeTagName },
    { "roundTrip", testRoundTrip },
    { "readsWindowsHtml", testReadsWindowsHtml },
    { "fragmentAndBrokenOffsets", testFragmentAndBrokenOffsets },
    { "htmlWithoutHeader", testHtmlWithoutHeader },
};

int main(int argc, char* argv[])
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s <test name>\n", argv[0]);
        return 2;
    }
    for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); i++)
        if (strcmp(tests[i].name, argv[1]) == 0)
            return tests[i].run() ? 0 : 1;

    fprintf(stderr, "unknown test: %s\n", argv[1]);
    return 2;
}
