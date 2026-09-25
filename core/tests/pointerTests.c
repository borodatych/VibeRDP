/*
 * Pointer tests: the image the app gets from the masks a server sends, built from core/src/pointer.c directly
 * The pixels are B, G, R, A in memory with straight alpha, rows top to bottom: the app reads them just so
 * Usage: pointerTests <test name>; CTest registers every test separately
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pointer.h"

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

static bool pixelIs(const uint8_t* image, uint32_t width, uint32_t x, uint32_t y, uint8_t blue, uint8_t green,
                    uint8_t red, uint8_t alpha)
{
    const uint8_t* pixel = &image[(y * width + x) * VRC_POINTER_BYTES_PER_PIXEL];
    return pixel[0] == blue && pixel[1] == green && pixel[2] == red && pixel[3] == alpha;
}

/*
 * A 4x2 monochrome pointer: rows top to bottom, each padded to two bytes
 * The top row holds all four kinds: black, white, transparent and a pixel that inverts the screen
 */
static bool testMonochromePointer(void)
{
    const uint8_t xorMask[] = { 0x50, 0x00, 0x00, 0x00 };
    const uint8_t andMask[] = { 0x30, 0x00, 0xF0, 0x00 };
    uint8_t* image = vrcPointerImageCreate(4, 2, 1, xorMask, sizeof(xorMask), andMask, sizeof(andMask), NULL);
    CHECK(image != NULL);

    CHECK(pixelIs(image, 4, 0, 0, 0x00, 0x00, 0x00, 0xFF));
    CHECK(pixelIs(image, 4, 1, 0, 0xFF, 0xFF, 0xFF, 0xFF));
    CHECK(pixelIs(image, 4, 2, 0, 0x00, 0x00, 0x00, 0x00));
    /* macOS cannot invert what lies under a cursor: FreeRDP draws a checkerboard, black where x + y is odd */
    CHECK(pixelIs(image, 4, 3, 0, 0x00, 0x00, 0x00, 0xFF));
    for (uint32_t x = 0; x < 4; x++)
        CHECK(pixelIs(image, 4, x, 1, 0x00, 0x00, 0x00, 0x00));
    free(image);
    return true;
}

/*
 * A 1x2 pointer of 32 bits: its rows arrive bottom up, and a half transparent pixel keeps its colour as it is,
 * which is what straight alpha means
 */
static bool testColorPointerKeepsStraightAlpha(void)
{
    const uint8_t xorMask[] = {
        0x10, 0x20, 0x30, 0x80, /* The bottom row comes first */
        0xFF, 0x00, 0x00, 0xFF,
    };
    const uint8_t andMask[] = { 0x00, 0x00, 0x00, 0x00 };
    uint8_t* image = vrcPointerImageCreate(1, 2, 32, xorMask, sizeof(xorMask), andMask, sizeof(andMask), NULL);
    CHECK(image != NULL);

    CHECK(pixelIs(image, 1, 0, 0, 0xFF, 0x00, 0x00, 0xFF));
    CHECK(pixelIs(image, 1, 0, 1, 0x10, 0x20, 0x30, 0x80));
    free(image);
    return true;
}

/* An empty pointer has no image, and an 8-bit one has none without the palette of the session */
static bool testNoImageWithoutWhatItNeeds(void)
{
    const uint8_t mask[] = { 0x00, 0x00 };
    CHECK(vrcPointerImageCreate(0, 1, 1, mask, sizeof(mask), mask, sizeof(mask), NULL) == NULL);
    CHECK(vrcPointerImageCreate(1, 0, 1, mask, sizeof(mask), mask, sizeof(mask), NULL) == NULL);
    CHECK(vrcPointerImageCreate(1, 1, 8, mask, sizeof(mask), mask, sizeof(mask), NULL) == NULL);
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "monochromePointer", testMonochromePointer },
    { "colorPointerKeepsStraightAlpha", testColorPointerKeepsStraightAlpha },
    { "noImageWithoutWhatItNeeds", testNoImageWithoutWhatItNeeds },
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
