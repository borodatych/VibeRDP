/*
 * Clipboard image tests: PNG against the bitmaps of Windows, built from core/src/clipimage.c directly
 * The PNGs come from ImageIO, the bitmaps are written byte by byte as Windows programs write them
 * Usage: clipimageTests <test name>; CTest registers every test separately
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "clipimage.h"
#include "pictures.h"

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

static uint32_t readLE32(const uint8_t* bytes)
{
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static void writeLE32(uint8_t* bytes, uint32_t value)
{
    for (int i = 0; i < 4; i++)
        bytes[i] = (uint8_t)(value >> (8 * i));
}

static bool pixelIs(const Picture* picture, size_t x, size_t y, Rgba expected)
{
    CHECK(pictureNear(picture->pixels[y * picture->width + x], expected));
    return true;
}

/* A channel after blending over white, which rounds either way */
static bool channelNear(uint8_t value, uint8_t expected)
{
    return pictureNear((Rgba){ value, 0, 0, 0 }, (Rgba){ expected, 0, 0, 0 });
}

static const Rgba red = { 255, 0, 0, 255 };
static const Rgba green = { 0, 255, 0, 255 };
static const Rgba blue = { 0, 0, 255, 255 };
static const Rgba white = { 255, 255, 255, 255 };
static const Rgba black = { 0, 0, 0, 255 };
static const Rgba yellow = { 255, 255, 0, 255 };

/* Three by two, each pixel its own colour, so a flip or a swap of channels shows */
static const Picture opaque = { 3, 2, { red, green, blue, white, black, yellow } };

/* A PNG becomes a 24-bit bitmap with rows from the bottom up, padded to four bytes, blue first */
static bool testPngToDibLayout(void)
{
    uint8_t* png = NULL;
    size_t pngLength = 0;
    CHECK(pictureEncodePng(&opaque, &png, &pngLength));

    uint8_t* dib = NULL;
    size_t length = 0;
    CHECK(vrcPngToDib(png, pngLength, &dib, &length));
    free(png);

    const size_t row = 12;
    CHECK(length == 40 + 2 * row);
    CHECK(readLE32(dib) == 40);
    CHECK(readLE32(dib + 4) == 3);
    CHECK(readLE32(dib + 8) == 2);
    CHECK(dib[12] == 1 && dib[13] == 0);
    CHECK(dib[14] == 24 && dib[15] == 0);
    CHECK(readLE32(dib + 16) == 0);
    CHECK(readLE32(dib + 20) == 2 * row);

    /* The first row of the bitmap is the bottom one: white, black, yellow */
    static const uint8_t bottom[] = { 255, 255, 255, 0, 0, 0, 0, 255, 255, 0, 0, 0 };
    static const uint8_t top[] = { 0, 0, 255, 0, 255, 0, 255, 0, 0, 0, 0, 0 };
    CHECK(memcmp(dib + 40, bottom, row) == 0);
    CHECK(memcmp(dib + 40 + row, top, row) == 0);
    free(dib);
    return true;
}

/* Transparency goes over white, since the programs that read CF_DIB ignore alpha */
static bool testTransparentGoesOverWhite(void)
{
    const Picture translucent = { 2, 1, { { 0, 0, 0, 0 }, { 255, 0, 0, 128 } } };
    uint8_t* png = NULL;
    size_t pngLength = 0;
    CHECK(pictureEncodePng(&translucent, &png, &pngLength));

    uint8_t* dib = NULL;
    size_t length = 0;
    CHECK(vrcPngToDib(png, pngLength, &dib, &length));
    free(png);
    CHECK(dib[40] == 255 && dib[41] == 255 && dib[42] == 255);
    CHECK(channelNear(dib[43], 127) && channelNear(dib[44], 127) && dib[45] == 255);
    free(dib);
    return true;
}

/* An opaque image comes back pixel for pixel through a bitmap */
static bool testRoundTrip(void)
{
    uint8_t* png = NULL;
    size_t pngLength = 0;
    CHECK(pictureEncodePng(&opaque, &png, &pngLength));
    uint8_t* dib = NULL;
    size_t dibLength = 0;
    CHECK(vrcPngToDib(png, pngLength, &dib, &dibLength));
    free(png);

    CHECK(vrcDibToPng(dib, dibLength, &png, &pngLength));
    free(dib);
    Picture back;
    const bool decoded = pictureDecodePng(png, pngLength, &back);
    free(png);
    CHECK(decoded);
    CHECK(back.width == 3 && back.height == 2);
    for (size_t i = 0; i < 6; i++)
        CHECK(pixelIs(&back, i % 3, i / 3, opaque.pixels[i]));
    return true;
}

/* A BITMAPINFOHEADER or a later one with the fields these tests vary; the rest is what Windows writes */
static void writeInfoHeader(uint8_t* dib, uint32_t size, int32_t width, int32_t height, uint8_t bitCount,
                            uint32_t compression, uint32_t colorsUsed)
{
    memset(dib, 0, size);
    writeLE32(dib, size);
    writeLE32(dib + 4, (uint32_t)width);
    writeLE32(dib + 8, (uint32_t)height);
    dib[12] = 1;
    dib[14] = bitCount;
    writeLE32(dib + 16, compression);
    writeLE32(dib + 32, colorsUsed);
}

static bool dibDecodesTo(const uint8_t* dib, size_t length, Picture* picture)
{
    uint8_t* png = NULL;
    size_t pngLength = 0;
    CHECK(vrcDibToPng(dib, length, &png, &pngLength));
    const bool decoded = pictureDecodePng(png, pngLength, picture);
    free(png);
    CHECK(decoded);
    return true;
}

/* 32 bits with BI_RGB, rows from the top down: the fourth byte is not alpha, Windows leaves it zero */
static bool testReadsTopDown32(void)
{
    uint8_t dib[40 + 2 * 4];
    writeInfoHeader(dib, 40, 1, -2, 32, 0, 0);
    static const uint8_t pixels[] = { 0, 0, 255, 0, 255, 0, 0, 0 };
    memcpy(dib + 40, pixels, sizeof(pixels));

    Picture picture;
    CHECK(dibDecodesTo(dib, sizeof(dib), &picture));
    CHECK(picture.width == 1 && picture.height == 2);
    CHECK(pixelIs(&picture, 0, 0, red));
    CHECK(pixelIs(&picture, 0, 1, blue));
    return true;
}

/* 8 bits with a palette of two colours: the palette sits between the header and the pixels */
static bool testReadsPalette(void)
{
    uint8_t dib[40 + 2 * 4 + 4];
    writeInfoHeader(dib, 40, 2, 1, 8, 0, 2);
    static const uint8_t palette[] = { 0, 255, 0, 0, 0, 0, 255, 0 };
    memcpy(dib + 40, palette, sizeof(palette));
    static const uint8_t pixels[] = { 1, 0, 0, 0 };
    memcpy(dib + 48, pixels, sizeof(pixels));

    Picture picture;
    CHECK(dibDecodesTo(dib, sizeof(dib), &picture));
    CHECK(pixelIs(&picture, 0, 0, red));
    CHECK(pixelIs(&picture, 1, 0, green));
    return true;
}

/* 16 bits with BI_BITFIELDS: three masks follow a BITMAPINFOHEADER */
static bool testReadsBitfields(void)
{
    uint8_t dib[40 + 12 + 4];
    writeInfoHeader(dib, 40, 2, 1, 16, 3, 0);
    writeLE32(dib + 40, 0xF800);
    writeLE32(dib + 44, 0x07E0);
    writeLE32(dib + 48, 0x001F);
    static const uint8_t pixels[] = { 0x00, 0xF8, 0x1F, 0x00 };
    memcpy(dib + 52, pixels, sizeof(pixels));

    Picture picture;
    CHECK(dibDecodesTo(dib, sizeof(dib), &picture));
    CHECK(pixelIs(&picture, 0, 0, red));
    CHECK(pixelIs(&picture, 1, 0, blue));
    return true;
}

/* CF_DIBV5 with an alpha mask keeps its transparency */
static bool testReadsV5Alpha(void)
{
    uint8_t dib[124 + 2 * 4];
    writeInfoHeader(dib, 124, 2, 1, 32, 3, 0);
    writeLE32(dib + 40, 0x00FF0000);
    writeLE32(dib + 44, 0x0000FF00);
    writeLE32(dib + 48, 0x000000FF);
    writeLE32(dib + 52, 0xFF000000);
    /* LCS_sRGB */
    writeLE32(dib + 56, 0x73524742);
    static const uint8_t pixels[] = { 0, 0, 255, 255, 0, 0, 0, 0 };
    memcpy(dib + 124, pixels, sizeof(pixels));

    Picture picture;
    CHECK(dibDecodesTo(dib, sizeof(dib), &picture));
    CHECK(pixelIs(&picture, 0, 0, red));
    CHECK(picture.pixels[1].a == 0);
    return true;
}

/* Broken data is refused, not read past its end */
static bool testBrokenData(void)
{
    uint8_t* out = NULL;
    size_t length = 0;
    static const uint8_t junk[] = { 1, 2, 3, 4, 5, 6, 7, 8 };
    CHECK(!vrcPngToDib(junk, sizeof(junk), &out, &length));
    CHECK(!vrcDibToPng(junk, 3, &out, &length));

    /* A header size no version of the header has */
    uint8_t dib[64];
    writeInfoHeader(dib, 40, 1, 1, 24, 0, 0);
    writeLE32(dib, 30);
    CHECK(!vrcDibToPng(dib, sizeof(dib), &out, &length));

    /* A header longer than the data, a palette past its end */
    writeInfoHeader(dib, 40, 1, 1, 24, 0, 0);
    CHECK(!vrcDibToPng(dib, 20, &out, &length));
    writeInfoHeader(dib, 40, 1, 1, 8, 0, 0);
    CHECK(!vrcDibToPng(dib, sizeof(dib), &out, &length));

    /* Pixels cut short */
    writeInfoHeader(dib, 40, 4, 4, 24, 0, 0);
    CHECK(!vrcDibToPng(dib, 44, &out, &length));
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "pngToDibLayout", testPngToDibLayout },
    { "transparentGoesOverWhite", testTransparentGoesOverWhite },
    { "imageRoundTrip", testRoundTrip },
    { "readsTopDown32", testReadsTopDown32 },
    { "readsPalette", testReadsPalette },
    { "readsBitfields", testReadsBitfields },
    { "readsV5Alpha", testReadsV5Alpha },
    { "brokenImageData", testBrokenData },
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
