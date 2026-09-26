/*
 * The VibeSeam channel: frames both ways and the plugin the engine loads for the channel
 */

#include "seam.h"

#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/addin.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cmdline.h>
#include <winpr/stream.h>
#include <winpr/string.h>
#include <winpr/wlog.h>

#define TAG "com.vibebrains.viberdp.seam"

/* The name the engine loads the plugin by, as the dynamic channel list carries it */
#define PLUGIN_NAME "vibeseam"

_Static_assert(VRC_SEAM_MAX_BODY <= UINT32_MAX, "a body length must fit the u32 in front of it");

void vrcSeamInit(VRCSeam* seam, const VRCCallbacks* callbacks, void* const* userData)
{
    memset(seam, 0, sizeof(*seam));
    pthread_mutex_init(&seam->mutex, NULL);
    seam->callbacks = callbacks;
    seam->userData = userData;
}

void vrcSeamDestroy(VRCSeam* seam)
{
    free(seam->pending);
    pthread_mutex_destroy(&seam->mutex);
}

void vrcSeamOpened(VRCSeam* seam, IWTSVirtualChannel* channel)
{
    pthread_mutex_lock(&seam->mutex);
    seam->channel = channel;
    pthread_mutex_unlock(&seam->mutex);
    seam->pendingLength = 0;
    seam->broken = false;
    WLog_INFO(TAG, "channel open");
    if (seam->callbacks->seamOpened)
        seam->callbacks->seamOpened(*seam->userData);
}

/* Whether this is the channel the app talks over; the channel thread alone changes it, so it may read it bare */
static bool isCurrent(const VRCSeam* seam, const IWTSVirtualChannel* channel)
{
    return channel != NULL && channel == seam->channel;
}

void vrcSeamClosed(VRCSeam* seam, IWTSVirtualChannel* channel)
{
    if (!isCurrent(seam, channel))
    {
        WLog_INFO(TAG, "an older channel closed");
        return;
    }
    pthread_mutex_lock(&seam->mutex);
    seam->channel = NULL;
    pthread_mutex_unlock(&seam->mutex);
    seam->pendingLength = 0;
    WLog_INFO(TAG, "channel closed");
    /* A broken channel was reported closed already */
    if (!seam->broken && seam->callbacks->seamClosed)
        seam->callbacks->seamClosed(*seam->userData);
}

static uint32_t lengthOf(const uint8_t* field)
{
    return (uint32_t)field[0] | (uint32_t)field[1] << 8 | (uint32_t)field[2] << 16 | (uint32_t)field[3] << 24;
}

/* Makes room for this many bytes of the frame being gathered */
static bool reserve(VRCSeam* seam, size_t size)
{
    if (size <= seam->pendingCapacity)
        return true;
    uint8_t* grown = realloc(seam->pending, size);
    if (!grown)
        return false;
    seam->pending = grown;
    seam->pendingCapacity = size;
    return true;
}

static void breakChannel(VRCSeam* seam, const char* reason)
{
    WLog_ERR(TAG, "protocol error: %s; the rest of the channel is dropped", reason);
    seam->broken = true;
    seam->pendingLength = 0;
    if (seam->callbacks->seamClosed)
        seam->callbacks->seamClosed(*seam->userData);
}

void vrcSeamReceived(VRCSeam* seam, IWTSVirtualChannel* channel, const uint8_t* chunk, size_t length)
{
    if (!isCurrent(seam, channel))
        return;
    while (!seam->broken)
    {
        /* A whole frame goes to the app, and gathering starts over; a frame may carry an empty body */
        if (seam->pendingLength >= VRC_SEAM_LENGTH_SIZE)
        {
            const uint32_t body = lengthOf(seam->pending);
            if (body > VRC_SEAM_MAX_BODY)
            {
                breakChannel(seam, "a frame longer than the protocol allows");
                return;
            }
            if (seam->pendingLength == VRC_SEAM_LENGTH_SIZE + (size_t)body)
            {
                if (seam->callbacks->seamReceived)
                    seam->callbacks->seamReceived(*seam->userData, seam->pending + VRC_SEAM_LENGTH_SIZE, body);
                seam->pendingLength = 0;
                continue;
            }
        }
        if (length == 0)
            return;

        /* The length field first, then the body it announces */
        const size_t wanted = seam->pendingLength < VRC_SEAM_LENGTH_SIZE
                                  ? VRC_SEAM_LENGTH_SIZE
                                  : VRC_SEAM_LENGTH_SIZE + (size_t)lengthOf(seam->pending);
        const size_t take = wanted - seam->pendingLength < length ? wanted - seam->pendingLength : length;
        if (!reserve(seam, seam->pendingLength + take))
        {
            breakChannel(seam, "no memory for a frame");
            return;
        }
        memcpy(seam->pending + seam->pendingLength, chunk, take);
        seam->pendingLength += take;
        chunk += take;
        length -= take;
    }
}

VRCResult vrcSeamSend(VRCSeam* seam, const uint8_t* body, size_t length)
{
    if ((!body && length > 0) || length > VRC_SEAM_MAX_BODY)
        return VRCResultInvalidArgument;
    uint8_t* frame = malloc(VRC_SEAM_LENGTH_SIZE + length);
    if (!frame)
        return VRCResultFailure;
    for (size_t i = 0; i < VRC_SEAM_LENGTH_SIZE; i++)
        frame[i] = (uint8_t)(length >> (8 * i));
    if (length > 0)
        memcpy(frame + VRC_SEAM_LENGTH_SIZE, body, length);

    VRCResult result = VRCResultInvalidState;
    /* Under the mutex: the channel cannot close and be freed while the write is on it */
    pthread_mutex_lock(&seam->mutex);
    if (seam->channel && !seam->broken)
    {
        const UINT rc =
            seam->channel->Write(seam->channel, (ULONG)(VRC_SEAM_LENGTH_SIZE + length), frame, NULL);
        result = rc == CHANNEL_RC_OK ? VRCResultOK : VRCResultFailure;
        if (rc != CHANNEL_RC_OK)
            WLog_ERR(TAG, "write failed: 0x%08" PRIX32, rc);
    }
    pthread_mutex_unlock(&seam->mutex);
    free(frame);
    return result;
}

/* The plugin: the generic dynamic channel of FreeRDP with the callbacks of this channel */

typedef struct SeamPlugin {
    /* Must stay first: the engine allocates the plugin with the size given and treats it as its own type */
    GENERIC_DYNVC_PLUGIN base;
    VRCSeam* seam;
} SeamPlugin;

static VRCSeam* seamOf(IWTSVirtualChannelCallback* callback)
{
    return ((SeamPlugin*)((GENERIC_CHANNEL_CALLBACK*)callback)->plugin)->seam;
}

static UINT onOpen(IWTSVirtualChannelCallback* callback)
{
    vrcSeamOpened(seamOf(callback), ((GENERIC_CHANNEL_CALLBACK*)callback)->channel);
    return CHANNEL_RC_OK;
}

static UINT onDataReceived(IWTSVirtualChannelCallback* callback, wStream* data)
{
    vrcSeamReceived(seamOf(callback), ((GENERIC_CHANNEL_CALLBACK*)callback)->channel, Stream_ConstPointer(data),
                    Stream_GetRemainingLength(data));
    return CHANNEL_RC_OK;
}

static UINT onClose(IWTSVirtualChannelCallback* callback)
{
    vrcSeamClosed(seamOf(callback), ((GENERIC_CHANNEL_CALLBACK*)callback)->channel);
    /* The generic listener allocated the callback for this channel and leaves freeing it to the close */
    free(callback);
    return CHANNEL_RC_OK;
}

static const IWTSVirtualChannelCallback channelCallbacks = {
    .OnDataReceived = onDataReceived,
    .OnOpen = onOpen,
    .OnClose = onClose,
};

static UINT initPlugin(GENERIC_DYNVC_PLUGIN* plugin, rdpContext* context, WINPR_ATTR_UNUSED rdpSettings* settings)
{
    ((SeamPlugin*)plugin)->seam = vrcSessionSeam(context);
    return CHANNEL_RC_OK;
}

static UINT VCAPITYPE seamPluginEntry(IDRDYNVC_ENTRY_POINTS* entryPoints)
{
    return freerdp_generic_DVCPluginEntry(entryPoints, TAG, VRC_SEAM_CHANNEL_NAME, sizeof(SeamPlugin),
                                          sizeof(GENERIC_CHANNEL_CALLBACK), &channelCallbacks, initPlugin, NULL);
}

/* Serves the plugin of this channel and hands every other name to the provider of FreeRDP */
static PVIRTUALCHANNELENTRY provideAddin(LPCSTR name, LPCSTR subsystem, LPCSTR type, DWORD flags)
{
    if (name && strcmp(name, PLUGIN_NAME) == 0 && (flags & FREERDP_ADDIN_CHANNEL_DYNAMIC) != 0)
    {
        /* The engine takes every entry as one pointer type and casts it back to the kind the flags name */
        PDVC_PLUGIN_ENTRY entry = seamPluginEntry;
        return WINPR_FUNC_PTR_CAST(entry, PVIRTUALCHANNELENTRY);
    }
    return freerdp_channels_load_static_addin_entry(name, subsystem, type, flags);
}

BOOL vrcSeamApply(rdpSettings* settings)
{
    /*
     * The provider is one for the process, and every new client context registers the one of FreeRDP again:
     * the core puts its own back before each connection, and it serves every session alike
     */
    if (freerdp_register_addin_provider(provideAddin, 0) != CHANNEL_RC_OK)
        return FALSE;
    const char* const channel[] = { PLUGIN_NAME };
    return freerdp_client_add_dynamic_channel(settings, ARRAYSIZE(channel), channel);
}
