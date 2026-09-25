#include "frame.h"

#include <CoreFoundation/CoreFoundation.h>

static void setNumber(CFMutableDictionaryRef properties, CFStringRef key, int64_t value)
{
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
    CFDictionarySetValue(properties, key, number);
    CFRelease(number);
}

IOSurfaceRef vrcFrameSurfaceCreate(uint32_t width, uint32_t height)
{
    if (width == 0 || height == 0)
        return NULL;

    /* Rows aligned the way the system prefers them, so the GPU reads the memory in place */
    const size_t bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)width * VRC_FRAME_BYTES_PER_PIXEL);
    CFMutableDictionaryRef properties =
        CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!properties)
        return NULL;
    setNumber(properties, kIOSurfaceWidth, width);
    setNumber(properties, kIOSurfaceHeight, height);
    setNumber(properties, kIOSurfaceBytesPerElement, VRC_FRAME_BYTES_PER_PIXEL);
    setNumber(properties, kIOSurfaceBytesPerRow, (int64_t)bytesPerRow);
    setNumber(properties, kIOSurfacePixelFormat, VRC_FRAME_PIXEL_FORMAT);

    IOSurfaceRef surface = IOSurfaceCreate(properties);
    CFRelease(properties);
    return surface;
}
