/*
 * Small pictures for the image tests of the clipboard, see pictures.h
 */

#include "pictures.h"

#include <stdlib.h>
#include <string.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

/* Blending over white rounds either way */
#define TOLERANCE 2

bool pictureEncodePng(const Picture* picture, uint8_t** png, size_t* length)
{
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CFDataRef pixels = CFDataCreate(kCFAllocatorDefault, (const UInt8*)picture->pixels,
                                    (CFIndex)(sizeof(Rgba) * picture->width * picture->height));
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixels);
    CGImageRef image = CGImageCreate(picture->width, picture->height, 8, 32, sizeof(Rgba) * picture->width, space,
                                     kCGImageAlphaLast | kCGBitmapByteOrder32Big, provider, NULL, false,
                                     kCGRenderingIntentDefault);
    CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(data, CFSTR("public.png"), 1, NULL);
    bool encoded = false;
    if (image && destination)
    {
        CGImageDestinationAddImage(destination, image, NULL);
        encoded = CGImageDestinationFinalize(destination);
    }
    if (encoded)
    {
        *length = (size_t)CFDataGetLength(data);
        *png = malloc(*length);
        encoded = *png != NULL;
        if (encoded)
            memcpy(*png, CFDataGetBytePtr(data), *length);
    }
    if (destination)
        CFRelease(destination);
    CFRelease(data);
    CGImageRelease(image);
    CGDataProviderRelease(provider);
    CFRelease(pixels);
    CGColorSpaceRelease(space);
    return encoded;
}

bool pictureDecodePng(const uint8_t* png, size_t length, Picture* picture)
{
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, png, (CFIndex)length);
    CGImageSourceRef source = CGImageSourceCreateWithData(data, NULL);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    bool decoded = false;
    if (image && CGImageGetWidth(image) * CGImageGetHeight(image) <= PICTURE_MAX_PIXELS)
    {
        picture->width = CGImageGetWidth(image);
        picture->height = CGImageGetHeight(image);
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context =
            CGBitmapContextCreate(picture->pixels, picture->width, picture->height, 8, sizeof(Rgba) * picture->width,
                                  space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        if (context)
        {
            CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat)picture->width, (CGFloat)picture->height), image);
            CGContextRelease(context);
            decoded = true;
        }
        CGColorSpaceRelease(space);
    }
    if (image)
        CGImageRelease(image);
    if (source)
        CFRelease(source);
    CFRelease(data);
    return decoded;
}

bool pictureNear(Rgba pixel, Rgba expected)
{
    return abs(pixel.r - expected.r) <= TOLERANCE && abs(pixel.g - expected.g) <= TOLERANCE &&
           abs(pixel.b - expected.b) <= TOLERANCE && abs(pixel.a - expected.a) <= TOLERANCE;
}
