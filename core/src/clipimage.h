/*
 * Images of the clipboard between PNG and the device-independent bitmaps of Windows, CF_DIB and CF_DIBV5
 * A bitmap is a .bmp file without its first 14 bytes: framed with them, it is decoded by ImageIO
 */

#ifndef VRC_CLIPIMAGE_H
#define VRC_CLIPIMAGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * PNG to CF_DIB: 24 bits a pixel, rows from the bottom up, transparent parts over white,
 * since programs that read CF_DIB ignore alpha
 * *dib is allocated with malloc; false when the PNG does not decode or the memory runs out
 */
bool vrcPngToDib(const uint8_t* png, size_t length, uint8_t** dib, size_t* dibLength);

/*
 * CF_DIB or CF_DIBV5 to PNG, whatever the depth, palette or masks of the bitmap
 * *png is allocated with malloc; false when the header is broken, the data is shorter than it says,
 * or the bitmap does not decode
 */
bool vrcDibToPng(const uint8_t* dib, size_t length, uint8_t** png, size_t* pngLength);

#endif
