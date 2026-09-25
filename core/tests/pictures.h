/*
 * Small pictures for the image tests of the clipboard: encoded to PNG and decoded back by ImageIO
 */

#ifndef VRC_TESTS_PICTURES_H
#define VRC_TESTS_PICTURES_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* The largest picture of the tests */
#define PICTURE_MAX_PIXELS 16

typedef struct Rgba {
    uint8_t r, g, b, a;
} Rgba;

/* Rows from the top down; straight alpha when encoded, premultiplied when decoded, as a bitmap context keeps it */
typedef struct Picture {
    size_t width;
    size_t height;
    Rgba pixels[PICTURE_MAX_PIXELS];
} Picture;

/* *png is allocated with malloc */
bool pictureEncodePng(const Picture* picture, uint8_t** png, size_t* length);
bool pictureDecodePng(const uint8_t* png, size_t length, Picture* picture);

/* Equal within the rounding of blending and colour matching */
bool pictureNear(Rgba pixel, Rgba expected);

#endif
