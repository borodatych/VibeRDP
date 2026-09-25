/*
 * H.264 decoding for the graphics pipeline through VideoToolbox, the video decoder of macOS
 * The stream comes in Annex B form: parameter sets and pictures, each NAL unit behind a start code
 *
 * VideoToolbox takes the parameter sets as a format description,
 * and the pictures behind length prefixes
 * It decodes in hardware wherever the Mac has it and returns 4:2:0 frames, NV12 as a rule
 * The frames are copied into I420 planes with room around them:
 * the YUV conversion of FreeRDP reads whole vectors
 *
 * VibeRDP lays this file over its copy of FreeRDP
 * core/freerdp/patches/h264-videotoolbox.patch registers it
 */

#include <freerdp/config.h>

#include <string.h>

#include <winpr/assert.h>
#include <winpr/crt.h>
#include <winpr/wlog.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>

#include "h264.h"

enum
{
	NAL_TYPE_SPS = 7,
	NAL_TYPE_PPS = 8,
	NAL_TYPE_AUD = 9
};

/* The type of a NAL unit sits in the low five bits of its first byte */
#define NAL_TYPE_MASK 0x1F

/* VideoToolbox reads NAL units behind a big-endian length of this size, as MP4 stores them */
#define NAL_LENGTH_SIZE 4

/* RDPGFX gives surface sizes in 16 bits: a frame larger than that belongs to no surface */
#define MAX_FRAME_SIDE UINT16_MAX

/*
 * The YUV conversion of FreeRDP reads whole vectors past the end of a row,
 * and rows past the end of the frame
 * The planes get the room FreeRDP gives its own buffers: sides rounded up and a margin
 */
#define PLANE_ALIGNMENT 16
#define PLANE_MARGIN 32

typedef struct
{
	VTDecompressionSessionRef session;
	CMVideoFormatDescriptionRef format;
	BYTE* sps;
	size_t spsLength;
	BYTE* pps;
	size_t ppsLength;
	/* The pictures of one access unit behind their lengths; the buffer stays for the next one */
	BYTE* sample;
	size_t sampleCapacity;
	/* The result of the last decode, as the callback of the session delivered it */
	CVPixelBufferRef image;
	OSStatus imageStatus;
	/* The I420 planes that h264->pYUVData points into */
	BYTE* planes[3];
	size_t planeWidth;
	size_t planeHeight;
} H264_CONTEXT_VIDEOTOOLBOX;

static size_t align_up(size_t value)
{
	return (value + PLANE_ALIGNMENT - 1) / PLANE_ALIGNMENT * PLANE_ALIGNMENT;
}

/* The first byte of the next three-byte start code, or the end of the data */
static const BYTE* find_start_code(const BYTE* data, const BYTE* end)
{
	while (end - data >= 3)
	{
		if ((data[0] == 0) && (data[1] == 0) && (data[2] == 1))
			return data;
		data++;
	}
	return end;
}

static void videotoolbox_output(void* decompressionOutputRefCon,
                                WINPR_ATTR_UNUSED void* sourceFrameRefCon, OSStatus status,
                                WINPR_ATTR_UNUSED VTDecodeInfoFlags infoFlags,
                                CVImageBufferRef imageBuffer,
                                WINPR_ATTR_UNUSED CMTime presentationTimeStamp,
                                WINPR_ATTR_UNUSED CMTime presentationDuration)
{
	H264_CONTEXT_VIDEOTOOLBOX* sys = decompressionOutputRefCon;
	WINPR_ASSERT(sys);

	sys->imageStatus = status;
	if ((status == noErr) && imageBuffer)
	{
		CVPixelBufferRelease(sys->image);
		sys->image = CVPixelBufferRetain(imageBuffer);
	}
}

static void videotoolbox_destroy_session(H264_CONTEXT_VIDEOTOOLBOX* sys)
{
	if (!sys->session)
		return;

	(void)VTDecompressionSessionWaitForAsynchronousFrames(sys->session);
	VTDecompressionSessionInvalidate(sys->session);
	CFRelease(sys->session);
	sys->session = nullptr;
}

/*
 * Frames come out in the native format of the decoder:
 * VideoToolbox converts neither the range nor the matrix
 */
static BOOL videotoolbox_create_session(H264_CONTEXT* h264, H264_CONTEXT_VIDEOTOOLBOX* sys)
{
	const VTDecompressionOutputCallbackRecord callback = { videotoolbox_output, sys };
	const OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault, sys->format, nullptr,
	                                                     nullptr, &callback, &sys->session);
	if (status != noErr)
	{
		WLog_Print(h264->log, WLOG_ERROR, "VTDecompressionSessionCreate failed: %" PRId32, status);
		sys->session = nullptr;
		return FALSE;
	}
	return TRUE;
}

/* Keeps a parameter set that differs from the one kept before; changed tells the caller so */
static BOOL videotoolbox_keep_parameter_set(BYTE** set, size_t* setLength, const BYTE* nal,
                                            size_t length, BOOL* changed)
{
	if (*set && (*setLength == length) && (memcmp(*set, nal, length) == 0))
		return TRUE;

	BYTE* copy = malloc(length);
	if (!copy)
		return FALSE;
	memcpy(copy, nal, length);
	free(*set);
	*set = copy;
	*setLength = length;
	*changed = TRUE;
	return TRUE;
}

/*
 * A new format description from the parameter sets; a session that cannot take it goes,
 * and the next picture opens a new one
 */
static BOOL videotoolbox_update_format(H264_CONTEXT* h264, H264_CONTEXT_VIDEOTOOLBOX* sys)
{
	if (!sys->sps || !sys->pps)
		return TRUE;

	const uint8_t* sets[] = { sys->sps, sys->pps };
	const size_t sizes[] = { sys->spsLength, sys->ppsLength };
	CMVideoFormatDescriptionRef format = nullptr;
	const OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
	    kCFAllocatorDefault, ARRAYSIZE(sets), sets, sizes, NAL_LENGTH_SIZE, &format);
	if (status != noErr)
	{
		WLog_Print(h264->log, WLOG_ERROR,
		           "CMVideoFormatDescriptionCreateFromH264ParameterSets failed: %" PRId32, status);
		return FALSE;
	}

	if (sys->session && !VTDecompressionSessionCanAcceptFormatDescription(sys->session, format))
		videotoolbox_destroy_session(sys);
	if (sys->format)
		CFRelease(sys->format);
	sys->format = format;
	return TRUE;
}

/* Appends a picture NAL unit behind its length to the sample of the access unit */
static BOOL videotoolbox_append_picture(H264_CONTEXT_VIDEOTOOLBOX* sys, size_t* sampleLength,
                                        const BYTE* nal, size_t length)
{
	if (length > UINT32_MAX)
		return FALSE;

	const size_t needed = *sampleLength + NAL_LENGTH_SIZE + length;
	if (needed > sys->sampleCapacity)
	{
		BYTE* sample = realloc(sys->sample, needed);
		if (!sample)
			return FALSE;
		sys->sample = sample;
		sys->sampleCapacity = needed;
	}

	BYTE* target = sys->sample + *sampleLength;
	target[0] = (BYTE)(length >> 24);
	target[1] = (BYTE)(length >> 16);
	target[2] = (BYTE)(length >> 8);
	target[3] = (BYTE)length;
	memcpy(target + NAL_LENGTH_SIZE, nal, length);
	*sampleLength = needed;
	return TRUE;
}

/* Decodes the sample; the status is that of the call, or that of the frame the callback received */
static OSStatus videotoolbox_decode_sample(H264_CONTEXT_VIDEOTOOLBOX* sys, size_t sampleLength)
{
	CMBlockBufferRef block = nullptr;
	CMSampleBufferRef sample = nullptr;

	/* The block borrows the buffer of the context: the decode ends before a new frame reuses it */
	OSStatus status =
	    CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, sys->sample, sampleLength,
	                                       kCFAllocatorNull, nullptr, 0, sampleLength, 0, &block);
	if (status == noErr)
		status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, sys->format, 1, 0, nullptr,
		                                   1, &sampleLength, &sample);
	if (status == noErr)
	{
		VTDecodeInfoFlags infoFlags = 0;
		sys->imageStatus = noErr;
		CVPixelBufferRelease(sys->image);
		sys->image = nullptr;
		/* Without the asynchronous flag the callback comes within the call; the wait makes sure */
		status = VTDecompressionSessionDecodeFrame(sys->session, sample, 0, nullptr, &infoFlags);
		(void)VTDecompressionSessionWaitForAsynchronousFrames(sys->session);
		if (status == noErr)
			status = sys->imageStatus;
	}

	if (sample)
		CFRelease(sample);
	if (block)
		CFRelease(block);
	return status;
}

static void videotoolbox_free_planes(H264_CONTEXT* h264, H264_CONTEXT_VIDEOTOOLBOX* sys)
{
	for (size_t x = 0; x < ARRAYSIZE(sys->planes); x++)
	{
		winpr_aligned_free(sys->planes[x]);
		sys->planes[x] = nullptr;
		h264->pYUVData[x] = nullptr;
		h264->iStride[x] = 0;
	}
	sys->planeWidth = 0;
	sys->planeHeight = 0;
}

/* Zeroed I420 planes for a frame of this size, with the room the YUV conversion reads beyond it */
static BOOL videotoolbox_ensure_planes(H264_CONTEXT* h264, H264_CONTEXT_VIDEOTOOLBOX* sys,
                                       size_t width, size_t height)
{
	if (sys->planes[0] && (sys->planeWidth == width) && (sys->planeHeight == height))
		return TRUE;

	videotoolbox_free_planes(h264, sys);
	const size_t chromaWidth = (width + 1) / 2;
	const size_t chromaHeight = (height + 1) / 2;
	const size_t strides[] = { align_up(width) + PLANE_MARGIN, align_up(chromaWidth) + PLANE_MARGIN,
		                       align_up(chromaWidth) + PLANE_MARGIN };
	const size_t rows[] = { align_up(height) + PLANE_MARGIN, align_up(chromaHeight) + PLANE_MARGIN,
		                    align_up(chromaHeight) + PLANE_MARGIN };

	for (size_t x = 0; x < ARRAYSIZE(sys->planes); x++)
	{
		sys->planes[x] = winpr_aligned_calloc(rows[x], strides[x], PLANE_ALIGNMENT);
		if (!sys->planes[x])
		{
			videotoolbox_free_planes(h264, sys);
			return FALSE;
		}
		h264->pYUVData[x] = sys->planes[x];
		h264->iStride[x] = (UINT32)strides[x];
	}
	sys->planeWidth = width;
	sys->planeHeight = height;
	return TRUE;
}

/*
 * Copies the decoded frame into the I420 planes: luma as it is,
 * chroma from the interleaved plane of NV12 or from the two planes of planar 4:2:0
 * The samples stay as decoded, whatever their range
 */
static int videotoolbox_copy_image(H264_CONTEXT* h264, H264_CONTEXT_VIDEOTOOLBOX* sys)
{
	CVPixelBufferRef image = sys->image;
	const OSType type = CVPixelBufferGetPixelFormatType(image);
	const BOOL interleaved = (type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ||
	                         (type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
	const BOOL planar = (type == kCVPixelFormatType_420YpCbCr8Planar) ||
	                    (type == kCVPixelFormatType_420YpCbCr8PlanarFullRange);
	const size_t width = CVPixelBufferGetWidth(image);
	const size_t height = CVPixelBufferGetHeight(image);
	const size_t chromaWidth = (width + 1) / 2;
	const size_t chromaHeight = (height + 1) / 2;

	if (!interleaved && !planar)
	{
		WLog_Print(h264->log, WLOG_ERROR,
		           "VideoToolbox returned the unsupported pixel format 0x%08" PRIx32,
		           (uint32_t)type);
		return -1;
	}
	if ((width == 0) || (height == 0) || (width > MAX_FRAME_SIDE) || (height > MAX_FRAME_SIDE))
	{
		WLog_Print(h264->log, WLOG_ERROR, "VideoToolbox returned a frame of %" PRIuz "x%" PRIuz,
		           width, height);
		return -1;
	}
	if ((CVPixelBufferGetPlaneCount(image) != (interleaved ? 2 : 3)) ||
	    (CVPixelBufferGetWidthOfPlane(image, 0) < width) ||
	    (CVPixelBufferGetHeightOfPlane(image, 0) < height) ||
	    (CVPixelBufferGetWidthOfPlane(image, 1) < chromaWidth) ||
	    (CVPixelBufferGetHeightOfPlane(image, 1) < chromaHeight))
	{
		WLog_Print(h264->log, WLOG_ERROR, "VideoToolbox returned planes smaller than the frame");
		return -1;
	}
	if (!videotoolbox_ensure_planes(h264, sys, width, height))
		return -1;
	if (CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
		return -1;

	const BYTE* luma = CVPixelBufferGetBaseAddressOfPlane(image, 0);
	const size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(image, 0);
	for (size_t y = 0; y < height; y++)
		memcpy(sys->planes[0] + y * h264->iStride[0], luma + y * lumaStride, width);

	if (interleaved)
	{
		const BYTE* chroma = CVPixelBufferGetBaseAddressOfPlane(image, 1);
		const size_t chromaStride = CVPixelBufferGetBytesPerRowOfPlane(image, 1);
		for (size_t y = 0; y < chromaHeight; y++)
		{
			const BYTE* source = chroma + y * chromaStride;
			BYTE* u = sys->planes[1] + y * h264->iStride[1];
			BYTE* v = sys->planes[2] + y * h264->iStride[2];
			for (size_t x = 0; x < chromaWidth; x++)
			{
				u[x] = source[2 * x];
				v[x] = source[2 * x + 1];
			}
		}
	}
	else
	{
		for (size_t plane = 1; plane < 3; plane++)
		{
			const BYTE* chroma = CVPixelBufferGetBaseAddressOfPlane(image, plane);
			const size_t chromaStride = CVPixelBufferGetBytesPerRowOfPlane(image, plane);
			for (size_t y = 0; y < chromaHeight; y++)
				memcpy(sys->planes[plane] + y * h264->iStride[plane], chroma + y * chromaStride,
				       chromaWidth);
		}
	}

	(void)CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
	h264->YUVWidth = (UINT32)width;
	h264->YUVHeight = (UINT32)height;
	return 1;
}

static BOOL videotoolbox_init(H264_CONTEXT* h264)
{
	WINPR_ASSERT(h264);

	/* Decoding only: the graphics pipeline of a client never encodes */
	if (h264->Compressor)
		return FALSE;

	H264_CONTEXT_VIDEOTOOLBOX* sys = calloc(1, sizeof(H264_CONTEXT_VIDEOTOOLBOX));
	if (!sys)
		return FALSE;
	h264->pSystemData = sys;
	return TRUE;
}

static void videotoolbox_uninit(H264_CONTEXT* h264)
{
	WINPR_ASSERT(h264);

	H264_CONTEXT_VIDEOTOOLBOX* sys = h264->pSystemData;
	if (!sys)
		return;

	videotoolbox_destroy_session(sys);
	if (sys->format)
		CFRelease(sys->format);
	CVPixelBufferRelease(sys->image);
	free(sys->sps);
	free(sys->pps);
	free(sys->sample);
	videotoolbox_free_planes(h264, sys);
	free(sys);
	h264->pSystemData = nullptr;
}

/*
 * One access unit: parameter sets update the format, pictures go to the decoder as one sample
 * 1 with a frame in the planes, 0 without a picture or when the decoder dropped it,
 * below 0 on failure
 */
static int videotoolbox_decompress(H264_CONTEXT* WINPR_RESTRICT h264,
                                   const BYTE* WINPR_RESTRICT pSrcData, UINT32 SrcSize)
{
	WINPR_ASSERT(h264);
	WINPR_ASSERT(pSrcData || (SrcSize == 0));

	H264_CONTEXT_VIDEOTOOLBOX* sys = h264->pSystemData;
	WINPR_ASSERT(sys);

	size_t sampleLength = 0;
	BOOL parametersChanged = FALSE;
	const BYTE* end = pSrcData + SrcSize;
	const BYTE* start = find_start_code(pSrcData, end);
	while (start < end)
	{
		const BYTE* nal = start + 3;
		const BYTE* next = find_start_code(nal, end);
		const BYTE* nalEnd = next;

		/* Zeros before a start code belong to it or pad the stream, not to the NAL unit before */
		while ((nalEnd > nal) && (nalEnd[-1] == 0))
			nalEnd--;
		const size_t length = (size_t)(nalEnd - nal);
		if (length > 0)
		{
			BOOL kept = TRUE;
			switch (nal[0] & NAL_TYPE_MASK)
			{
				case NAL_TYPE_SPS:
					kept = videotoolbox_keep_parameter_set(&sys->sps, &sys->spsLength, nal, length,
					                                       &parametersChanged);
					break;
				case NAL_TYPE_PPS:
					kept = videotoolbox_keep_parameter_set(&sys->pps, &sys->ppsLength, nal, length,
					                                       &parametersChanged);
					break;
				case NAL_TYPE_AUD:
					break;
				default:
					kept = videotoolbox_append_picture(sys, &sampleLength, nal, length);
					break;
			}
			if (!kept)
				return -1;
		}
		start = next;
	}

	if (parametersChanged && !videotoolbox_update_format(h264, sys))
		return -1;
	if (sampleLength == 0)
		return 0;
	if (!sys->format)
	{
		WLog_Print(h264->log, WLOG_WARN, "H264 picture before its parameter sets");
		return -1;
	}
	if (!sys->session && !videotoolbox_create_session(h264, sys))
		return -1;

	OSStatus status = videotoolbox_decode_sample(sys, sampleLength);
	if (status == kVTInvalidSessionErr)
	{
		/*
		 * The session dies with the decoder behind it, as over a sleep of the Mac
		 * A new one takes the stream on
		 */
		videotoolbox_destroy_session(sys);
		if (!videotoolbox_create_session(h264, sys))
			return -1;
		status = videotoolbox_decode_sample(sys, sampleLength);
	}
	if (status != noErr)
	{
		WLog_Print(h264->log, WLOG_WARN, "VideoToolbox failed to decode a frame: %" PRId32, status);
		return -1;
	}
	if (!sys->image)
		return 0;
	return videotoolbox_copy_image(h264, sys);
}

const H264_CONTEXT_SUBSYSTEM g_Subsystem_VideoToolbox = { "VideoToolbox", videotoolbox_init,
	                                                      videotoolbox_uninit,
	                                                      videotoolbox_decompress, nullptr };
