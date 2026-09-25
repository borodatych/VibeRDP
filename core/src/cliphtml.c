/*
 * HTML of the clipboard between plain HTML and "HTML Format"
 * The offsets of the header count bytes from the start of the data; ten digits each keep the header
 * the same length whatever the numbers are, so it can be written before the offsets are known
 */

#include "cliphtml.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define HEADER_FORMAT                                                                                       \
    "Version:0.9\r\nStartHTML:%010zu\r\nEndHTML:%010zu\r\nStartFragment:%010zu\r\nEndFragment:%010zu\r\n"
/* The length of the header above with every offset written out */
#define HEADER_LENGTH 105u

static const char startMarker[] = "<!--StartFragment-->";
static const char endMarker[] = "<!--EndFragment-->";
static const char openWrap[] = "<html><body>";
static const char closeWrap[] = "</body></html>";

/* Whether text at position starts with the ASCII word, whatever the case */
static bool startsWithIgnoringCase(const char* text, size_t length, size_t position, const char* word)
{
    const size_t wordLength = strlen(word);
    if (length - position < wordLength)
        return false;
    for (size_t i = 0; i < wordLength; i++)
        if (tolower((unsigned char)text[position + i]) != word[i])
            return false;
    return true;
}

/* A tag name ends where a space, a slash or the end of the tag follows it */
static bool endsTagName(const char* text, size_t length, size_t position)
{
    return position >= length || text[position] == '>' || text[position] == '/' ||
           isspace((unsigned char)text[position]);
}

/* The span of the content of <body>: after its opening tag and up to the last closing one; false without both */
static bool findBody(const char* html, size_t length, size_t* start, size_t* end)
{
    size_t open = length;
    for (size_t i = 0; i < length && open == length; i++)
        if (startsWithIgnoringCase(html, length, i, "<body") && endsTagName(html, length, i + 5))
            open = i;
    if (open == length)
        return false;

    const char* close = memchr(html + open, '>', length - open);
    if (!close)
        return false;
    *start = (size_t)(close - html) + 1;

    for (size_t i = length; i > *start; i--)
        if (startsWithIgnoringCase(html, length, i - 1, "</body") && endsTagName(html, length, i + 5))
        {
            *end = i - 1;
            return true;
        }
    return false;
}

static void append(uint8_t* out, size_t* written, const void* data, size_t length)
{
    memcpy(out + *written, data, length);
    *written += length;
}

bool vrcHtmlToWindows(const char* html, size_t length, uint8_t** windows, size_t* windowsLength)
{
    size_t bodyStart = 0;
    size_t bodyEnd = 0;
    const bool body = findBody(html, length, &bodyStart, &bodyEnd);
    const size_t wrapping = body ? 0 : strlen(openWrap) + strlen(closeWrap);
    const size_t markers = strlen(startMarker) + strlen(endMarker);

    if (length > SIZE_MAX - HEADER_LENGTH - wrapping - markers - 1)
        return false;
    const size_t total = HEADER_LENGTH + wrapping + markers + length;
    uint8_t* out = malloc(total + 1);
    if (!out)
        return false;

    size_t written = HEADER_LENGTH;
    size_t fragmentStart = 0;
    size_t fragmentEnd = 0;
    if (body)
    {
        append(out, &written, html, bodyStart);
        append(out, &written, startMarker, strlen(startMarker));
        fragmentStart = written;
        append(out, &written, html + bodyStart, bodyEnd - bodyStart);
        fragmentEnd = written;
        append(out, &written, endMarker, strlen(endMarker));
        append(out, &written, html + bodyEnd, length - bodyEnd);
    }
    else
    {
        append(out, &written, openWrap, strlen(openWrap));
        append(out, &written, startMarker, strlen(startMarker));
        fragmentStart = written;
        append(out, &written, html, length);
        fragmentEnd = written;
        append(out, &written, endMarker, strlen(endMarker));
        append(out, &written, closeWrap, strlen(closeWrap));
    }

    char header[HEADER_LENGTH + 1];
    const int headerLength =
        snprintf(header, sizeof(header), HEADER_FORMAT, (size_t)HEADER_LENGTH, written, fragmentStart, fragmentEnd);
    if (headerLength != (int)HEADER_LENGTH)
    {
        free(out);
        return false;
    }
    memcpy(out, header, HEADER_LENGTH);
    out[written] = 0;

    *windows = out;
    *windowsLength = written + 1;
    return true;
}

/* The value of a header line "Name:number"; -1 as Windows writes it for a part that is absent */
static bool headerValue(const char* line, size_t length, const char* name, long long* value)
{
    const size_t nameLength = strlen(name);
    if (length <= nameLength || strncmp(line, name, nameLength) != 0 || line[nameLength] != ':')
        return false;

    char digits[24];
    const size_t digitsLength = length - nameLength - 1;
    if (digitsLength == 0 || digitsLength >= sizeof(digits))
        return false;
    memcpy(digits, line + nameLength + 1, digitsLength);
    digits[digitsLength] = '\0';
    char* end = NULL;
    const long long parsed = strtoll(digits, &end, 10);
    if (end == digits || *end != '\0')
        return false;
    *value = parsed;
    return true;
}

static bool copyOut(const uint8_t* data, size_t start, size_t end, char** html, size_t* htmlLength)
{
    /* A zero at the end belongs to the clipboard data, not to the page */
    while (end > start && data[end - 1] == 0)
        end--;
    char* out = malloc(end - start + 1);
    if (!out)
        return false;
    memcpy(out, data + start, end - start);
    out[end - start] = '\0';
    *html = out;
    *htmlLength = end - start;
    return true;
}

bool vrcHtmlFromWindows(const uint8_t* windows, size_t length, char** html, size_t* htmlLength)
{
    long long startHtml = -1;
    long long endHtml = -1;
    long long startFragment = -1;
    long long endFragment = -1;
    bool header = false;

    /* The header is lines of "Name:value" before the first tag */
    const char* text = (const char*)windows;
    size_t position = 0;
    while (position < length && text[position] != '<')
    {
        size_t lineEnd = position;
        while (lineEnd < length && text[lineEnd] != '\r' && text[lineEnd] != '\n')
            lineEnd++;
        const char* line = text + position;
        const size_t lineLength = lineEnd - position;
        header |= headerValue(line, lineLength, "StartHTML", &startHtml) ||
                  headerValue(line, lineLength, "EndHTML", &endHtml) ||
                  headerValue(line, lineLength, "StartFragment", &startFragment) ||
                  headerValue(line, lineLength, "EndFragment", &endFragment);
        position = lineEnd;
        while (position < length && (text[position] == '\r' || text[position] == '\n'))
            position++;
    }

    if (!header)
        return position == 0 && length > 0 && copyOut(windows, 0, length, html, htmlLength);
    if (startHtml >= 0 && endHtml > startHtml && (unsigned long long)endHtml <= length)
        return copyOut(windows, (size_t)startHtml, (size_t)endHtml, html, htmlLength);
    if (startFragment >= 0 && endFragment > startFragment && (unsigned long long)endFragment <= length)
        return copyOut(windows, (size_t)startFragment, (size_t)endFragment, html, htmlLength);
    return false;
}
