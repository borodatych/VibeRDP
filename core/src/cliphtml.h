/*
 * HTML of the clipboard between the Mac and Windows
 * Windows keeps it as the registered format "HTML Format": a header of byte offsets, then UTF-8 HTML
 * with the copied part between comment markers; the Mac keeps plain HTML
 */

#ifndef VRC_CLIPHTML_H
#define VRC_CLIPHTML_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * HTML of the Mac to "HTML Format": the markers go around the content of <body>, or around all of it
 * when it has no body; the header gives the offsets, and a zero byte ends the data
 * *windows is allocated with malloc; false only when the memory runs out
 */
bool vrcHtmlToWindows(const char* html, size_t length, uint8_t** windows, size_t* windowsLength);

/*
 * "HTML Format" to HTML for the Mac: the part from StartHTML to EndHTML, which keeps the styles of the page,
 * or from StartFragment to EndFragment when the header gives no such part
 * Data without a header that starts as HTML is taken whole
 * *html is allocated with malloc and zero-terminated; false when the offsets point outside the data
 */
bool vrcHtmlFromWindows(const uint8_t* windows, size_t length, char** html, size_t* htmlLength);

#endif
