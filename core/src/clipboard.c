/*
 * The clipboard channel of a session
 * Mac to Windows: the offer goes out as a format list, the server asks for data only when something pastes there
 * Windows to Mac: the format list of the server comes to the app, which asks for data only when the Mac pastes
 */

#include "clipboard.h"
#include "cliphtml.h"
#include "clipimage.h"
#include "cliptext.h"

#include <stdlib.h>
#include <string.h>

#include <freerdp/channels/cliprdr.h>
#include <winpr/user.h>

/*
 * The ids this client gives the registered formats in its own lists: the server asks for data by them
 * Registered formats go by name, and each side numbers them as it likes, from 0xC000 up
 */
#define HTML_FORMAT_ID 0xC0A0u
#define RTF_FORMAT_ID 0xC0A1u
#define PNG_FORMAT_ID 0xC0A2u

/* RTF is ASCII: Windows keeps it zero-terminated, the Mac without the zero */
static bool rtfToWindows(const void* rtf, size_t length, uint8_t** out, size_t* outLength)
{
    if (length == SIZE_MAX)
        return false;
    *out = malloc(length + 1);
    if (!*out)
        return false;
    memcpy(*out, rtf, length);
    (*out)[length] = 0;
    *outLength = length + 1;
    return true;
}

static bool rtfFromWindows(const uint8_t* rtf, size_t length, void** out, size_t* outLength)
{
    while (length > 0 && rtf[length - 1] == 0)
        length--;
    char* copy = malloc(length + 1);
    if (!copy)
        return false;
    memcpy(copy, rtf, length);
    copy[length] = '\0';
    *out = copy;
    *outLength = length;
    return true;
}

static bool textToWindows(const void* data, size_t length, uint8_t** out, size_t* outLength)
{
    return vrcTextToUnicode(data, length, out, outLength);
}

static bool textFromWindows(const uint8_t* data, size_t length, void** out, size_t* outLength)
{
    return vrcTextFromUnicode(data, length, (char**)out, outLength);
}

static bool htmlToWindows(const void* data, size_t length, uint8_t** out, size_t* outLength)
{
    return vrcHtmlToWindows(data, length, out, outLength);
}

static bool htmlFromWindows(const uint8_t* data, size_t length, void** out, size_t* outLength)
{
    return vrcHtmlFromWindows(data, length, (char**)out, outLength);
}

/* PNG is the same file on both sides */
static bool pngToWindows(const void* data, size_t length, uint8_t** out, size_t* outLength)
{
    *out = malloc(length > 0 ? length : 1);
    if (!*out)
        return false;
    memcpy(*out, data, length);
    *outLength = length;
    return true;
}

static bool pngFromWindows(const uint8_t* data, size_t length, void** out, size_t* outLength)
{
    return pngToWindows(data, length, (uint8_t**)out, outLength);
}

static bool dibToWindows(const void* data, size_t length, uint8_t** out, size_t* outLength)
{
    return vrcPngToDib(data, length, out, outLength);
}

static bool dibFromWindows(const uint8_t* data, size_t length, void** out, size_t* outLength)
{
    return vrcDibToPng(data, length, (uint8_t**)out, outLength);
}

/* A format of Windows that carries a format of the app, and the conversions between the two */
typedef struct WindowsFormat {
    VRCClipboardFormat app;
    /* The standard id, or the id this client gives a registered format in its lists */
    uint32_t id;
    /* The name of a registered format, NULL for a standard one */
    const char* name;
    /* NULL for a format this client only takes: only formats with it go into the lists of this client */
    bool (*toWindows)(const void* data, size_t length, uint8_t** out, size_t* outLength);
    bool (*fromWindows)(const uint8_t* data, size_t length, void** out, size_t* outLength);
} WindowsFormat;

/*
 * The formats in the order this client prefers them when the server offers several for one format of the app
 * Windows makes CF_TEXT from CF_UNICODETEXT, and CF_BITMAP and CF_DIBV5 from CF_DIB, so those are not offered
 * An image goes out both as PNG, which keeps transparency for the programs that read it, and as CF_DIB for the rest;
 * from the server PNG is taken first, then CF_DIBV5, which may hold alpha, then CF_DIB
 */
static const WindowsFormat windowsFormats[] = {
    { VRCClipboardFormatText, CF_UNICODETEXT, NULL, textToWindows, textFromWindows },
    { VRCClipboardFormatHtml, HTML_FORMAT_ID, "HTML Format", htmlToWindows, htmlFromWindows },
    { VRCClipboardFormatRtf, RTF_FORMAT_ID, "Rich Text Format", rtfToWindows, rtfFromWindows },
    { VRCClipboardFormatImage, PNG_FORMAT_ID, "PNG", pngToWindows, pngFromWindows },
    { VRCClipboardFormatImage, CF_DIBV5, NULL, NULL, dibFromWindows },
    { VRCClipboardFormatImage, CF_DIB, NULL, dibToWindows, dibFromWindows },
};

#define WINDOWS_FORMAT_COUNT (sizeof(windowsFormats) / sizeof(windowsFormats[0]))

static uint32_t formatBit(int32_t format)
{
    return 1u << (uint32_t)format;
}

static bool knownFormat(int32_t format)
{
    return format > 0 && format < VRC_CLIPBOARD_FORMAT_SLOTS;
}

/* The entry of a format in a list of the server, -1 for one the app does not take */
static int32_t entryOfServerFormat(const CLIPRDR_FORMAT* format)
{
    for (size_t i = 0; i < WINDOWS_FORMAT_COUNT; i++)
    {
        const WindowsFormat* entry = &windowsFormats[i];
        const bool matches = entry->name ? format->formatName && strcmp(format->formatName, entry->name) == 0
                                         : format->formatId == entry->id;
        if (matches)
            return (int32_t)i;
    }
    return -1;
}

/* The entry of an id in the lists of this client, -1 for an id this client did not offer */
static int32_t entryOfOwnId(uint32_t id, uint32_t offered)
{
    for (size_t i = 0; i < WINDOWS_FORMAT_COUNT; i++)
    {
        const WindowsFormat* entry = &windowsFormats[i];
        if (entry->id == id && entry->toWindows && (offered & formatBit(entry->app)))
            return (int32_t)i;
    }
    return -1;
}

/* The caller holds the mutex: the channel stays up while the list goes out */
static UINT sendFormatList(CliprdrClientContext* channel, uint32_t offered)
{
    CLIPRDR_FORMAT formats[WINDOWS_FORMAT_COUNT] = { 0 };
    UINT32 count = 0;

    for (size_t i = 0; i < WINDOWS_FORMAT_COUNT; i++)
    {
        const WindowsFormat* entry = &windowsFormats[i];
        if (entry->toWindows && (offered & formatBit(entry->app)))
        {
            formats[count].formatId = entry->id;
            /* The engine only reads the name, whatever its type says */
            formats[count].formatName = (char*)entry->name;
            count++;
        }
    }

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
    memset(clipboard->remoteEntries, 0, sizeof(clipboard->remoteEntries));
    for (UINT32 i = 0; i < list->numFormats; i++)
    {
        const int32_t entry = entryOfServerFormat(&list->formats[i]);
        if (entry < 0)
            continue;
        const VRCClipboardFormat format = windowsFormats[entry].app;
        if (clipboard->remoteFormatIds[format] == 0)
            formats[count++] = format;
        /* The table lists the formats of Windows best first */
        else if (clipboard->remoteEntries[format] <= entry)
            continue;
        clipboard->remoteFormatIds[format] = list->formats[i].formatId;
        clipboard->remoteEntries[format] = entry;
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

    pthread_mutex_lock(&clipboard->mutex);
    const int32_t entry = entryOfOwnId(request->requestedFormatId, clipboard->offered);
    const bool answerable = entry >= 0 && clipboard->callbacks->clipboardDataRequested;
    clipboard->serverAsks = answerable ? entry : NO_ENTRY;
    const UINT result = answerable ? CHANNEL_RC_OK : sendDataResponse(channel, NULL, 0);
    pthread_mutex_unlock(&clipboard->mutex);

    if (answerable)
        clipboard->callbacks->clipboardDataRequested(*clipboard->userData, windowsFormats[entry].app);
    return result;
}

/* The answer to a copy from the server; the late answer to a copy that timed out is dropped */
static UINT onServerFormatDataResponse(CliprdrClientContext* channel, const CLIPRDR_FORMAT_DATA_RESPONSE* response)
{
    VRCClipboard* clipboard = channel->custom;

    pthread_mutex_lock(&clipboard->mutex);
    if (clipboard->lateAnswers > 0)
        clipboard->lateAnswers--;
    else if (clipboard->copyEntry != NO_ENTRY && !clipboard->copySucceeded && !clipboard->copyData)
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
    clipboard->serverAsks = NO_ENTRY;
    clipboard->copyEntry = NO_ENTRY;
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
    clipboard->serverAsks = NO_ENTRY;
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
        clipboard->serverAsks = NO_ENTRY;
        memset(clipboard->remoteFormatIds, 0, sizeof(clipboard->remoteFormatIds));
        if (clipboard->copyEntry != NO_ENTRY)
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
    uint8_t* converted = NULL;
    size_t convertedLength = 0;

    if (!knownFormat(format) || (!data && length > 0))
        return VRCResultInvalidArgument;

    pthread_mutex_lock(&clipboard->mutex);
    const int32_t entry = clipboard->serverAsks;
    pthread_mutex_unlock(&clipboard->mutex);
    if (entry == NO_ENTRY || windowsFormats[entry].app != format)
        return VRCResultInvalidState;
    /* Converted outside the lock: a long text or a large image must not hold the channel */
    if (data && !windowsFormats[entry].toWindows(data, length, &converted, &convertedLength))
        return VRCResultFailure;

    pthread_mutex_lock(&clipboard->mutex);
    VRCResult result = VRCResultInvalidState;
    if (clipboard->channel && clipboard->serverAsks == entry)
    {
        clipboard->serverAsks = NO_ENTRY;
        result = sendDataResponse(clipboard->channel, converted, convertedLength) == CHANNEL_RC_OK ? VRCResultOK
                                                                                                  : VRCResultFailure;
    }
    pthread_mutex_unlock(&clipboard->mutex);
    free(converted);
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
    const int32_t entry = clipboard->remoteEntries[format];
    if (clipboard->channel && formatId != 0)
    {
        const CLIPRDR_FORMAT_DATA_REQUEST request = {
            .common = { .msgType = CB_FORMAT_DATA_REQUEST },
            .requestedFormatId = formatId,
        };
        clipboard->copyEntry = entry;
        clipboard->copySucceeded = false;
        (void)ResetEvent(clipboard->copyAnswered);
        result = clipboard->channel->ClientFormatDataRequest(clipboard->channel, &request) == CHANNEL_RC_OK
                     ? VRCResultOK
                     : VRCResultFailure;
        if (result != VRCResultOK)
            clipboard->copyEntry = NO_ENTRY;
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
        clipboard->copyEntry = NO_ENTRY;
        if (timedOut && clipboard->channel)
            clipboard->lateAnswers++;
        pthread_mutex_unlock(&clipboard->mutex);

        if (timedOut)
            result = VRCResultTimeout;
        else if (!succeeded)
            result = VRCResultFailure;
        else if (!windowsFormats[entry].fromWindows(answer, answerLength, data, length))
            result = VRCResultFailure;
        free(answer);
    }
    pthread_mutex_unlock(&clipboard->copyLock);
    return result;
}
