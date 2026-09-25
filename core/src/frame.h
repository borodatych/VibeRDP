/*
 * The frame the engine draws into: an IOSurface, so the app shows it on the GPU without a copy
 * Pixels are BGRA in memory, which FreeRDP calls PIXEL_FORMAT_BGRX32; the alpha byte carries nothing
 */

#ifndef VRC_FRAME_H
#define VRC_FRAME_H

#include <stdint.h>

#include <IOSurface/IOSurfaceRef.h>

/* The 32-bit pixel format code of the surface, 'BGRA' */
#define VRC_FRAME_PIXEL_FORMAT 0x42475241u
#define VRC_FRAME_BYTES_PER_PIXEL 4u

/* A new surface of the given size in pixels, or NULL for an empty size or when the system refuses */
IOSurfaceRef vrcFrameSurfaceCreate(uint32_t width, uint32_t height);

#endif
