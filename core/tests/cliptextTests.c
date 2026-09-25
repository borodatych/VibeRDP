/*
 * Clipboard text tests: UTF-8 with LF against CF_UNICODETEXT, built from core/src/cliptext.c directly
 * Usage: cliptextTests <test name>; CTest registers every test separately
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cliptext.h"

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

/* The UTF-16LE bytes of the units, as CF_UNICODETEXT carries them */
static size_t unitsToBytes(const uint16_t* units, size_t count, uint8_t* bytes)
{
    for (size_t i = 0; i < count; i++)
    {
        bytes[2 * i] = (uint8_t)(units[i] & 0xFF);
        bytes[2 * i + 1] = (uint8_t)(units[i] >> 8);
    }
    return count * 2;
}

static bool toUnicodeIs(const char* utf8, size_t length, const uint16_t* expected, size_t expectedCount)
{
    uint8_t* unicode = NULL;
    size_t unicodeLength = 0;
    uint8_t bytes[256];

    CHECK(vrcTextToUnicode(utf8, length, &unicode, &unicodeLength));
    const size_t expectedLength = unitsToBytes(expected, expectedCount, bytes);
    CHECK(unicodeLength == expectedLength);
    CHECK(memcmp(unicode, bytes, expectedLength) == 0);
    free(unicode);
    return true;
}

static bool fromUnicodeIs(const uint16_t* units, size_t count, const char* expected)
{
    uint8_t bytes[256];
    char* utf8 = NULL;
    size_t utf8Length = 0;

    const size_t length = unitsToBytes(units, count, bytes);
    CHECK(vrcTextFromUnicode(bytes, length, &utf8, &utf8Length));
    CHECK(utf8Length == strlen(expected));
    CHECK(strcmp(utf8, expected) == 0);
    free(utf8);
    return true;
}

/* A lone LF becomes CRLF, a CRLF stays one, and the text ends with a zero unit */
static bool testLineEndsToWindows(void)
{
    static const uint16_t lf[] = { 'a', '\r', '\n', 'b', '\r', '\n', 0 };
    static const uint16_t crlf[] = { 'a', '\r', '\n', 'b', 0 };
    static const uint16_t cr[] = { 'a', '\r', 'b', 0 };
    static const uint16_t empty[] = { 0 };

    CHECK(toUnicodeIs("a\nb\n", 4, lf, 7));
    CHECK(toUnicodeIs("a\r\nb", 4, crlf, 5));
    CHECK(toUnicodeIs("a\rb", 3, cr, 4));
    CHECK(toUnicodeIs("", 0, empty, 1));
    return true;
}

/* Cyrillic takes one unit a letter, an emoji a surrogate pair */
static bool testBeyondAscii(void)
{
    static const uint16_t expected[] = { 0x041F, 0x0440, 0x0438, ' ', 0xD83D, 0xDC4B, 0 };
    CHECK(toUnicodeIs("\xD0\x9F\xD1\x80\xD0\xB8 \xF0\x9F\x91\x8B", 11, expected, 7));
    CHECK(fromUnicodeIs(expected, 7, "\xD0\x9F\xD1\x80\xD0\xB8 \xF0\x9F\x91\x8B"));
    return true;
}

/* Broken UTF-8 becomes U+FFFD: a stray continuation byte, an overlong form, a surrogate, a cut sequence */
static bool testBrokenUtf8(void)
{
    static const uint16_t stray[] = { 'a', 0xFFFD, 'b', 0 };
    static const uint16_t overlong[] = { 0xFFFD, 0xFFFD, 0 };
    static const uint16_t surrogate[] = { 0xFFFD, 0xFFFD, 0xFFFD, 0 };
    static const uint16_t cut[] = { 'a', 0xFFFD, 0xFFFD, 0 };

    CHECK(toUnicodeIs("a\x80" "b", 3, stray, 4));
    CHECK(toUnicodeIs("\xC0\xAF", 2, overlong, 3));
    CHECK(toUnicodeIs("\xED\xA0\x80", 3, surrogate, 4));
    CHECK(toUnicodeIs("a\xE2\x82", 3, cut, 4));
    return true;
}

/* CRLF becomes LF, a lone CR stays, and the text ends at the first zero unit */
static bool testLineEndsFromWindows(void)
{
    static const uint16_t crlf[] = { 'a', '\r', '\n', 'b', '\r', '\n' };
    static const uint16_t cr[] = { 'a', '\r', 'b', '\r' };
    static const uint16_t zero[] = { 'a', 'b', 0, 'c', 'd' };

    CHECK(fromUnicodeIs(crlf, 6, "a\nb\n"));
    CHECK(fromUnicodeIs(cr, 4, "a\rb\r"));
    CHECK(fromUnicodeIs(zero, 5, "ab"));
    CHECK(fromUnicodeIs(zero, 0, ""));
    return true;
}

/* A lone surrogate becomes U+FFFD, and an odd last byte is dropped */
static bool testBrokenUtf16(void)
{
    static const uint16_t loneHigh[] = { 0xD83D, 'a' };
    static const uint16_t loneLow[] = { 'a', 0xDC4B };
    static const uint16_t highAtEnd[] = { 'a', 0xD83D };

    CHECK(fromUnicodeIs(loneHigh, 2, "\xEF\xBF\xBD" "a"));
    CHECK(fromUnicodeIs(loneLow, 2, "a\xEF\xBF\xBD"));
    CHECK(fromUnicodeIs(highAtEnd, 2, "a\xEF\xBF\xBD"));

    static const uint8_t odd[] = { 'a', 0, 'b' };
    char* utf8 = NULL;
    size_t utf8Length = 0;
    CHECK(vrcTextFromUnicode(odd, sizeof(odd), &utf8, &utf8Length));
    CHECK(strcmp(utf8, "a") == 0);
    free(utf8);
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "lineEndsToWindows", testLineEndsToWindows },
    { "beyondAscii", testBeyondAscii },
    { "brokenUtf8", testBrokenUtf8 },
    { "lineEndsFromWindows", testLineEndsFromWindows },
    { "brokenUtf16", testBrokenUtf16 },
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
