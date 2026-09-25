/*
 * Images of the clipboard between PNG and the device-independent bitmaps of Windows
 * ImageIO decodes and encodes both; this module only frames a bitmap as a .bmp file and checks its sizes
 */

#include "clipimage.h"

#include <stdlib.h>
#include <string.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

/* The file header a .bmp starts with and the clipboard of Windows leaves out */
#define FILE_HEADER_SIZE 14u

/* The headers of a bitmap by their sizes: BITMAPCOREHEADER, BITMAPINFOHEADER and its later versions */
#define CORE_HEADER_SIZE 12u
#define INFO_HEADER_SIZE 40u
#define V5_HEADER_SIZE 124u

/* Compressions whose masks follow a BITMAPINFOHEADER: three for BI_BITFIELDS, four for BI_ALPHABITFIELDS */
#define BI_RGB_VALUE 0u
#define BI_BITFIELDS_VALUE 3u
#define BI_ALPHABITFIELDS_VALUE 6u

/* The resolution written into a bitmap: 72 dots an inch, the one of a screen on the Mac, in dots a metre */
#define DOTS_PER_METRE 2835u

/* The depth of the bitmaps this module writes */
#define DIB_BITS_PER_PIXEL 24u

static uint32_t readLE16(const uint8_t* bytes)
{
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8);
}

static uint32_t readLE32(const uint8_t* bytes)
{
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static void writeLE16(uint8_t* bytes, uint32_t value)
{
    bytes[0] = (uint8_t)value;
    bytes[1] = (uint8_t)(value >> 8);
}

static void writeLE32(uint8_t* bytes, uint32_t value)
{
    writeLE16(bytes, value);
    writeLE16(bytes + 2, value >> 16);
}

/*
 * The bytes the rows of an uncompressed bitmap take: each row is padded to four bytes
 * SIZE_MAX when the size does not fit, so no data is long enough for it
 */
static size_t pixelBytes(uint32_t width, uint32_t height, uint32_t bitCount)
{
    const uint64_t row = (((uint64_t)width * bitCount + 31) / 32) * 4;
    const uint64_t total = row * height;
    return total / (height ? height : 1) == row && total < SIZE_MAX ? (size_t)total : SIZE_MAX;
}

/*
 * Where the pixels of a bitmap start, counted from the start of its header: after the header, the masks and the palette
 * 0 when the header is not one Windows writes or the data is shorter than the header and the pixels it announces
 */
static size_t pixelOffset(const uint8_t* dib, size_t length)
{
    if (length < 4)
        return 0;
    const uint32_t headerSize = readLE32(dib);
    if (length < headerSize)
        return 0;

    size_t offset = headerSize;
    size_t pixels = 0;
    if (headerSize == CORE_HEADER_SIZE)
    {
        const uint32_t bitCount = readLE16(dib + 10);
        /* A core palette has three bytes an entry and always the full size */
        offset += bitCount <= 8 ? 3u * (1u << bitCount) : 0;
        pixels = pixelBytes(readLE16(dib + 4), readLE16(dib + 6), bitCount);
    }
    else if (headerSize >= INFO_HEADER_SIZE && headerSize <= V5_HEADER_SIZE)
    {
        const uint32_t width = readLE32(dib + 4);
        const int32_t height = (int32_t)readLE32(dib + 8);
        const uint32_t bitCount = readLE16(dib + 14);
        const uint32_t compression = readLE32(dib + 16);
        const uint32_t colorsUsed = readLE32(dib + 32);
        /* Later headers hold the masks themselves */
        if (headerSize == INFO_HEADER_SIZE && compression == BI_BITFIELDS_VALUE)
            offset += 3 * 4;
        else if (headerSize == INFO_HEADER_SIZE && compression == BI_ALPHABITFIELDS_VALUE)
            offset += 4 * 4;
        /* Depth 0 goes with JPEG or PNG inside the bitmap, which has no palette */
        if (bitCount > 0 && bitCount <= 8)
        {
            const uint32_t maxColors = 1u << bitCount;
            offset += 4u * (colorsUsed == 0 || colorsUsed > maxColors ? maxColors : colorsUsed);
        }
        else
            offset += 4u * (colorsUsed > 256 ? 0 : colorsUsed);
        /* Compressed pixels have no size to check; ImageIO stops at the end of the data */
        const bool uncompressed = compression == BI_RGB_VALUE || compression == BI_BITFIELDS_VALUE ||
                                  compression == BI_ALPHABITFIELDS_VALUE;
        const uint32_t rows = height < 0 ? (uint32_t)0 - (uint32_t)height : (uint32_t)height;
        pixels = uncompressed ? pixelBytes(width, rows, bitCount) : 0;
    }
    else
        return 0;
    return offset <= length && pixels <= length - offset ? offset : 0;
}

/*
 * The first image of encoded data, NULL when ImageIO cannot decode it
 * The image decodes lazily and keeps the data: the bytes must outlive it, or belong to the data
 */
static CGImageRef decodeImage(CFDataRef data)
{
    if (!data)
        return NULL;
    CGImageSourceRef source = CGImageSourceCreateWithData(data, NULL);
    if (!source)
        return NULL;
    CGImageRef image = CGImageSourceGetCount(source) > 0 ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    CFRelease(source);
    return image;
}

bool vrcDibToPng(const uint8_t* dib, size_t length, uint8_t** png, size_t* pngLength)
{
    const size_t offset = pixelOffset(dib, length);
    if (offset == 0 || length > UINT32_MAX - FILE_HEADER_SIZE)
        return false;

    uint8_t* file = malloc(FILE_HEADER_SIZE + length);
    if (!file)
        return false;
    file[0] = 'B';
    file[1] = 'M';
    writeLE32(file + 2, (uint32_t)(FILE_HEADER_SIZE + length));
    writeLE32(file + 6, 0);
    writeLE32(file + 10, (uint32_t)(FILE_HEADER_SIZE + offset));
    memcpy(file + FILE_HEADER_SIZE, dib, length);
    /* The data takes the file and frees it with the image */
    const CFIndex fileLength = (CFIndex)(FILE_HEADER_SIZE + length);
    CFDataRef fileData = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, file, fileLength, kCFAllocatorMalloc);
    if (!fileData)
    {
        free(file);
        return false;
    }
    CGImageRef image = decodeImage(fileData);
    CFRelease(fileData);
    if (!image)
        return false;

    bool encoded = false;
    CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
    CGImageDestinationRef destination =
        data ? CGImageDestinationCreateWithData(data, CFSTR("public.png"), 1, NULL) : NULL;
    if (destination)
    {
        CGImageDestinationAddImage(destination, image, NULL);
        encoded = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(image);

    if (encoded)
    {
        const size_t size = (size_t)CFDataGetLength(data);
        *png = malloc(size);
        encoded = *png != NULL;
        if (encoded)
        {
            memcpy(*png, CFDataGetBytePtr(data), size);
            *pngLength = size;
        }
    }
    if (data)
        CFRelease(data);
    return encoded;
}

bool vrcPngToDib(const uint8_t* png, size_t length, uint8_t** dib, size_t* dibLength)
{
    /* The image is drawn and released before this returns, so it may borrow the bytes of the caller */
    CFDataRef pngData = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, png, (CFIndex)length, kCFAllocatorNull);
    CGImageRef image = decodeImage(pngData);
    if (pngData)
        CFRelease(pngData);
    if (!image)
        return false;
    const size_t width = CGImageGetWidth(image);
    const size_t height = CGImageGetHeight(image);

    /* Rows of a bitmap are padded to four bytes; the whole must fit the 32-bit sizes of the header */
    const size_t dibRow = (width * 3 + 3) & ~(size_t)3;
    const size_t canvasRow = width * 4;
    if (width == 0 || height == 0 || width > INT32_MAX / 4 || height > INT32_MAX ||
        dibRow > (UINT32_MAX - INFO_HEADER_SIZE) / height || canvasRow > SIZE_MAX / height)
    {
        CGImageRelease(image);
        return false;
    }
    const size_t pixelsSize = dibRow * height;

    uint8_t* canvas = malloc(canvasRow * height);
    uint8_t* out = malloc(INFO_HEADER_SIZE + pixelsSize);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = canvas && out && space
                               ? CGBitmapContextCreate(canvas, width, height, 8, canvasRow, space,
                                                       kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big)
                               : NULL;
    if (space)
        CGColorSpaceRelease(space);
    if (!context)
    {
        free(canvas);
        free(out);
        CGImageRelease(image);
        return false;
    }
    /* Programs that read CF_DIB ignore alpha: transparent parts would turn black, so they go over white */
    const CGRect bounds = CGRectMake(0, 0, (CGFloat)width, (CGFloat)height);
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, bounds);
    CGContextDrawImage(context, bounds, image);
    CGContextRelease(context);
    CGImageRelease(image);

    memset(out, 0, INFO_HEADER_SIZE);
    writeLE32(out, INFO_HEADER_SIZE);
    writeLE32(out + 4, (uint32_t)width);
    /* A positive height: rows from the bottom up, the form every reader of CF_DIB takes */
    writeLE32(out + 8, (uint32_t)height);
    writeLE16(out + 12, 1);
    writeLE16(out + 14, DIB_BITS_PER_PIXEL);
    writeLE32(out + 16, BI_RGB_VALUE);
    writeLE32(out + 20, (uint32_t)pixelsSize);
    writeLE32(out + 24, DOTS_PER_METRE);
    writeLE32(out + 28, DOTS_PER_METRE);

    /* The canvas holds the top row first; a bitmap holds it last, and its pixels are blue, green, red */
    for (size_t y = 0; y < height; y++)
    {
        const uint8_t* from = canvas + (height - 1 - y) * canvasRow;
        uint8_t* to = out + INFO_HEADER_SIZE + y * dibRow;
        for (size_t x = 0; x < width; x++)
        {
            to[3 * x] = from[4 * x + 2];
            to[3 * x + 1] = from[4 * x + 1];
            to[3 * x + 2] = from[4 * x];
        }
        memset(to + 3 * width, 0, dibRow - 3 * width);
    }
    free(canvas);

    *dib = out;
    *dibLength = INFO_HEADER_SIZE + pixelsSize;
    return true;
}
