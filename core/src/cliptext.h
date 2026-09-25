/*
 * Text of the clipboard between the Mac and Windows: CF_UNICODETEXT is UTF-16LE with CRLF line ends and a
 * terminating zero, the Mac side is UTF-8 with LF
 * Malformed input never fails the conversion: a broken sequence becomes U+FFFD, as both systems show it
 */

#ifndef VRC_CLIPTEXT_H
#define VRC_CLIPTEXT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * UTF-8 to CF_UNICODETEXT: a lone LF becomes CRLF, a CRLF stays, and the zero terminator goes at the end
 * *unicode is allocated with malloc; false only when the memory runs out
 */
bool vrcTextToUnicode(const char* utf8, size_t length, uint8_t** unicode, size_t* unicodeLength);

/*
 * CF_UNICODETEXT to UTF-8: the text ends at the first zero character or at the end of the data,
 * CRLF becomes LF; an odd last byte is dropped
 * *utf8 is allocated with malloc and zero-terminated, *utf8Length does not count the zero
 */
bool vrcTextFromUnicode(const uint8_t* unicode, size_t length, char** utf8, size_t* utf8Length);

#endif
