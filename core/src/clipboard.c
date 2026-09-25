/*
 * The clipboard channel of a session
 * Mac to Windows: the offer goes out as a format list, the server asks for data only when something pastes there
 * Windows to Mac: the format list of the server comes to the app, which asks for data only when the Mac pastes
 */

#include "clipboard.h"
#include "cliptext.h"

#include <stdlib.h>
#include <string.h>

#include <freerdp/channels/cliprdr.h>
#include <winpr/user.h>

static uint32_t formatBit(int32_t format)
{
    return 1u << (uint32_t)format;
}

static bool knownFormat(int32_t format)
{
    return format == VRCClipboardFormatText;
}

/* The format of Windows that carries a format of the app: Windows makes its other text formats itself */
static uint32_t windowsFormatId(int32_t format)
{
    switch (format)
    {
        case VRCClipboardFormatText:
            return CF_UNICODETEXT;
        default:
            return 0;
    }
}

/* The format of the app that a format of the server carries, 0 for one the app does not take */
static int32_t appFormat(const CLIPRDR_FORMAT* format)
{
    if (format->formatId == CF_UNICODETEXT)
        return VRCClipboardFormatText;
    return 0;
}

/* The caller holds the mutex: the channel stays up while the list goes out */
static UINT sendFormatList(CliprdrClientContext* channel, uint32_t offered)
{
    CLIPRDR_FORMAT formats[VRC_CLIPBOARD_FORMAT_SLOTS] = { 0 };
    UINT32 count = 0;

    for (int32_t format = 1; format < VRC_CLIPBOARD_FORMAT_SLOTS; format++)
        if (offered & formatBit(format))
            formats[count++].formatId = windowsFormatId(format);

    const CLIPRDR_FORMAT_LIST list = { .common = { .msgType = CB_FORMAT_LIST }, .numFormats = count,
                                       .formats = formats };
    return channel->ClientFormatList(channel, &list);
}

/* The caller holds the mutex; NULL data is a failed answer, the one for a format the Mac no longer has */
static UINT sendDataResponse(CliprdrClientContext* channel, const uint8_t* data, size_t length)
{
    if (length > UINT32_MAX)
    {
        data = NULL;
        length = 0;
    }
    const CLIPRDR_FORMAT_DATA_RESPONSE response = {
        .common = { .msgType = CB_FORMAT_DATA_RESPONSE,
                    .msgFlags = data ? CB_RESPONSE_OK : CB_RESPONSE_FAIL,
                    .dataLen = (UINT32)length },
        .requestedFormatData = data,
    };
    return channel->ClientFormatDataResponse(channel, &response);
}

/* The server starts the exchange: capabilities go back, then what the clipboard of the Mac offers */
static UINT onMonitorReady(CliprdrClientContext* channel, const CLIPRDR_MONITOR_READY* ready)
{
    (void)ready;
    VRCClipboard* clipboard = channel->custom;
    CLIPRDR_GENERAL_CAPABILITY_SET general = {
        .capabilitySetType = CB_CAPSTYPE_GENERAL,
        .capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN,
        .version = CB_CAPS_VERSION_2,
        .generalFlags = CB_USE_LONG_FORMAT_NAMES,
    };
    const CLIPRDR_CAPABILITIES capabilities = {
        .common = { .msgType = CB_CLIP_CAPS },
        .cCapabilitiesSets = 1,
        .capabilitySets = (CLIPRDR_CAPABILITY_SET*)&general,
    };

    pthread_mutex_lock(&clipboard->mutex);
    UINT result = channel->ClientCapabilities(channel, &capabilities);
    if (result == CHANNEL_RC_OK)
    {
        clipboard->ready = true;
        result = sendFormatList(channel, clipboard->offered);
    }
    pthread_mutex_unlock(&clipboard->mutex);
    return result;
}

/* The clipboard of the server changed: the list is acknowledged, and the app learns what it may paste */
static UINT onServerFormatList(CliprdrClientContext* channel, const CLIPRDR_FORMAT_LIST* list)
{
    VRCClipboard* clipboard = channel->custom;
    VRCClipboardFormat formats[VRC_CLIPBOARD_FORMAT_SLOTS];
    size_t count = 0;

    pthread_mutex_lock(&clipboard->mutex);
    memset(clipboard->remoteFormatIds, 0, sizeof(clipboard->remoteFormatIds));
    for (UINT32 i = 0; i < list->numFormats; i++)
    {
        const int32_t format = appFormat(&list->formats[i]);
        if (format != 0 && clipboard->remoteFormatIds[format] == 0)
        {
            clipboard->remoteFormatIds[format] = list->formats[i].formatId;
            formats[count++] = (VRCClipboardFormat)format;
        }
    }
    const CLIPRDR_FORMAT_LIST_RESPONSE response = {
        .common = { .msgType = CB_FORMAT_LIST_RESPONSE, .msgFlags = CB_RESPONSE_OK },
    };
    const UINT result = channel->ClientFormatListResponse(channel, &response);
    pthread_mutex_unlock(&clipboard->mutex);

    if (clipboard->callbacks->remoteClipboardChanged)
        clipboard->callbacks->remoteClipboardChanged(*clipboard->userData, formats, count);
    return result;
}

/* Something on the server pastes: the app gets the question, or the server a failed answer at once */
static UINT onServerFormatDataRequest(CliprdrClientContext* channel, const CLIPRDR_FORMAT_DATA_REQUEST* request)
{
    VRCClipboard* clipboard = channel->custom;
    int32_t asked = 0;

    for (int32_t format = 1; format < VRC_CLIPBOARD_FORMAT_SLOTS; format++)
        if (windowsFormatId(format) == request->requestedFormatId)
            asked = format;

    pthread_mutex_lock(&clipboard->mutex);
    const bool answerable = asked != 0 && (clipboard->offered & formatBit(asked)) &&
                            clipboard->callbacks->clipboardDataRequested;
    clipboard->serverAsks = answerable ? asked : 0;
    const UINT result = answerable ? CHANNEL_RC_OK : sendDataResponse(channel, NULL, 0);
    pthread_mutex_unlock(&clipboard->mutex);

    if (answerable)
        clipboard->callbacks->clipboardDataRequested(*clipboard->userData, (VRCClipboardFormat)asked);
    return result;
}

/* The answer to a copy from the server; the late answer to a copy that timed out is dropped */
static UINT onServerFormatDataResponse(CliprdrClientContext* channel, const CLIPRDR_FORMAT_DATA_RESPONSE* response)
{
    VRCClipboard* clipboard = channel->custom;

    pthread_mutex_lock(&clipboard->mutex);
    if (clipboard->lateAnswers > 0)
        clipboard->lateAnswers--;
    else if (clipboard->copyFormat != 0 && !clipboard->copySucceeded && !clipboard->copyData)
    {
        const bool ok = (response->common.msgFlags & CB_RESPONSE_OK) != 0;
        const size_t length = response->common.dataLen;
        if (ok && length > 0 && response->requestedFormatData)
        {
            clipboard->copyData = malloc(length);
            if (clipboard->copyData)
            {
                memcpy(clipboard->copyData, response->requestedFormatData, length);
                clipboard->copyLength = length;
                clipboard->copySucceeded = true;
            }
        }
        (void)SetEvent(clipboard->copyAnswered);
    }
    pthread_mutex_unlock(&clipboard->mutex);
    return CHANNEL_RC_OK;
}

bool vrcClipboardInit(VRCClipboard* clipboard, const VRCCallbacks* callbacks, void* const* userData)
{
    memset(clipboard, 0, sizeof(*clipboard));
    /* Static initializers cannot fail, so Destroy always meets valid mutexes */
    clipboard->mutex = (pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;
    clipboard->copyLock = (pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;
    clipboard->callbacks = callbacks;
    clipboard->userData = userData;
    clipboard->copyAnswered = CreateEventA(NULL, TRUE, FALSE, NULL);
    return clipboard->copyAnswered != NULL;
}

void vrcClipboardDestroy(VRCClipboard* clipboard)
{
    if (clipboard->copyAnswered)
        (void)CloseHandle(clipboard->copyAnswered);
    free(clipboard->copyData);
    pthread_mutex_destroy(&clipboard->copyLock);
    pthread_mutex_destroy(&clipboard->mutex);
}

void vrcClipboardAttach(VRCClipboard* clipboard, CliprdrClientContext* channel)
{
    pthread_mutex_lock(&clipboard->mutex);
    channel->custom = clipboard;
    channel->MonitorReady = onMonitorReady;
    channel->ServerFormatList = onServerFormatList;
    channel->ServerFormatDataRequest = onServerFormatDataRequest;
    channel->ServerFormatDataResponse = onServerFormatDataResponse;
    clipboard->channel = channel;
    clipboard->ready = false;
    clipboard->serverAsks = 0;
    clipboard->lateAnswers = 0;
    memset(clipboard->remoteFormatIds, 0, sizeof(clipboard->remoteFormatIds));
    pthread_mutex_unlock(&clipboard->mutex);
}

void vrcClipboardDetach(VRCClipboard* clipboard, CliprdrClientContext* channel)
{
    pthread_mutex_lock(&clipboard->mutex);
    if (clipboard->channel == channel)
    {
        channel->custom = NULL;
        clipboard->channel = NULL;
        clipboard->ready = false;
        clipboard->serverAsks = 0;
        memset(clipboard->remoteFormatIds, 0, sizeof(clipboard->remoteFormatIds));
        if (clipboard->copyFormat != 0)
            (void)SetEvent(clipboard->copyAnswered);
    }
    pthread_mutex_unlock(&clipboard->mutex);
}

VRCResult vrcClipboardOffer(VRCClipboard* clipboard, const VRCClipboardFormat* formats, size_t count)
{
    uint32_t offered = 0;

    if (count > 0 && !formats)
        return VRCResultInvalidArgument;
    for (size_t i = 0; i < count; i++)
    {
        if (!knownFormat(formats[i]))
            return VRCResultInvalidArgument;
        offered |= formatBit(formats[i]);
    }

    pthread_mutex_lock(&clipboard->mutex);
    clipboard->offered = offered;
    /* Before Monitor Ready the offer waits: it goes out as the first list of the channel */
    const bool sent = !clipboard->channel || !clipboard->ready ||
                      sendFormatList(clipboard->channel, offered) == CHANNEL_RC_OK;
    pthread_mutex_unlock(&clipboard->mutex);
    return sent ? VRCResultOK : VRCResultFailure;
}

VRCResult vrcClipboardProvide(VRCClipboard* clipboard, VRCClipboardFormat format, const void* data, size_t length)
{
    uint8_t* unicode = NULL;
    size_t unicodeLength = 0;

    if (!knownFormat(format) || (!data && length > 0))
        return VRCResultInvalidArgument;
    /* Converted before the lock: a long text must not hold the channel */
    if (data && !vrcTextToUnicode(data, length, &unicode, &unicodeLength))
        return VRCResultFailure;

    pthread_mutex_lock(&clipboard->mutex);
    VRCResult result = VRCResultInvalidState;
    if (clipboard->channel && clipboard->serverAsks == (int32_t)format)
    {
        clipboard->serverAsks = 0;
        result = sendDataResponse(clipboard->channel, unicode, unicodeLength) == CHANNEL_RC_OK ? VRCResultOK
                                                                                              : VRCResultFailure;
    }
    pthread_mutex_unlock(&clipboard->mutex);
    free(unicode);
    return result;
}

VRCResult vrcClipboardCopyRemote(VRCClipboard* clipboard, VRCClipboardFormat format, uint32_t timeoutMs,
                                 HANDLE abortEvent, void** data, size_t* length)
{
    if (!knownFormat(format) || !data || !length)
        return VRCResultInvalidArgument;
    *data = NULL;
    *length = 0;

    pthread_mutex_lock(&clipboard->copyLock);
    pthread_mutex_lock(&clipboard->mutex);
    VRCResult result = VRCResultInvalidState;
    const uint32_t formatId = clipboard->remoteFormatIds[format];
    if (clipboard->channel && formatId != 0)
    {
        const CLIPRDR_FORMAT_DATA_REQUEST request = {
            .common = { .msgType = CB_FORMAT_DATA_REQUEST },
            .requestedFormatId = formatId,
        };
        clipboard->copyFormat = format;
        clipboard->copySucceeded = false;
        (void)ResetEvent(clipboard->copyAnswered);
        result = clipboard->channel->ClientFormatDataRequest(clipboard->channel, &request) == CHANNEL_RC_OK
                     ? VRCResultOK
                     : VRCResultFailure;
        if (result != VRCResultOK)
            clipboard->copyFormat = 0;
    }
    pthread_mutex_unlock(&clipboard->mutex);

    if (result == VRCResultOK)
    {
        const HANDLE events[] = { clipboard->copyAnswered, abortEvent };
        const DWORD waited = WaitForMultipleObjects(abortEvent ? 2 : 1, events, FALSE, timeoutMs);

        pthread_mutex_lock(&clipboard->mutex);
        /* An answer may have come between the timeout and the lock: then it counts, and none is due later */
        const bool answered = WaitForSingleObject(clipboard->copyAnswered, 0) == WAIT_OBJECT_0;
        const bool timedOut = waited == WAIT_TIMEOUT && !answered;
        uint8_t* answer = clipboard->copyData;
        const size_t answerLength = clipboard->copyLength;
        const bool succeeded = clipboard->copySucceeded;
        clipboard->copyData = NULL;
        clipboard->copyLength = 0;
        clipboard->copySucceeded = false;
        clipboard->copyFormat = 0;
        if (timedOut && clipboard->channel)
            clipboard->lateAnswers++;
        pthread_mutex_unlock(&clipboard->mutex);

        if (timedOut)
            result = VRCResultTimeout;
        else if (!succeeded)
            result = VRCResultFailure;
        else
        {
            char* text = NULL;
            size_t textLength = 0;
            if (vrcTextFromUnicode(answer, answerLength, &text, &textLength))
            {
                *data = text;
                *length = textLength;
            }
            else
                result = VRCResultFailure;
        }
        free(answer);
    }
    pthread_mutex_unlock(&clipboard->copyLock);
    return result;
}
