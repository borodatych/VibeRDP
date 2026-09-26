/*
 * The clipboard channel of a session
 * Mac to Windows: the offer goes out as a format list, the server asks for data only when something pastes there
 * Windows to Mac: the format list of the server comes to the app, which asks for data only when the Mac pastes
 * Files add a second kind of question: the contents of one file of a list, by range
 */

#include "clipboard.h"
#include "cliphtml.h"
#include "clipimage.h"
#include "cliptext.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <freerdp/channels/cliprdr.h>
#include <winpr/user.h>
#include <winpr/wlog.h>

/* The exchange in the diagnostics log: formats, sizes and the order of the messages, never the data itself */
#define TAG "com.vibebrains.viberdp.clipboard"
/* Room for the names of all formats of the app in one line of the log */
#define FORMAT_NAMES_SIZE 64

/*
 * The ids this client gives the registered formats in its own lists: the server asks for data by them
 * Registered formats go by name, and each side numbers them as it likes, from 0xC000 up
 */
#define HTML_FORMAT_ID 0xC0A0u
#define RTF_FORMAT_ID 0xC0A1u
#define PNG_FORMAT_ID 0xC0A2u
#define FILES_FORMAT_ID 0xC0A3u

/* The size of the answer to a question about the size of a file: a 64-bit number */
#define FILE_SIZE_ANSWER 8u
/*
 * The range of a file a copy asks for at once: large enough that the round trips cost little,
 * small enough that progress moves and a cancel is heard soon
 */
#define RANGE_REQUEST_SIZE (1024u * 1024u)
/* The largest range the server gets at once, whatever it asks: the answer is held in memory */
#define RANGE_ANSWER_LIMIT (64u * 1024u * 1024u)
/* Files and folders a copy of the files of the server makes, as the Finder makes them */
#define COPIED_FILE_MODE 0644
#define COPIED_DIRECTORY_MODE 0755

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

/* The list of files of the server gives the app the names at its top; the files come with a copy of their own */
static bool filesFromWindows(const uint8_t* data, size_t length, void** out, size_t* outLength)
{
    VRCRemoteFiles* files = vrcRemoteFilesParse(data, length);
    if (!files)
        return false;
    const bool listed = vrcRemoteFilesTopLevel(files, (char**)out, outLength);
    vrcRemoteFilesFree(files);
    return listed;
}

/* A format of Windows that carries a format of the app, and the conversions between the two */
typedef struct WindowsFormat {
    VRCClipboardFormat app;
    /* The standard id, or the id this client gives a registered format in its lists */
    uint32_t id;
    /* The name of a registered format, NULL for a standard one */
    const char* name;
    /* Goes into the lists of this client; a format that does not, this client only takes */
    bool offered;
    /* NULL for files: their list is built by vrcLocalFilesCreate and kept for the questions about their contents */
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
    { VRCClipboardFormatText, CF_UNICODETEXT, NULL, true, textToWindows, textFromWindows },
    { VRCClipboardFormatHtml, HTML_FORMAT_ID, "HTML Format", true, htmlToWindows, htmlFromWindows },
    { VRCClipboardFormatRtf, RTF_FORMAT_ID, "Rich Text Format", true, rtfToWindows, rtfFromWindows },
    { VRCClipboardFormatImage, PNG_FORMAT_ID, "PNG", true, pngToWindows, pngFromWindows },
    { VRCClipboardFormatImage, CF_DIBV5, NULL, false, NULL, dibFromWindows },
    { VRCClipboardFormatImage, CF_DIB, NULL, true, dibToWindows, dibFromWindows },
    { VRCClipboardFormatFiles, FILES_FORMAT_ID, "FileGroupDescriptorW", true, NULL, filesFromWindows },
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

/* A format of the app as the log names it */
static const char* formatName(int32_t format)
{
    switch (format)
    {
        case VRCClipboardFormatText:
            return "text";
        case VRCClipboardFormatHtml:
            return "html";
        case VRCClipboardFormatRtf:
            return "rtf";
        case VRCClipboardFormatImage:
            return "image";
        case VRCClipboardFormatFiles:
            return "files";
        default:
            return "unknown";
    }
}

/* The formats of a set of bits as the log names them, "none" for an empty set */
static const char* formatNames(uint32_t set, char names[FORMAT_NAMES_SIZE])
{
    size_t used = 0;
    names[0] = '\0';
    for (int32_t format = 1; format < VRC_CLIPBOARD_FORMAT_SLOTS; format++)
    {
        if (set & formatBit(format))
            used += (size_t)snprintf(names + used, FORMAT_NAMES_SIZE - used, "%s%s", used ? " " : "",
                                     formatName(format));
    }
    return used ? names : "none";
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
        if (entry->id == id && entry->offered && (offered & formatBit(entry->app)))
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
        if (entry->offered && (offered & formatBit(entry->app)))
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
        /* Files go as contents, never as paths of the server; the engine keeps only what the server offers too */
        .generalFlags = CB_USE_LONG_FORMAT_NAMES | CB_STREAM_FILECLIP_ENABLED | CB_FILECLIP_NO_FILE_PATHS |
                        CB_HUGE_FILE_SUPPORT_ENABLED,
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
    char names[FORMAT_NAMES_SIZE];
    WLog_INFO(TAG, "channel ready, the first list of the Mac: %s, sent %s", formatNames(clipboard->offered, names),
              result == CHANNEL_RC_OK ? "ok" : "with an error");
    pthread_mutex_unlock(&clipboard->mutex);
    return result;
}

/* What the server takes, for the log: whether it locks its clipboard and how it names formats changes its answers */
static UINT onServerCapabilities(CliprdrClientContext* channel, const CLIPRDR_CAPABILITIES* capabilities)
{
    (void)channel;
    for (UINT32 i = 0; i < capabilities->cCapabilitiesSets; i++)
    {
        const CLIPRDR_CAPABILITY_SET* set = &capabilities->capabilitySets[i];
        if (set->capabilitySetType == CB_CAPSTYPE_GENERAL)
        {
            const CLIPRDR_GENERAL_CAPABILITY_SET* general = (const CLIPRDR_GENERAL_CAPABILITY_SET*)set;
            WLog_INFO(TAG, "the server takes: version %" PRIu32 ", flags 0x%08" PRIX32, general->version,
                      general->generalFlags);
        }
    }
    return CHANNEL_RC_OK;
}

/* The server took a list of the Mac or turned it down: a list it turned down leaves its clipboard as it was */
static UINT onServerFormatListResponse(CliprdrClientContext* channel, const CLIPRDR_FORMAT_LIST_RESPONSE* response)
{
    (void)channel;
    if (response->common.msgFlags & CB_RESPONSE_OK)
        WLog_INFO(TAG, "the server took the list of the Mac");
    else
        WLog_WARN(TAG, "the server turned down the list of the Mac: flags 0x%04" PRIX16, response->common.msgFlags);
    return CHANNEL_RC_OK;
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
    clipboard->remoteGeneration++;
    free(clipboard->remoteDescriptor);
    clipboard->remoteDescriptor = NULL;
    clipboard->remoteDescriptorLength = 0;
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
    uint32_t taken = 0;
    for (size_t i = 0; i < count; i++)
        taken |= formatBit(formats[i]);
    char names[FORMAT_NAMES_SIZE];
    WLog_INFO(TAG, "the server copied: list %" PRIu64 " of %" PRIu32 " formats, the Mac takes %s",
              clipboard->remoteGeneration, list->numFormats, formatNames(taken, names));
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
    if (clipboard->serverAsks != NO_ENTRY)
        WLog_WARN(TAG, "the server asks again before the answer about %s",
                  formatName(windowsFormats[clipboard->serverAsks].app));
    clipboard->serverAsks = answerable ? entry : NO_ENTRY;
    const UINT result = answerable ? CHANNEL_RC_OK : sendDataResponse(channel, NULL, 0);
    if (answerable)
        WLog_INFO(TAG, "the server pastes format 0x%04" PRIX32 ": %s, the app is asked",
                  request->requestedFormatId, formatName(windowsFormats[entry].app));
    else
        WLog_INFO(TAG, "the server pastes format 0x%04" PRIX32 ", not in the list of the Mac: a failed answer",
                  request->requestedFormatId);
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
    WLog_INFO(TAG, "the server answered: %s, %" PRIu32 " bytes%s",
              (response->common.msgFlags & CB_RESPONSE_OK) ? "ok" : "failed", response->common.dataLen,
              clipboard->lateAnswers > 0 ? ", late: dropped" : "");
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

/* The caller holds the mutex; NULL data is a failed answer */
static UINT sendRangeResponse(CliprdrClientContext* channel, uint32_t stream, const uint8_t* data, uint32_t length)
{
    const CLIPRDR_FILE_CONTENTS_RESPONSE response = {
        .common = { .msgType = CB_FILECONTENTS_RESPONSE, .msgFlags = data ? CB_RESPONSE_OK : CB_RESPONSE_FAIL },
        .streamId = stream,
        /* The engine sizes the message by this field, not by dataLen */
        .cbRequested = data ? length : 0,
        .requestedData = data,
    };
    return channel->ClientFileContentsResponse(channel, &response);
}

/*
 * Something on the server pastes the files of the Mac and reads one: its size or a range of it
 * The list stays under the mutex while the range is read, so a new list cannot free it meanwhile
 */
static UINT onServerFileContentsRequest(CliprdrClientContext* channel, const CLIPRDR_FILE_CONTENTS_REQUEST* request)
{
    VRCClipboard* clipboard = channel->custom;

    pthread_mutex_lock(&clipboard->mutex);
    const VRCLocalFiles* files = clipboard->localFiles;
    const bool known = files && request->listIndex < files->count && !files->items[request->listIndex].directory;
    UINT result;
    if (known && (request->dwFlags & FILECONTENTS_SIZE))
    {
        uint8_t size[FILE_SIZE_ANSWER];
        const uint64_t bytes = files->items[request->listIndex].size;
        for (unsigned i = 0; i < FILE_SIZE_ANSWER; i++)
            size[i] = (uint8_t)(bytes >> (8 * i));
        result = sendRangeResponse(channel, request->streamId, size, FILE_SIZE_ANSWER);
    }
    else if (known && (request->dwFlags & FILECONTENTS_RANGE))
    {
        const uint64_t position = ((uint64_t)request->nPositionHigh << 32) | request->nPositionLow;
        const uint32_t wanted = request->cbRequested < RANGE_ANSWER_LIMIT ? request->cbRequested : RANGE_ANSWER_LIMIT;
        uint8_t* data = malloc(wanted ? wanted : 1);
        uint32_t read = 0;
        const bool ok = data && vrcLocalFilesRead(files, request->listIndex, position, wanted, data, &read);
        result = sendRangeResponse(channel, request->streamId, ok ? data : NULL, read);
        free(data);
    }
    else
        result = sendRangeResponse(channel, request->streamId, NULL, 0);
    pthread_mutex_unlock(&clipboard->mutex);
    return result;
}

/* A range of a file of the server; one for a request that no longer waits is dropped by its number */
static UINT onServerFileContentsResponse(CliprdrClientContext* channel,
                                         const CLIPRDR_FILE_CONTENTS_RESPONSE* response)
{
    VRCClipboard* clipboard = channel->custom;

    pthread_mutex_lock(&clipboard->mutex);
    if (clipboard->rangeStream != 0 && response->streamId == clipboard->rangeStream && !clipboard->rangeSucceeded)
    {
        /* The engine gives the length of the data here: dataLen counts the number of the request too */
        const size_t length = response->cbRequested;
        if ((response->common.msgFlags & CB_RESPONSE_OK) && (length == 0 || response->requestedData))
        {
            clipboard->rangeData = malloc(length ? length : 1);
            if (clipboard->rangeData)
            {
                memcpy(clipboard->rangeData, response->requestedData, length);
                clipboard->rangeLength = length;
                clipboard->rangeSucceeded = true;
            }
        }
        (void)SetEvent(clipboard->rangeAnswered);
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
    clipboard->rangeAnswered = CreateEventA(NULL, TRUE, FALSE, NULL);
    return clipboard->copyAnswered != NULL && clipboard->rangeAnswered != NULL;
}

void vrcClipboardDestroy(VRCClipboard* clipboard)
{
    if (clipboard->copyAnswered)
        (void)CloseHandle(clipboard->copyAnswered);
    if (clipboard->rangeAnswered)
        (void)CloseHandle(clipboard->rangeAnswered);
    free(clipboard->copyData);
    free(clipboard->rangeData);
    free(clipboard->remoteDescriptor);
    vrcLocalFilesFree(clipboard->localFiles);
    pthread_mutex_destroy(&clipboard->copyLock);
    pthread_mutex_destroy(&clipboard->mutex);
}

void vrcClipboardAttach(VRCClipboard* clipboard, CliprdrClientContext* channel)
{
    pthread_mutex_lock(&clipboard->mutex);
    channel->custom = clipboard;
    channel->MonitorReady = onMonitorReady;
    channel->ServerCapabilities = onServerCapabilities;
    channel->ServerFormatListResponse = onServerFormatListResponse;
    channel->ServerFormatList = onServerFormatList;
    channel->ServerFormatDataRequest = onServerFormatDataRequest;
    channel->ServerFormatDataResponse = onServerFormatDataResponse;
    channel->ServerFileContentsRequest = onServerFileContentsRequest;
    channel->ServerFileContentsResponse = onServerFileContentsResponse;
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
        if (clipboard->rangeStream != 0)
            (void)SetEvent(clipboard->rangeAnswered);
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
    clipboard->offers++;
    /* Before Monitor Ready the offer waits: it goes out as the first list of the channel */
    const bool waits = !clipboard->channel || !clipboard->ready;
    const bool sent = waits || sendFormatList(clipboard->channel, offered) == CHANNEL_RC_OK;
    char names[FORMAT_NAMES_SIZE];
    WLog_INFO(TAG, "the Mac copied: offer %" PRIu64 " of %s, %s", clipboard->offers, formatNames(offered, names),
              waits ? "waits for the channel" : sent ? "list sent" : "the list failed");
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
    {
        WLog_WARN(TAG, "an answer of %s dropped: the server waits for %s", formatName(format),
                  entry == NO_ENTRY ? "nothing" : formatName(windowsFormats[entry].app));
        return VRCResultInvalidState;
    }
    /* Converted outside the lock: a long text, a large image or a deep folder must not hold the channel */
    VRCLocalFiles* files = NULL;
    if (data && format == VRCClipboardFormatFiles)
    {
        files = vrcLocalFilesCreate(data, length);
        if (!files)
            return VRCResultFailure;
    }
    else if (data && !windowsFormats[entry].toWindows(data, length, &converted, &convertedLength))
        return VRCResultFailure;

    pthread_mutex_lock(&clipboard->mutex);
    VRCResult result = VRCResultInvalidState;
    if (clipboard->channel && clipboard->serverAsks == entry)
    {
        clipboard->serverAsks = NO_ENTRY;
        const uint8_t* answer = files ? files->descriptor : converted;
        const size_t answerLength = files ? files->descriptorLength : convertedLength;
        result = sendDataResponse(clipboard->channel, answer, answerLength) == CHANNEL_RC_OK ? VRCResultOK
                                                                                            : VRCResultFailure;
        if (answer)
            WLog_INFO(TAG, "answer to the server: %s, %zu bytes from %zu of the Mac, sent %s", formatName(format),
                      answerLength, length, result == VRCResultOK ? "ok" : "with an error");
        else
            WLog_INFO(TAG, "answer to the server: the Mac no longer holds %s, a failed answer", formatName(format));
        /* The server reads the files of the list it got */
        if (files && result == VRCResultOK)
        {
            VRCLocalFiles* previous = clipboard->localFiles;
            clipboard->localFiles = files;
            files = previous;
        }
    }
    else
        WLog_WARN(TAG, "an answer of %s dropped: the channel went down or the server asked anew meanwhile",
                  formatName(format));
    pthread_mutex_unlock(&clipboard->mutex);
    vrcLocalFilesFree(files);
    free(converted);
    return result;
}

/*
 * Fetches the data of a format of the server as it came, holding copyLock
 * *generation tells which list of the server the data belongs to; *entry which format of Windows it is in
 */
static VRCResult fetchRemote(VRCClipboard* clipboard, VRCClipboardFormat format, uint32_t timeoutMs, HANDLE abortEvent,
                             uint8_t** data, size_t* length, int32_t* entry, uint64_t* generation)
{
    pthread_mutex_lock(&clipboard->mutex);
    VRCResult result = VRCResultInvalidState;
    const uint32_t formatId = clipboard->remoteFormatIds[format];
    *entry = clipboard->remoteEntries[format];
    *generation = clipboard->remoteGeneration;
    if (clipboard->channel && formatId != 0)
    {
        const CLIPRDR_FORMAT_DATA_REQUEST request = {
            .common = { .msgType = CB_FORMAT_DATA_REQUEST },
            .requestedFormatId = formatId,
        };
        clipboard->copyEntry = *entry;
        clipboard->copySucceeded = false;
        (void)ResetEvent(clipboard->copyAnswered);
        result = clipboard->channel->ClientFormatDataRequest(clipboard->channel, &request) == CHANNEL_RC_OK
                     ? VRCResultOK
                     : VRCResultFailure;
        if (result != VRCResultOK)
            clipboard->copyEntry = NO_ENTRY;
    }
    WLog_INFO(TAG, "the Mac pastes %s of list %" PRIu64 ": %s", formatName(format), *generation,
              formatId == 0 ? "the server does not offer it" : result == VRCResultOK ? "asked" : "the request failed");
    pthread_mutex_unlock(&clipboard->mutex);
    if (result != VRCResultOK)
        return result;

    const HANDLE events[] = { clipboard->copyAnswered, abortEvent };
    const DWORD waited = WaitForMultipleObjects(abortEvent ? 2 : 1, events, FALSE, timeoutMs);

    pthread_mutex_lock(&clipboard->mutex);
    /* An answer may have come between the timeout and the lock: then it counts, and none is due later */
    const bool answered = WaitForSingleObject(clipboard->copyAnswered, 0) == WAIT_OBJECT_0;
    const bool timedOut = waited == WAIT_TIMEOUT && !answered;
    *data = clipboard->copyData;
    *length = clipboard->copyLength;
    const bool succeeded = clipboard->copySucceeded;
    clipboard->copyData = NULL;
    clipboard->copyLength = 0;
    clipboard->copySucceeded = false;
    clipboard->copyEntry = NO_ENTRY;
    if (timedOut && clipboard->channel)
        clipboard->lateAnswers++;
    pthread_mutex_unlock(&clipboard->mutex);

    if (timedOut)
        WLog_WARN(TAG, "no answer from the server about %s in %" PRIu32 " ms", formatName(format), timeoutMs);
    if (succeeded)
        return VRCResultOK;
    free(*data);
    *data = NULL;
    return timedOut ? VRCResultTimeout : VRCResultFailure;
}

/* Keeps the list of files of the server for the copy of its files, unless the server has a new list by now */
static void keepDescriptor(VRCClipboard* clipboard, uint8_t* descriptor, size_t length, uint64_t generation)
{
    pthread_mutex_lock(&clipboard->mutex);
    if (generation == clipboard->remoteGeneration)
    {
        free(clipboard->remoteDescriptor);
        clipboard->remoteDescriptor = descriptor;
        clipboard->remoteDescriptorLength = length;
        descriptor = NULL;
    }
    pthread_mutex_unlock(&clipboard->mutex);
    free(descriptor);
}

VRCResult vrcClipboardCopyRemote(VRCClipboard* clipboard, VRCClipboardFormat format, uint32_t timeoutMs,
                                 HANDLE abortEvent, void** data, size_t* length)
{
    if (!knownFormat(format) || !data || !length)
        return VRCResultInvalidArgument;
    *data = NULL;
    *length = 0;

    pthread_mutex_lock(&clipboard->copyLock);
    uint8_t* answer = NULL;
    size_t answerLength = 0;
    int32_t entry = NO_ENTRY;
    uint64_t generation = 0;
    VRCResult result =
        fetchRemote(clipboard, format, timeoutMs, abortEvent, &answer, &answerLength, &entry, &generation);
    if (result == VRCResultOK && !windowsFormats[entry].fromWindows(answer, answerLength, data, length))
        result = VRCResultFailure;
    if (result == VRCResultOK && format == VRCClipboardFormatFiles)
    {
        keepDescriptor(clipboard, answer, answerLength, generation);
        answer = NULL;
    }
    free(answer);
    pthread_mutex_unlock(&clipboard->copyLock);
    return result;
}

/* Asks the server for its size of a file or for a range of it and waits for the answer, holding copyLock */
static VRCResult fetchRange(VRCClipboard* clipboard, uint32_t index, uint32_t flags, uint64_t position,
                            uint32_t requested, uint32_t timeoutMs, HANDLE abortEvent, uint8_t** data, size_t* length)
{
    pthread_mutex_lock(&clipboard->mutex);
    VRCResult result = VRCResultInvalidState;
    if (clipboard->channel)
    {
        clipboard->lastStream = clipboard->lastStream == UINT32_MAX ? 1 : clipboard->lastStream + 1;
        const CLIPRDR_FILE_CONTENTS_REQUEST request = {
            .common = { .msgType = CB_FILECONTENTS_REQUEST },
            .streamId = clipboard->lastStream,
            .listIndex = index,
            .dwFlags = flags,
            .nPositionLow = (uint32_t)position,
            .nPositionHigh = (uint32_t)(position >> 32),
            .cbRequested = requested,
        };
        clipboard->rangeStream = clipboard->lastStream;
        clipboard->rangeSucceeded = false;
        (void)ResetEvent(clipboard->rangeAnswered);
        result = clipboard->channel->ClientFileContentsRequest(clipboard->channel, &request) == CHANNEL_RC_OK
                     ? VRCResultOK
                     : VRCResultFailure;
        if (result != VRCResultOK)
            clipboard->rangeStream = 0;
    }
    pthread_mutex_unlock(&clipboard->mutex);
    if (result != VRCResultOK)
        return result;

    const HANDLE events[] = { clipboard->rangeAnswered, abortEvent };
    const DWORD waited = WaitForMultipleObjects(abortEvent ? 2 : 1, events, FALSE, timeoutMs);

    pthread_mutex_lock(&clipboard->mutex);
    const bool answered = WaitForSingleObject(clipboard->rangeAnswered, 0) == WAIT_OBJECT_0;
    *data = clipboard->rangeData;
    *length = clipboard->rangeLength;
    const bool succeeded = clipboard->rangeSucceeded;
    clipboard->rangeData = NULL;
    clipboard->rangeLength = 0;
    clipboard->rangeSucceeded = false;
    /* A late answer carries a number no request waits for, and is dropped */
    clipboard->rangeStream = 0;
    pthread_mutex_unlock(&clipboard->mutex);

    if (succeeded)
        return VRCResultOK;
    free(*data);
    *data = NULL;
    return waited == WAIT_TIMEOUT && !answered ? VRCResultTimeout : VRCResultFailure;
}

/* The state of one copy of the files of the server */
typedef struct FileCopy {
    VRCClipboard* clipboard;
    uint32_t timeoutMs;
    HANDLE abortEvent;
    VRCFileProgress progress;
    void* context;
    uint64_t done;
    uint64_t total;
} FileCopy;

/* The size of a file the list of the server does not give */
static VRCResult askSize(FileCopy* copy, uint32_t index, uint64_t* size)
{
    uint8_t* answer = NULL;
    size_t length = 0;
    VRCResult result = fetchRange(copy->clipboard, index, FILECONTENTS_SIZE, 0, FILE_SIZE_ANSWER, copy->timeoutMs,
                                  copy->abortEvent, &answer, &length);
    if (result == VRCResultOK && length < FILE_SIZE_ANSWER)
        result = VRCResultFailure;
    if (result == VRCResultOK)
    {
        *size = 0;
        for (unsigned i = 0; i < FILE_SIZE_ANSWER; i++)
            *size |= (uint64_t)answer[i] << (8 * i);
    }
    free(answer);
    return result;
}

static bool report(FileCopy* copy)
{
    return !copy->progress || copy->progress(copy->context, copy->done, copy->total);
}

/* Creates the folders on the way to a name; the name itself is left to the caller */
static bool makeParents(int root, const char* name)
{
    char path[PATH_MAX];
    if (strlen(name) >= sizeof(path))
        return false;
    strcpy(path, name);
    for (char* slash = strchr(path, '/'); slash; slash = strchr(slash + 1, '/'))
    {
        *slash = '\0';
        if (mkdirat(root, path, COPIED_DIRECTORY_MODE) != 0 && errno != EEXIST)
            return false;
        *slash = '/';
    }
    return true;
}

/* One file of the server into the folder, range by range */
static VRCResult copyFile(FileCopy* copy, int root, uint32_t index, const VRCRemoteFile* item, uint64_t size)
{
    if (!makeParents(root, item->name))
        return VRCResultFailure;
    /* A fresh name only, never through a link: the folder of the copy holds nothing but what the copy made */
    const int file = openat(root, item->name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, COPIED_FILE_MODE);
    if (file < 0)
        return VRCResultFailure;

    VRCResult result = VRCResultOK;
    for (uint64_t position = 0; result == VRCResultOK && position < size;)
    {
        const uint64_t left = size - position;
        const uint32_t requested = left < RANGE_REQUEST_SIZE ? (uint32_t)left : RANGE_REQUEST_SIZE;
        uint8_t* data = NULL;
        size_t length = 0;
        result = fetchRange(copy->clipboard, index, FILECONTENTS_RANGE, position, requested, copy->timeoutMs,
                            copy->abortEvent, &data, &length);
        /* A file that ends before its size in the list is broken: the copy must not stop half way as if done */
        if (result == VRCResultOK && (length == 0 || length > left))
            result = VRCResultFailure;
        for (size_t written = 0; result == VRCResultOK && written < length;)
        {
            const ssize_t put = write(file, data + written, length - written);
            if (put <= 0)
                result = VRCResultFailure;
            else
                written += (size_t)put;
        }
        free(data);
        if (result == VRCResultOK)
        {
            position += length;
            copy->done += length;
            if (!report(copy))
                result = VRCResultCancelled;
        }
    }
    if (result == VRCResultOK && item->hasModified)
    {
        const struct timespec times[2] = { { .tv_nsec = UTIME_OMIT }, item->modified };
        (void)futimens(file, times);
    }
    close(file);
    return result;
}

VRCResult vrcClipboardCopyRemoteFiles(VRCClipboard* clipboard, const char* directory, uint32_t timeoutMs,
                                      HANDLE abortEvent, VRCFileProgress progress, void* context)
{
    if (!directory)
        return VRCResultInvalidArgument;
    const int root = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (root < 0)
        return VRCResultInvalidArgument;

    pthread_mutex_lock(&clipboard->copyLock);
    /* The list fetched for the names at the top serves the copy, unless the server has a new one by now */
    pthread_mutex_lock(&clipboard->mutex);
    size_t length = clipboard->remoteDescriptorLength;
    uint8_t* descriptor = clipboard->remoteDescriptor ? malloc(length) : NULL;
    if (descriptor)
        memcpy(descriptor, clipboard->remoteDescriptor, length);
    pthread_mutex_unlock(&clipboard->mutex);
    VRCResult result = VRCResultOK;
    if (!descriptor)
    {
        int32_t entry = NO_ENTRY;
        uint64_t generation = 0;
        result = fetchRemote(clipboard, VRCClipboardFormatFiles, timeoutMs, abortEvent, &descriptor, &length, &entry,
                             &generation);
    }
    VRCRemoteFiles* files = result == VRCResultOK ? vrcRemoteFilesParse(descriptor, length) : NULL;
    free(descriptor);
    if (result == VRCResultOK && !files)
        result = VRCResultFailure;

    FileCopy copy = { clipboard, timeoutMs, abortEvent, progress, context, 0, 0 };
    uint64_t* sizes = files ? calloc(files->count ? files->count : 1, sizeof(*sizes)) : NULL;
    if (result == VRCResultOK && !sizes)
        result = VRCResultFailure;
    /* The sizes first: progress needs the total before the first byte */
    for (size_t i = 0; result == VRCResultOK && i < files->count; i++)
    {
        const VRCRemoteFile* item = &files->items[i];
        if (item->directory)
            continue;
        if (item->hasSize)
            sizes[i] = item->size;
        else
            result = askSize(&copy, (uint32_t)i, &sizes[i]);
        copy.total += sizes[i];
    }
    if (result == VRCResultOK && !report(&copy))
        result = VRCResultCancelled;

    for (size_t i = 0; result == VRCResultOK && i < files->count; i++)
    {
        const VRCRemoteFile* item = &files->items[i];
        if (item->directory)
        {
            if (!makeParents(root, item->name) ||
                (mkdirat(root, item->name, COPIED_DIRECTORY_MODE) != 0 && errno != EEXIST))
                result = VRCResultFailure;
        }
        else
            result = copyFile(&copy, root, (uint32_t)i, item, sizes[i]);
    }
    free(sizes);
    vrcRemoteFilesFree(files);
    pthread_mutex_unlock(&clipboard->copyLock);
    close(root);
    return result;
}
