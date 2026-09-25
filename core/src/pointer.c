#include "pointer.h"

#include <stdlib.h>

uint8_t* vrcPointerImageCreate(uint32_t width, uint32_t height, uint32_t xorBpp, const uint8_t* xorMask,
                               uint32_t xorMaskLength, const uint8_t* andMask, uint32_t andMaskLength,
                               const gdiPalette* palette)
{
    if (width == 0 || height == 0 || (xorBpp == 8 && !palette))
        return NULL;

    uint8_t* pixels = malloc((size_t)width * height * VRC_POINTER_BYTES_PER_PIXEL);
    if (!pixels)
        return NULL;
    if (!freerdp_image_copy_from_pointer_data(pixels, VRC_POINTER_FORMAT, width * VRC_POINTER_BYTES_PER_PIXEL, 0, 0,
                                              width, height, xorMask, xorMaskLength, andMask, andMaskLength, xorBpp,
                                              palette))
    {
        free(pixels);
        return NULL;
    }
    return pixels;
}
