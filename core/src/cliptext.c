/*
 * Text of the clipboard between UTF-8 with LF and CF_UNICODETEXT
 * The conversion is written out rather than taken from a library: it has to accept anything the other side
 * puts on its clipboard, and its handling of broken input has to be the same on every Mac
 */

#include "cliptext.h"

#include <stdlib.h>

#define REPLACEMENT_CHARACTER 0xFFFDu
#define HIGH_SURROGATE_FIRST 0xD800u
#define LOW_SURROGATE_FIRST 0xDC00u
#define SURROGATE_LAST 0xDFFFu
#define LAST_CODE_POINT 0x10FFFFu

/* The code point at *position, which moves past it; a malformed sequence yields U+FFFD and moves by one byte */
static uint32_t decodeUtf8(const uint8_t* text, size_t length, size_t* position)
{
    const size_t at = *position;
    const uint8_t first = text[at];
    size_t count = 0;
    uint32_t codePoint = 0;
    uint32_t lowest = 0;

    if (first < 0x80)
    {
        *position = at + 1;
        return first;
    }
    if (first >= 0xC2 && first <= 0xDF)
    {
        count = 1;
        codePoint = first & 0x1Fu;
        lowest = 0x80;
    }
    else if (first >= 0xE0 && first <= 0xEF)
    {
        count = 2;
        codePoint = first & 0x0Fu;
        lowest = 0x800;
    }
    else if (first >= 0xF0 && first <= 0xF4)
    {
        count = 3;
        codePoint = first & 0x07u;
        lowest = 0x10000;
    }

    if (count == 0 || length - at <= count)
    {
        *position = at + 1;
        return REPLACEMENT_CHARACTER;
    }
    for (size_t i = 1; i <= count; i++)
    {
        const uint8_t next = text[at + i];
        if ((next & 0xC0u) != 0x80u)
        {
            *position = at + 1;
            return REPLACEMENT_CHARACTER;
        }
        codePoint = (codePoint << 6) | (next & 0x3Fu);
    }
    /* Overlong forms, surrogates and values past Unicode are no characters */
    if (codePoint < lowest || codePoint > LAST_CODE_POINT ||
        (codePoint >= HIGH_SURROGATE_FIRST && codePoint <= SURROGATE_LAST))
    {
        *position = at + 1;
        return REPLACEMENT_CHARACTER;
    }
    *position = at + 1 + count;
    return codePoint;
}

static void putUnit(uint8_t* out, size_t* written, uint32_t unit)
{
    out[(*written)++] = (uint8_t)(unit & 0xFFu);
    out[(*written)++] = (uint8_t)(unit >> 8);
}

static void putUtf16(uint8_t* out, size_t* written, uint32_t codePoint)
{
    if (codePoint < 0x10000u)
    {
        putUnit(out, written, codePoint);
        return;
    }
    const uint32_t offset = codePoint - 0x10000u;
    putUnit(out, written, HIGH_SURROGATE_FIRST + (offset >> 10));
    putUnit(out, written, LOW_SURROGATE_FIRST + (offset & 0x3FFu));
}

bool vrcTextToUnicode(const char* utf8, size_t length, uint8_t** unicode, size_t* unicodeLength)
{
    const uint8_t* text = (const uint8_t*)utf8;

    /* At most four bytes for one byte of input: an LF becomes CR and LF, a stray byte becomes U+FFFD */
    if (length > (SIZE_MAX - 2) / 4)
        return false;
    uint8_t* out = malloc(length * 4 + 2);
    if (!out)
        return false;

    size_t written = 0;
    uint32_t previous = 0;
    for (size_t position = 0; position < length;)
    {
        const uint32_t codePoint = decodeUtf8(text, length, &position);
        if (codePoint == '\n' && previous != '\r')
            putUnit(out, &written, '\r');
        putUtf16(out, &written, codePoint);
        previous = codePoint;
    }
    putUnit(out, &written, 0);

    *unicode = out;
    *unicodeLength = written;
    return true;
}

/* The code point at unit *position, which moves past it; a lone surrogate yields U+FFFD */
static uint32_t decodeUtf16(const uint8_t* units, size_t count, size_t* position)
{
    const size_t at = *position;
    const uint32_t first = (uint32_t)units[2 * at] | ((uint32_t)units[2 * at + 1] << 8);

    *position = at + 1;
    if (first < HIGH_SURROGATE_FIRST || first > SURROGATE_LAST)
        return first;
    if (first >= LOW_SURROGATE_FIRST || at + 1 >= count)
        return REPLACEMENT_CHARACTER;

    const uint32_t second = (uint32_t)units[2 * at + 2] | ((uint32_t)units[2 * at + 3] << 8);
    if (second < LOW_SURROGATE_FIRST || second > SURROGATE_LAST)
        return REPLACEMENT_CHARACTER;
    *position = at + 2;
    return 0x10000u + ((first - HIGH_SURROGATE_FIRST) << 10) + (second - LOW_SURROGATE_FIRST);
}

static void putUtf8(char* out, size_t* written, uint32_t codePoint)
{
    if (codePoint < 0x80u)
    {
        out[(*written)++] = (char)codePoint;
    }
    else if (codePoint < 0x800u)
    {
        out[(*written)++] = (char)(0xC0u | (codePoint >> 6));
        out[(*written)++] = (char)(0x80u | (codePoint & 0x3Fu));
    }
    else if (codePoint < 0x10000u)
    {
        out[(*written)++] = (char)(0xE0u | (codePoint >> 12));
        out[(*written)++] = (char)(0x80u | ((codePoint >> 6) & 0x3Fu));
        out[(*written)++] = (char)(0x80u | (codePoint & 0x3Fu));
    }
    else
    {
        out[(*written)++] = (char)(0xF0u | (codePoint >> 18));
        out[(*written)++] = (char)(0x80u | ((codePoint >> 12) & 0x3Fu));
        out[(*written)++] = (char)(0x80u | ((codePoint >> 6) & 0x3Fu));
        out[(*written)++] = (char)(0x80u | (codePoint & 0x3Fu));
    }
}

bool vrcTextFromUnicode(const uint8_t* unicode, size_t length, char** utf8, size_t* utf8Length)
{
    size_t count = length / 2;

    for (size_t i = 0; i < count; i++)
        if (unicode[2 * i] == 0 && unicode[2 * i + 1] == 0)
        {
            count = i;
            break;
        }

    /* At most three bytes for one unit: a pair of surrogates takes four bytes for two units */
    if (count > (SIZE_MAX - 1) / 3)
        return false;
    char* out = malloc(count * 3 + 1);
    if (!out)
        return false;

    size_t written = 0;
    for (size_t position = 0; position < count;)
    {
        const uint32_t codePoint = decodeUtf16(unicode, count, &position);
        if (codePoint == '\r' && position < count && unicode[2 * position] == '\n' && unicode[2 * position + 1] == 0)
            continue;
        putUtf8(out, &written, codePoint);
    }
    out[written] = '\0';

    *utf8 = out;
    *utf8Length = written;
    return true;
}
