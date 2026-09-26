/*
 * H.264 tests: the VideoToolbox decoder that VibeRDP adds to FreeRDP, through the codec API of FreeRDP
 * The encoder of VideoToolbox makes the streams from the YUV that FreeRDP itself computes
 * The streams come out in Annex B form, as RDPGFX carries them, and decode back to pixels to compare with the source
 * Usage: h264Tests <test name>; CTest registers every test separately
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>

#include <freerdp/channels/rdpgfx.h>
#include <freerdp/codec/color.h>
#include <freerdp/codec/h264.h>
#include <freerdp/primitives.h>

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

#define BYTES_PER_PIXEL 4u
/* The side of the colored blocks of the test picture: whole macroblocks, so their edges stay sharp */
#define BLOCK_SIDE 64u
/* How far the blocks move between frames: a P-frame then carries motion, not a copy */
#define BLOCK_STEP 16u
/* Enough bits that the encoder spends them on detail, whatever the size of the picture */
#define ENCODER_BITRATE 40000000
#define FRAMES_PER_SECOND 30
/* Frames of a round trip: one key frame and P-frames after it */
#define ROUND_TRIP_FRAMES 4

static const uint8_t startCode[] = { 0, 0, 0, 1 };
/* The low five bits of the first byte of a NAL unit give its type; 5 is a slice of an IDR picture */
#define NAL_TYPE_MASK 0x1F
#define NAL_TYPE_IDR 5

/* The picture as a plain buffer of BGRX pixels, as the surfaces of the graphics pipeline hold it */
typedef struct Canvas {
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint8_t* pixels;
} Canvas;

/* Planes of 4:2:0 YUV at full picture size, as FreeRDP computes them */
typedef struct Planes {
    uint8_t* data[3];
    uint32_t stride[3];
} Planes;

/* An encoder of VideoToolbox and the last frame it made, in Annex B form */
typedef struct Encoder {
    VTCompressionSessionRef session;
    uint32_t width;
    uint32_t height;
    int64_t frames;
    OSStatus status;
    uint8_t* stream;
    size_t length;
    size_t capacity;
} Encoder;

static bool canvasInit(Canvas* picture, uint32_t width, uint32_t height)
{
    picture->width = width;
    picture->height = height;
    picture->stride = width * BYTES_PER_PIXEL;
    picture->pixels = calloc(height, picture->stride);
    return picture->pixels != NULL;
}

static void canvasFree(Canvas* picture)
{
    free(picture->pixels);
    picture->pixels = NULL;
}

static bool planesInit(Planes* planes, uint32_t width, uint32_t height)
{
    const uint32_t chromaWidth = (width + 1) / 2;
    const uint32_t chromaHeight = (height + 1) / 2;
    const uint32_t strides[3] = { width, chromaWidth, chromaWidth };
    const uint32_t rows[3] = { height, chromaHeight, chromaHeight };

    for (int plane = 0; plane < 3; plane++)
    {
        planes->stride[plane] = strides[plane];
        planes->data[plane] = calloc(rows[plane], strides[plane]);
        if (!planes->data[plane])
            return false;
    }
    return true;
}

static void planesFree(Planes* planes)
{
    for (int plane = 0; plane < 3; plane++)
        free(planes->data[plane]);
}

static void setPixel(Canvas* picture, uint32_t x, uint32_t y, uint8_t red, uint8_t green, uint8_t blue)
{
    uint8_t* pixel = picture->pixels + (size_t)y * picture->stride + (size_t)x * BYTES_PER_PIXEL;
    pixel[0] = blue;
    pixel[1] = green;
    pixel[2] = red;
    pixel[3] = 0xFF;
}

/*
 * A grey gradient with rows of colored blocks over it; the blocks move with the frame number
 * Eight colors, far apart in hue: swapped chroma planes or channels turn one into another
 */
static void drawBlocks(Canvas* picture, uint32_t frame)
{
    static const uint8_t colors[8][3] = { { 220, 40, 40 },  { 40, 200, 60 },  { 50, 70, 230 },
                                          { 230, 210, 40 }, { 200, 60, 200 }, { 40, 200, 210 },
                                          { 240, 240, 240 }, { 20, 20, 20 } };

    for (uint32_t y = 0; y < picture->height; y++)
    {
        for (uint32_t x = 0; x < picture->width; x++)
        {
            const uint32_t column = (x + frame * BLOCK_STEP) / BLOCK_SIDE;
            const uint32_t row = y / BLOCK_SIDE;
            if (row % 2 == 1)
            {
                const uint8_t* color = colors[(column + row) % 8];
                setPixel(picture, x, y, color[0], color[1], color[2]);
            }
            else
            {
                const uint8_t grey = (uint8_t)((x * 255u) / picture->width);
                setPixel(picture, x, y, grey, grey, grey);
            }
        }
    }
}

/* Single columns of red and blue side by side: chroma detail that 4:2:0 cannot keep and 4:4:4 can */
static void drawChromaStripes(Canvas* picture)
{
    for (uint32_t y = 0; y < picture->height; y++)
        for (uint32_t x = 0; x < picture->width; x++)
        {
            if (x % 2 == 0)
                setPixel(picture, x, y, 200, 40, 40);
            else
                setPixel(picture, x, y, 40, 40, 200);
        }
}

/* The mean difference of all color channels between two pictures, and the largest */
static double meanDifference(const Canvas* a, const Canvas* b, int* largest)
{
    uint64_t sum = 0;
    int maximum = 0;

    for (uint32_t y = 0; y < a->height; y++)
    {
        const uint8_t* rowA = a->pixels + (size_t)y * a->stride;
        const uint8_t* rowB = b->pixels + (size_t)y * b->stride;
        for (uint32_t x = 0; x < a->width; x++)
            for (uint32_t channel = 0; channel < 3; channel++)
            {
                const int difference = abs((int)rowA[x * BYTES_PER_PIXEL + channel] -
                                           (int)rowB[x * BYTES_PER_PIXEL + channel]);
                sum += (uint64_t)difference;
                if (difference > maximum)
                    maximum = difference;
            }
    }
    if (largest)
        *largest = maximum;
    return (double)sum / ((double)a->width * a->height * 3.0);
}

static bool appendBytes(Encoder* encoder, const void* bytes, size_t length)
{
    if (encoder->length + length > encoder->capacity)
    {
        const size_t capacity = (encoder->length + length) * 2;
        uint8_t* stream = realloc(encoder->stream, capacity);
        if (!stream)
            return false;
        encoder->stream = stream;
        encoder->capacity = capacity;
    }
    memcpy(encoder->stream + encoder->length, bytes, length);
    encoder->length += length;
    return true;
}

/* A key frame gets the parameter sets in front, as RDPGFX sends them; every NAL unit gets a start code */
static OSStatus toAnnexB(Encoder* encoder, CMSampleBufferRef sample)
{
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    bool keyFrame = true;
    if (attachments && CFArrayGetCount(attachments) > 0)
    {
        CFDictionaryRef first = CFArrayGetValueAtIndex(attachments, 0);
        keyFrame = !CFDictionaryContainsKey(first, kCMSampleAttachmentKey_NotSync);
    }

    size_t setCount = 0;
    int lengthSize = 0;
    OSStatus status =
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, NULL, NULL, &setCount, &lengthSize);
    if (status != noErr)
        return status;
    if (keyFrame)
        for (size_t index = 0; index < setCount; index++)
        {
            const uint8_t* set = NULL;
            size_t setLength = 0;
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, index, &set, &setLength, NULL, NULL);
            if (status != noErr)
                return status;
            if (!appendBytes(encoder, startCode, sizeof(startCode)) || !appendBytes(encoder, set, setLength))
                return kCMBlockBufferBlockAllocationFailedErr;
        }

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    const size_t total = CMBlockBufferGetDataLength(block);
    uint8_t* data = malloc(total);
    if (!data)
        return kCMBlockBufferBlockAllocationFailedErr;
    status = CMBlockBufferCopyDataBytes(block, 0, total, data);
    for (size_t offset = 0; status == noErr && offset + (size_t)lengthSize <= total;)
    {
        size_t length = 0;
        for (int i = 0; i < lengthSize; i++)
            length = (length << 8) | data[offset + (size_t)i];
        offset += (size_t)lengthSize;
        if (length > total - offset || !appendBytes(encoder, startCode, sizeof(startCode)) ||
            !appendBytes(encoder, data + offset, length))
            status = kCMBlockBufferBadLengthParameterErr;
        offset += length;
    }
    free(data);
    return status;
}

static void onEncoded(void* refCon, void* frameRefCon, OSStatus status, VTEncodeInfoFlags flags,
                      CMSampleBufferRef sample)
{
    (void)frameRefCon;
    (void)flags;
    Encoder* encoder = refCon;
    encoder->status = status;
    if (status == noErr && sample)
        encoder->status = toAnnexB(encoder, sample);
}

static void setProperty(VTCompressionSessionRef session, CFStringRef key, CFTypeRef value)
{
    /* An encoder that knows no such property keeps its default: the round trip decides */
    (void)VTSessionSetProperty(session, key, value);
}

/* Real time, no reordering of frames: the encoder behaves as the one of a remote desktop */
static bool encoderInit(Encoder* encoder, uint32_t width, uint32_t height)
{
    memset(encoder, 0, sizeof(*encoder));
    encoder->width = width;
    encoder->height = height;
    const OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault, (int32_t)width, (int32_t)height,
                                                       kCMVideoCodecType_H264, NULL, NULL, NULL, onEncoded,
                                                       encoder, &encoder->session);
    if (status != noErr)
    {
        fprintf(stderr, "VTCompressionSessionCreate: %d\n", (int)status);
        return false;
    }

    const int32_t bitrate = ENCODER_BITRATE;
    CFNumberRef bitrateNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bitrate);
    setProperty(encoder->session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    setProperty(encoder->session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    setProperty(encoder->session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
    setProperty(encoder->session, kVTCompressionPropertyKey_AverageBitRate, bitrateNumber);
    CFRelease(bitrateNumber);
    return VTCompressionSessionPrepareToEncodeFrames(encoder->session) == noErr;
}

static void encoderFree(Encoder* encoder)
{
    if (encoder->session)
    {
        VTCompressionSessionInvalidate(encoder->session);
        CFRelease(encoder->session);
    }
    free(encoder->stream);
}

/* Encodes the planes as the next frame; the Annex B stream of that frame is left in the encoder */
static bool encodeFrame(Encoder* encoder, const Planes* planes, bool keyFrame)
{
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, encoder->width, encoder->height,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &buffer) != kCVReturnSuccess)
        return false;

    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t* luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
    const size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
    uint8_t* chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
    const size_t chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
    for (uint32_t y = 0; y < encoder->height; y++)
        memcpy(luma + y * lumaStride, planes->data[0] + (size_t)y * planes->stride[0], encoder->width);
    for (uint32_t y = 0; y < (encoder->height + 1) / 2; y++)
        for (uint32_t x = 0; x < (encoder->width + 1) / 2; x++)
        {
            chroma[y * chromaStride + 2 * x] = planes->data[1][(size_t)y * planes->stride[1] + x];
            chroma[y * chromaStride + 2 * x + 1] = planes->data[2][(size_t)y * planes->stride[2] + x];
        }
    CVPixelBufferUnlockBaseAddress(buffer, 0);

    CFDictionaryRef options = NULL;
    if (keyFrame)
    {
        const void* keys[] = { kVTEncodeFrameOptionKey_ForceKeyFrame };
        const void* values[] = { kCFBooleanTrue };
        options = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                     &kCFTypeDictionaryValueCallBacks);
    }
    encoder->length = 0;
    encoder->status = noErr;
    const CMTime time = CMTimeMake(encoder->frames++, FRAMES_PER_SECOND);
    OSStatus status =
        VTCompressionSessionEncodeFrame(encoder->session, buffer, time, kCMTimeInvalid, options, NULL, NULL);
    if (status == noErr)
        status = VTCompressionSessionCompleteFrames(encoder->session, kCMTimeInvalid);
    if (options)
        CFRelease(options);
    CVPixelBufferRelease(buffer);
    if (status != noErr || encoder->status != noErr || encoder->length == 0)
    {
        fprintf(stderr, "encoding failed: %d, frame status %d, %zu bytes\n", (int)status, (int)encoder->status,
                encoder->length);
        return false;
    }
    return true;
}

static bool toYUV420(const Canvas* picture, Planes* planes)
{
    const primitives_t* prims = primitives_get();
    const prim_size_t roi = { .width = picture->width, .height = picture->height };
    return prims->RGBToYUV420_8u_P3AC4R(picture->pixels, PIXEL_FORMAT_BGRX32, picture->stride, planes->data,
                                        planes->stride, &roi) == PRIMITIVES_SUCCESS;
}

/* Frames of moving blocks through AVC420: each decodes to the picture it came from */
static bool roundTrip420(uint32_t width, uint32_t height)
{
    Canvas source;
    Canvas decoded;
    Planes planes;
    Encoder encoder;
    CHECK(canvasInit(&source, width, height));
    CHECK(canvasInit(&decoded, width, height));
    CHECK(planesInit(&planes, width, height));
    CHECK(encoderInit(&encoder, width, height));
    H264_CONTEXT* h264 = h264_context_new(FALSE);
    CHECK(h264 != NULL);
    CHECK(h264_context_reset(h264, width, height));

    const RECTANGLE_16 whole = { 0, 0, (UINT16)width, (UINT16)height };
    for (uint32_t frame = 0; frame < ROUND_TRIP_FRAMES; frame++)
    {
        drawBlocks(&source, frame);
        CHECK(toYUV420(&source, &planes));
        CHECK(encodeFrame(&encoder, &planes, frame == 0));
        const INT32 rc = avc420_decompress(h264, encoder.stream, (UINT32)encoder.length, decoded.pixels,
                                           PIXEL_FORMAT_BGRX32, decoded.stride, width, height, &whole, 1);
        int largest = 0;
        const double mean = meanDifference(&source, &decoded, &largest);
        printf("%ux%u frame %u: %zu bytes, avc420_decompress %d, mean difference %.2f, largest %d\n", width,
               height, frame, encoder.length, rc, mean, largest);
        CHECK(rc >= 0);
        CHECK(mean < 2.0);
    }

    h264_context_free(h264);
    encoderFree(&encoder);
    planesFree(&planes);
    canvasFree(&decoded);
    canvasFree(&source);
    return true;
}

static bool testAvc420RoundTrip(void)
{
    return roundTrip420(640, 480);
}

/* 1080 rows are no whole number of macroblocks: the stream crops 1088 to 1080, the frame fills the surface */
static bool testAvc420CroppedFrame(void)
{
    return roundTrip420(1920, 1080);
}

/*
 * Chroma stripes through AVC444: the main frame and the auxiliary one go through one stream
 * FreeRDP decodes both with one decoder; the combined picture keeps the stripes that 4:2:0 alone would blur
 */
static bool roundTrip444(bool version2)
{
    const uint32_t width = 320;
    const uint32_t height = 240;
    Canvas source;
    Canvas decoded;
    Planes main;
    Planes auxiliary;
    Encoder encoder;
    CHECK(canvasInit(&source, width, height));
    CHECK(canvasInit(&decoded, width, height));
    CHECK(planesInit(&main, width, height));
    CHECK(planesInit(&auxiliary, width, height));
    CHECK(encoderInit(&encoder, width, height));
    H264_CONTEXT* h264 = h264_context_new(FALSE);
    CHECK(h264 != NULL);
    CHECK(h264_context_reset(h264, width, height));

    drawChromaStripes(&source);
    const primitives_t* prims = primitives_get();
    const prim_size_t roi = { .width = width, .height = height };
    const pstatus_t split =
        version2 ? prims->RGBToAVC444YUVv2(source.pixels, PIXEL_FORMAT_BGRX32, source.stride, main.data, main.stride,
                                           auxiliary.data, auxiliary.stride, &roi)
                 : prims->RGBToAVC444YUV(source.pixels, PIXEL_FORMAT_BGRX32, source.stride, main.data, main.stride,
                                         auxiliary.data, auxiliary.stride, &roi);
    CHECK(split == PRIMITIVES_SUCCESS);

    CHECK(encodeFrame(&encoder, &main, true));
    uint8_t* mainStream = malloc(encoder.length);
    CHECK(mainStream != NULL);
    memcpy(mainStream, encoder.stream, encoder.length);
    const UINT32 mainLength = (UINT32)encoder.length;
    CHECK(encodeFrame(&encoder, &auxiliary, false));

    const RECTANGLE_16 whole = { 0, 0, (UINT16)width, (UINT16)height };
    const INT32 rc =
        avc444_decompress(h264, 0, &whole, 1, mainStream, mainLength, &whole, 1, encoder.stream,
                          (UINT32)encoder.length, decoded.pixels, PIXEL_FORMAT_BGRX32, decoded.stride, width, height,
                          version2 ? RDPGFX_CODECID_AVC444v2 : RDPGFX_CODECID_AVC444);
    int largest = 0;
    const double mean = meanDifference(&source, &decoded, &largest);
    printf("AVC444%s: main %u bytes, auxiliary %zu bytes, avc444_decompress %d, mean difference %.2f, largest %d\n",
           version2 ? "v2" : "", mainLength, encoder.length, rc, mean, largest);
    CHECK(rc >= 0);
    CHECK(mean < 6.0);

    /* The same stripes through AVC420 alone lose their chroma: that is what the auxiliary frame brings back */
    H264_CONTEXT* only420 = h264_context_new(FALSE);
    CHECK(only420 != NULL);
    CHECK(h264_context_reset(only420, width, height));
    Canvas blurred;
    CHECK(canvasInit(&blurred, width, height));
    CHECK(avc420_decompress(only420, mainStream, mainLength, blurred.pixels, PIXEL_FORMAT_BGRX32, blurred.stride,
                            width, height, &whole, 1) >= 0);
    const double mean420 = meanDifference(&source, &blurred, NULL);
    printf("the main frame alone: mean difference %.2f\n", mean420);
    CHECK(mean420 > mean * 4);

    canvasFree(&blurred);
    h264_context_free(only420);
    free(mainStream);
    h264_context_free(h264);
    encoderFree(&encoder);
    planesFree(&auxiliary);
    planesFree(&main);
    canvasFree(&decoded);
    canvasFree(&source);
    return true;
}

static bool testAvc444RoundTrip(void)
{
    return roundTrip444(false);
}

static bool testAvc444v2RoundTrip(void)
{
    return roundTrip444(true);
}

/* A new surface size resets the context, the stream brings new parameter sets, and decoding goes on */
static bool testSizeChange(void)
{
    const uint32_t sizes[2][2] = { { 640, 480 }, { 800, 600 } };
    H264_CONTEXT* h264 = h264_context_new(FALSE);
    CHECK(h264 != NULL);

    for (int step = 0; step < 2; step++)
    {
        const uint32_t width = sizes[step][0];
        const uint32_t height = sizes[step][1];
        Canvas source;
        Canvas decoded;
        Planes planes;
        Encoder encoder;
        CHECK(canvasInit(&source, width, height));
        CHECK(canvasInit(&decoded, width, height));
        CHECK(planesInit(&planes, width, height));
        CHECK(encoderInit(&encoder, width, height));
        CHECK(h264_context_reset(h264, width, height));

        drawBlocks(&source, (uint32_t)step);
        CHECK(toYUV420(&source, &planes));
        CHECK(encodeFrame(&encoder, &planes, true));
        const RECTANGLE_16 whole = { 0, 0, (UINT16)width, (UINT16)height };
        CHECK(avc420_decompress(h264, encoder.stream, (UINT32)encoder.length, decoded.pixels, PIXEL_FORMAT_BGRX32,
                                decoded.stride, width, height, &whole, 1) >= 0);
        const double mean = meanDifference(&source, &decoded, NULL);
        printf("%ux%u: mean difference %.2f\n", width, height, mean);
        CHECK(mean < 2.0);

        encoderFree(&encoder);
        planesFree(&planes);
        canvasFree(&decoded);
        canvasFree(&source);
    }
    h264_context_free(h264);
    return true;
}

/*
 * What a broken or hostile server may send: a picture before any parameter sets, and bytes that are no H.264
 * Each is a failure of that update, not of the process, and a key frame after them decodes as usual
 */
static bool testBadStreams(void)
{
    const uint32_t width = 320;
    const uint32_t height = 240;
    Canvas source;
    Canvas decoded;
    Planes planes;
    Encoder encoder;
    CHECK(canvasInit(&source, width, height));
    CHECK(canvasInit(&decoded, width, height));
    CHECK(planesInit(&planes, width, height));
    CHECK(encoderInit(&encoder, width, height));
    H264_CONTEXT* h264 = h264_context_new(FALSE);
    CHECK(h264 != NULL);
    CHECK(h264_context_reset(h264, width, height));
    const RECTANGLE_16 whole = { 0, 0, (UINT16)width, (UINT16)height };

    /* A slice of an IDR picture with no parameter sets before it */
    static const uint8_t lonePicture[] = { 0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00, 0x33, 0xFF };
    CHECK(avc420_decompress(h264, lonePicture, sizeof(lonePicture), decoded.pixels, PIXEL_FORMAT_BGRX32,
                            decoded.stride, width, height, &whole, 1) < 0);

    drawBlocks(&source, 0);
    CHECK(toYUV420(&source, &planes));
    CHECK(encodeFrame(&encoder, &planes, true));

    /* The parameter sets of a real stream, then noise where the picture should be */
    uint8_t noise[4096];
    uint32_t seed = 0x12345678u;
    for (size_t i = 0; i < sizeof(noise); i++)
    {
        seed = seed * 1664525u + 1013904223u;
        noise[i] = (uint8_t)(seed >> 24);
    }
    static const uint8_t pictureStart[] = { 0, 0, 0, 1, 0x65 };
    const uint8_t* idr = NULL;
    for (size_t i = 0; i + sizeof(pictureStart) <= encoder.length; i++)
        if (memcmp(encoder.stream + i, startCode, sizeof(startCode)) == 0 &&
            (encoder.stream[i + sizeof(startCode)] & NAL_TYPE_MASK) == NAL_TYPE_IDR)
        {
            idr = encoder.stream + i;
            break;
        }
    CHECK(idr != NULL);
    const size_t prefix = (size_t)(idr - encoder.stream);
    uint8_t* broken = malloc(prefix + sizeof(pictureStart) + sizeof(noise));
    CHECK(broken != NULL);
    memcpy(broken, encoder.stream, prefix);
    memcpy(broken + prefix, pictureStart, sizeof(pictureStart));
    memcpy(broken + prefix + sizeof(pictureStart), noise, sizeof(noise));
    const INT32 rc = avc420_decompress(h264, broken, (UINT32)(prefix + sizeof(pictureStart) + sizeof(noise)),
                                       decoded.pixels, PIXEL_FORMAT_BGRX32, decoded.stride, width, height, &whole, 1);
    printf("noise in place of the picture: avc420_decompress %d\n", rc);
    free(broken);

    CHECK(avc420_decompress(h264, encoder.stream, (UINT32)encoder.length, decoded.pixels, PIXEL_FORMAT_BGRX32,
                            decoded.stride, width, height, &whole, 1) >= 0);
    const double mean = meanDifference(&source, &decoded, NULL);
    printf("the key frame after them: mean difference %.2f\n", mean);
    CHECK(mean < 2.0);

    h264_context_free(h264);
    encoderFree(&encoder);
    planesFree(&planes);
    canvasFree(&decoded);
    canvasFree(&source);
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "avc420RoundTrip", testAvc420RoundTrip },
    { "avc420CroppedFrame", testAvc420CroppedFrame },
    { "avc444RoundTrip", testAvc444RoundTrip },
    { "avc444v2RoundTrip", testAvc444v2RoundTrip },
    { "sizeChange", testSizeChange },
    { "badStreams", testBadStreams },
};

/* CTest counts a test that returns this as skipped, not failed */
#define SKIPPED 77

int main(int argc, char* argv[])
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s <test name>\n", argv[0]);
        return 2;
    }
    /*
     * Every Mac the app runs on decodes H.264 in hardware; a virtual machine, as a CI runner is, has no such decoder,
     * and VideoToolbox fails its frames there: the tests say so and skip rather than fail
     */
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_H264))
    {
        printf("skipped: this machine has no hardware H.264 decoder\n");
        return SKIPPED;
    }
    for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); i++)
        if (strcmp(tests[i].name, argv[1]) == 0)
            return tests[i].run() ? 0 : 1;

    fprintf(stderr, "unknown test: %s\n", argv[1]);
    return 2;
}
