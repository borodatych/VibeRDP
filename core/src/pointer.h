/*
 * The server pointer as an image the app can show: BGRA with straight alpha, rows top to bottom
 * FreeRDP draws the XOR and AND masks of any depth into it; pixels meant to invert the screen become a checkerboard
 */

#ifndef VRC_POINTER_H
#define VRC_POINTER_H

#include <stdint.h>

#include <freerdp/codec/color.h>

/* The pixel format of the image: B, G, R, A in memory */
#define VRC_POINTER_FORMAT PIXEL_FORMAT_BGRA32
#define VRC_POINTER_BYTES_PER_PIXEL 4u

/*
 * The image of a pointer, width * height * 4 bytes the caller frees; NULL for an empty size or masks FreeRDP refuses
 * The palette serves 8-bit pointers and may be NULL for the others
 */
uint8_t* vrcPointerImageCreate(uint32_t width, uint32_t height, uint32_t xorBpp, const uint8_t* xorMask,
                               uint32_t xorMaskLength, const uint8_t* andMask, uint32_t andMaskLength,
                               const gdiPalette* palette);

#endif
