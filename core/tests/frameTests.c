/*
 * Frame tests: the surface the engine draws into, built from core/src/frame.c directly
 * The framework exports only the VRC API, so the tests compile the module themselves
 * Usage: frameTests <test name>; CTest registers every test separately
 */

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "frame.h"

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

/* An odd width, so the row alignment has something to round */
static bool testSurfaceMatchesTheDesktop(void)
{
    IOSurfaceRef surface = vrcFrameSurfaceCreate(1023, 767);
    CHECK(surface != NULL);
    CHECK(IOSurfaceGetWidth(surface) == 1023);
    CHECK(IOSurfaceGetHeight(surface) == 767);
    CHECK(IOSurfaceGetPixelFormat(surface) == VRC_FRAME_PIXEL_FORMAT);
    CHECK(IOSurfaceGetBytesPerElement(surface) == VRC_FRAME_BYTES_PER_PIXEL);
    CHECK(IOSurfaceGetBytesPerRow(surface) >= 1023 * VRC_FRAME_BYTES_PER_PIXEL);
    printf("1023x767: %zu bytes per row\n", IOSurfaceGetBytesPerRow(surface));

    /* The engine writes through the base address: the whole last row must be reachable */
    CHECK(IOSurfaceLock(surface, 0, NULL) == KERN_SUCCESS);
    unsigned char* base = IOSurfaceGetBaseAddress(surface);
    CHECK(base != NULL);
    memset(base + IOSurfaceGetBytesPerRow(surface) * 766, 0xAB, 1023 * VRC_FRAME_BYTES_PER_PIXEL);
    CHECK(IOSurfaceUnlock(surface, 0, NULL) == KERN_SUCCESS);

    CFRelease(surface);
    return true;
}

static bool testEmptySizeHasNoSurface(void)
{
    CHECK(vrcFrameSurfaceCreate(0, 768) == NULL);
    CHECK(vrcFrameSurfaceCreate(1024, 0) == NULL);
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "surfaceMatchesTheDesktop", testSurfaceMatchesTheDesktop },
    { "emptySizeHasNoSurface", testEmptySizeHasNoSurface },
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
