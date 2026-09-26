/*
 * Clipboard channel tests: core/src/clipboard.c against a stand-in for the CLIPRDR channel of the engine
 * The stand-in records what the core sends; a test plays the server by calling the handlers the core installed
 * Usage: clipboardTests <test name>; CTest registers every test separately
 */

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <freerdp/channels/cliprdr.h>
#include <winpr/sysinfo.h>
#include <winpr/user.h>

#include "clipboard.h"
#include "clipimage.h"
#include "fileTrees.h"

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

/* Long enough for a thread to reach its wait, short enough to keep the tests quick */
#define SETTLE_US 50000
#define ANSWER_TIMEOUT_MS 5000
#define SHORT_TIMEOUT_MS 50
#define MAX_FORMATS 8

/* Format ids the server gave registered formats, as Windows numbers them */
#define REGISTERED_FORMAT_ID 0xC0FFu
#define SERVER_HTML_ID 0xC123u
#define SERVER_RTF_ID 0xC124u
#define SERVER_OTHER_ID 0xC125u
#define SERVER_PNG_ID 0xC126u
#define SERVER_FILES_ID 0xC127u
/* Room for the list of files of the tests: a count and three descriptors of 592 bytes */
#define RESPONSE_ROOM 4096
#define FORMAT_NAME_SIZE 32

/* What the core sent on the channel, and what it told the app */
typedef struct Channel {
    CliprdrClientContext context;
    int capabilities;
    int formatLists;
    UINT32 lastFormatCount;
    UINT32 lastFormatIds[MAX_FORMATS];
    char lastFormatNames[MAX_FORMATS][FORMAT_NAME_SIZE];
    int listResponses;
    /* Read by the thread that plays the server while a copy runs */
    atomic_int dataRequests;
    UINT32 lastRequestedFormatId;
    int dataResponses;
    UINT16 lastResponseFlags;
    uint8_t lastResponse[RESPONSE_ROOM];
    UINT32 lastResponseLength;
    int remoteChanges;
    size_t lastRemoteCount;
    VRCClipboardFormat lastRemote[MAX_FORMATS];
    int dataQuestions;
    VRCClipboardFormat lastQuestion;
    /* Questions of this client about the files of the server */
    atomic_int fileRequests;
    CLIPRDR_FILE_CONTENTS_REQUEST lastFileRequest;
    /* Answers of this client about its own files */
    int fileResponses;
    UINT16 lastFileFlags;
    UINT32 lastFileStream;
    uint8_t lastFileData[RESPONSE_ROOM];
    UINT32 lastFileLength;
} Channel;

static Channel channel;
static VRCCallbacks callbacks;
static void* userData = &channel;

static UINT sentCapabilities(CliprdrClientContext* context, const CLIPRDR_CAPABILITIES* capabilities)
{
    (void)context;
    (void)capabilities;
    channel.capabilities++;
    return CHANNEL_RC_OK;
}

static UINT sentFormatList(CliprdrClientContext* context, const CLIPRDR_FORMAT_LIST* list)
{
    (void)context;
    channel.formatLists++;
    channel.lastFormatCount = list->numFormats;
    for (UINT32 i = 0; i < list->numFormats && i < MAX_FORMATS; i++)
    {
        channel.lastFormatIds[i] = list->formats[i].formatId;
        snprintf(channel.lastFormatNames[i], FORMAT_NAME_SIZE, "%s",
                 list->formats[i].formatName ? list->formats[i].formatName : "");
    }
    return CHANNEL_RC_OK;
}

static UINT sentListResponse(CliprdrClientContext* context, const CLIPRDR_FORMAT_LIST_RESPONSE* response)
{
    (void)context;
    (void)response;
    channel.listResponses++;
    return CHANNEL_RC_OK;
}

static UINT sentDataRequest(CliprdrClientContext* context, const CLIPRDR_FORMAT_DATA_REQUEST* request)
{
    (void)context;
    channel.dataRequests++;
    channel.lastRequestedFormatId = request->requestedFormatId;
    return CHANNEL_RC_OK;
}

static UINT sentDataResponse(CliprdrClientContext* context, const CLIPRDR_FORMAT_DATA_RESPONSE* response)
{
    (void)context;
    channel.dataResponses++;
    channel.lastResponseFlags = response->common.msgFlags;
    channel.lastResponseLength = response->common.dataLen;
    if (response->requestedFormatData && response->common.dataLen <= sizeof(channel.lastResponse))
        memcpy(channel.lastResponse, response->requestedFormatData, response->common.dataLen);
    return CHANNEL_RC_OK;
}

static UINT sentFileRequest(CliprdrClientContext* context, const CLIPRDR_FILE_CONTENTS_REQUEST* request)
{
    (void)context;
    channel.lastFileRequest = *request;
    channel.fileRequests++;
    return CHANNEL_RC_OK;
}

static UINT sentFileResponse(CliprdrClientContext* context, const CLIPRDR_FILE_CONTENTS_RESPONSE* response)
{
    (void)context;
    channel.fileResponses++;
    channel.lastFileFlags = response->common.msgFlags;
    channel.lastFileStream = response->streamId;
    channel.lastFileLength = response->cbRequested;
    if (response->requestedData && response->cbRequested <= sizeof(channel.lastFileData))
        memcpy(channel.lastFileData, response->requestedData, response->cbRequested);
    return CHANNEL_RC_OK;
}

static void remoteChanged(void* data, const VRCClipboardFormat* formats, size_t count)
{
    Channel* target = data;
    target->remoteChanges++;
    target->lastRemoteCount = count;
    for (size_t i = 0; i < count && i < MAX_FORMATS; i++)
        target->lastRemote[i] = formats[i];
}

static void dataRequested(void* data, VRCClipboardFormat format)
{
    Channel* target = data;
    target->dataQuestions++;
    target->lastQuestion = format;
}

/* A clipboard on a fresh stand-in, attached as when the channel comes up */
static bool setUp(VRCClipboard* clipboard)
{
    memset(&channel, 0, sizeof(channel));
    channel.context.ClientCapabilities = sentCapabilities;
    channel.context.ClientFormatList = sentFormatList;
    channel.context.ClientFormatListResponse = sentListResponse;
    channel.context.ClientFormatDataRequest = sentDataRequest;
    channel.context.ClientFormatDataResponse = sentDataResponse;
    channel.context.ClientFileContentsRequest = sentFileRequest;
    channel.context.ClientFileContentsResponse = sentFileResponse;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.remoteClipboardChanged = remoteChanged;
    callbacks.clipboardDataRequested = dataRequested;
    CHECK(vrcClipboardInit(clipboard, &callbacks, &userData));
    vrcClipboardAttach(clipboard, &channel.context);
    return true;
}

static UINT serverMonitorReady(void)
{
    const CLIPRDR_MONITOR_READY ready = { .common = { .msgType = CB_MONITOR_READY } };
    return channel.context.MonitorReady(&channel.context, &ready);
}

static UINT serverAsks(UINT32 formatId)
{
    const CLIPRDR_FORMAT_DATA_REQUEST request = {
        .common = { .msgType = CB_FORMAT_DATA_REQUEST },
        .requestedFormatId = formatId,
    };
    return channel.context.ServerFormatDataRequest(&channel.context, &request);
}

static UINT serverOffers(const CLIPRDR_FORMAT* formats, UINT32 count)
{
    CLIPRDR_FORMAT copies[MAX_FORMATS];
    memcpy(copies, formats, sizeof(CLIPRDR_FORMAT) * count);
    const CLIPRDR_FORMAT_LIST list = { .common = { .msgType = CB_FORMAT_LIST }, .numFormats = count,
                                       .formats = copies };
    return channel.context.ServerFormatList(&channel.context, &list);
}

static UINT serverAnswers(const uint8_t* data, UINT32 length)
{
    const CLIPRDR_FORMAT_DATA_RESPONSE response = {
        .common = { .msgType = CB_FORMAT_DATA_RESPONSE,
                    .msgFlags = data ? CB_RESPONSE_OK : CB_RESPONSE_FAIL,
                    .dataLen = length },
        .requestedFormatData = data,
    };
    return channel.context.ServerFormatDataResponse(&channel.context, &response);
}

/* The server offers text among formats the app does not take */
static bool offerText(void)
{
    static const CLIPRDR_FORMAT formats[] = {
        { CF_TEXT, NULL },
        { CF_UNICODETEXT, NULL },
        { REGISTERED_FORMAT_ID, (char*)"HTML Format" },
    };
    CHECK(serverOffers(formats, 3) == CHANNEL_RC_OK);
    return true;
}

static UINT serverRespondsToList(bool took)
{
    const CLIPRDR_FORMAT_LIST_RESPONSE response = {
        .common = { .msgType = CB_FORMAT_LIST_RESPONSE, .msgFlags = took ? CB_RESPONSE_OK : CB_RESPONSE_FAIL },
    };
    return channel.context.ServerFormatListResponse(&channel.context, &response);
}

/* An offer made before Monitor Ready waits, and goes out as the first list after the capabilities */
static bool testOfferWaitsForMonitorReady(void)
{
    VRCClipboard clipboard;
    CHECK(setUp(&clipboard));
    const VRCClipboardFormat text = VRCClipboardFormatText;

    CHECK(vrcClipboardOffer(&clipboard, &text, 1) == VRCResultOK);
    CHECK(channel.formatLists == 0);
    CHECK(serverMonitorReady() == CHANNEL_RC_OK);
    CHECK(channel.capabilities == 1);
    CHECK(channel.formatLists == 1);
    CHECK(channel.lastFormatCount == 1);
    CHECK(channel.lastFormatIds[0] == CF_UNICODETEXT);

    /* After it every offer goes out at once, an empty one too */
    CHECK(vrcClipboardOffer(&clipboard, NULL, 0) == VRCResultOK);
    CHECK(channel.formatLists == 2);
    CHECK(channel.lastFormatCount == 0);
    const VRCClipboardFormat unknown = (VRCClipboardFormat)99;
    CHECK(vrcClipboardOffer(&clipboard, &unknown, 1) == VRCResultInvalidArgument);

    vrcClipboardDestroy(&clipboard);
    return true;
}

/* The server pastes offered text: the app is asked, and its UTF-8 goes out as CF_UNICODETEXT, once */
static bool testServerPastesText(void)
{
    VRCClipboard clipboard;
    CHECK(setUp(&clipboard));
    const VRCClipboardFormat text = VRCClipboardFormatText;
    CHECK(vrcClipboardOffer(&clipboard, &text, 1) == VRCResultOK);
    CHECK(serverMonitorReady() == CHANNEL_RC_OK);

    CHECK(serverAsks(CF_UNICODETEXT) == CHANNEL_RC_OK);
    CHECK(channel.dataQuestions == 1);
    CHECK(channel.lastQuestion == VRCClipboardFormatText);
    CHECK(channel.dataResponses == 0);

    CHECK(vrcClipboardProvide(&clipboard, VRCClipboardFormatText, "a\nb", 3) == VRCResultOK);
    static const uint8_t expected[] = { 'a', 0, '\r', 0, '\n', 0, 'b', 0, 0, 0 };
    CHECK(channel.dataResponses == 1);
    CHECK(channel.lastResponseFlags == CB_RESPONSE_OK);
    CHECK(channel.lastResponseLength == sizeof(expected));
    CHECK(memcmp(channel.lastResponse, expected, sizeof(expected)) == 0);

    /* The question is answered: a second answer has nothing to go to */
    CHECK(vrcClipboardProvide(&clipboard, VRCClipboardFormatText, "c", 1) == VRCResultInvalidState);
    CHECK(channel.dataResponses == 1);

    /* The Mac no longer holds the text: the server gets a failed answer */
    CHECK(serverAsks(CF_UNICODETEXT) == CHANNEL_RC_OK);
    CHECK(vrcClipboardProvide(&clipboard, VRCClipboardFormatText, NULL, 0) == VRCResultOK);
    CHECK(channel.lastResponseFlags == CB_RESPONSE_FAIL);

    vrcClipboardDestroy(&clipboard);
    return true;
}

/* A format the Mac does not offer gets a failed answer at once, and the app is not asked */
static bool testServerAsksForWhatIsNotOffered(void)
{
    VRCClipboard clipboard;
    CHECK(setUp(&clipboard));
    CHECK(serverMonitorReady() == CHANNEL_RC_OK);

    CHECK(serverAsks(CF_UNICODETEXT) == CHANNEL_RC_OK);
    CHECK(serverAsks(CF_DIB) == CHANNEL_RC_OK);
    CHECK(channel.dataQuestions == 0);
    CHECK(channel.dataResponses == 2);
    CHECK(channel.lastResponseFlags == CB_RESPONSE_FAIL);

    vrcClipboardDestroy(&clipboard);
    return true;
}

/* The list of the server is acknowledged, and the app hears only of the formats it takes, by their names */
static bool testServerOffersFormats(void)
{
    VRCClipboard clipboard;
    CHECK(setUp(&clipboard));

    CHECK(offerText());
    CHECK(channel.listResponses == 1);
    CHECK(channel.remoteChanges == 1);
    CHECK(channel.lastRemoteCount == 2);
    CHECK(channel.lastRemote[0] == VRCClipboardFormatText);
    CHECK(channel.lastRemote[1] == VRCClipboardFormatHtml);

    static const CLIPRDR_FORMAT rich[] = {
        { SERVER_RTF_ID, (char*)"Rich Text Format" },
        { SERVER_OTHER_ID, (char*)"Link Source" },
    };
    CHECK(serverOffers(rich, 2) == CHANNEL_RC_OK);
    CHECK(channel.lastRemoteCount == 1);
    CHECK(channel.lastRemote[0] == VRCClipboardFormatRtf);

    static const CLIPRDR_FORMAT other[] = { { SERVER_OTHER_ID, (char*)"Link Source" } };
    CHECK(serverOffers(other, 1) == CHANNEL_RC_OK);
    CHECK(channel.remoteChanges == 3);
    CHECK(channel.lastRemoteCount == 0);

    vrcClipboardDestroy(&clipboard);
    return true;
}

/* HTML and RTF go out as the registered formats of Windows: the ids of this client and the names of Windows */
static bool testOfferRegisteredFormats(void)
{
    VRCClipboard clipboard;
    CHECK(setUp(&clipboard));
    CHECK(serverMonitorReady() == CHANNEL_RC_OK);

    const VRCClipboardFormat all[] = { VRCClipboardFormatText, VRCClipboardFormatHtml, VRCClipboardFormatRtf };
    CHECK(vrcClipboardOffer(&clipboard, all, 3) == VRCResultOK);
    CHECK(channel.lastFormatCount == 3);
    CHECK(channel.lastFormatIds[0] == CF_UNICODETEXT);
    CHECK(channel.lastFormatNames[0][0] == '\0');
    CHECK(channel.lastFormatIds[1] >= 0xC000u);
    CHECK(strcmp(channel.lastFormatNames[1], "HTML Format") == 0);
    CHECK(channel.lastFormatIds[2] >= 0xC000u);
    CHECK(channel.lastFormatIds[2] != channel.lastFormatIds[1]);
    CHECK(strcmp(channel.lastFormatNames[2], "Rich Text Format") == 0);

    /* The server asks by the id this client gave: HTML goes as "HTML Format", RTF with a zero at its end */
    CHECK(serverAsks(channel.lastFormatIds[1]) == CHANNEL_RC_OK);
    CHECK(channel.lastQuestion == VRCClipboardFormatHtml);
    CHECK(vrcClipboardProvide(&clipboard, VRCClipboardFormatHtml, "<b>x</b>", 8) == VRCResultOK);
    CHECK(channel.lastResponseFlags == CB_RESPONSE_OK);
    CHECK(memcmp(channel.lastResponse, "Version:0.9\r\n", 13) == 0);
    CHECK(channel.lastResponse[channel.lastResponseLength - 1] == 0);

    CHECK(serverAsks(channel.lastFormatIds[2]) == CHANNEL_RC_OK);
    CHECK(channel.lastQuestion == VRCClipboardFormatRtf);
    CHECK(vrcClipboardProvide(&clipboard, VRCClipboardFormatRtf, "{\\rtf1 x}", 9) == VRCResultOK);
    CHECK(channel.lastResponseLength == 10);
    CHECK(memcmp(channel.lastResponse, "{\\rtf1 x}", 10) == 0);

    vrcClipboardDestroy(&clipboard);
    return true;
}

typedef struct FormatCopy {
    VRCClipboard* clipboard;
    VRCClipboardFormat format;
    VRCResult result;
    void* data;
    size_t length;
} FormatCopy;

static void* runFormatCopy(void* argument)
{
    FormatCopy* copy = argument;
    copy->result =
        vrcClipboardCopyRemote(copy->clipboard, copy->format, ANSWER_TIMEOUT_MS, NULL, &copy->data, &copy->length);
    return NULL;
}

/* A copy of a registered format asks by the id the server gave it and converts the answer */
static bool copyAs(VRCClipboard* clipboard, VRCClipboardFormat format, const uint8_t* answer, UINT32 answerLength,
                   UINT32 expectedId, const char* expected)
{
    FormatCopy copy = { .clipboard = clipboard, .format = format };
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, runFormatCopy, &copy) == 0);
    usleep(SETTLE_US);
    CHECK(channel.lastRequestedFormatId == expectedId);
    CHECK(serverAnswers(answer, answerLength) == CHANNEL_RC_OK);
    CHECK(pthread_join(thread, NULL) == 0);
    CHECK(copy.result == VRCResultOK);
    CHECK(copy.length == strlen(expected));
    CHECK(strcmp(copy.data, expected) == 0);
    free(copy.data);
    return true;
}

static bool testCopyRegisteredFormats(void)
{
    VRCClipboard clipboard;
    CHECK(setUp(&clipboard));
    static const CLIPRDR_FORMAT formats[] = {
        { SERVER_HTML_ID, (char*)"HTML Format" },
        { SERVER_RTF_ID, (char*)"Rich Text Format" },
    };
    CHECK(serverOffers(formats, 2) == CHANNEL_RC_OK);

    static const char html[] = "Version:0.9\r\nStartHTML:0000000105\r\nEndHTML:0000000113\r\n"
                               "StartFragment:0000000105\r\nEndFragment:0000000113\r\n<b>x</b>";
    CHECK(copyAs(&clipboard, VRCClipboardFormatHtml, (const uint8_t*)html, sizeof(html), SERVER_HTML_ID, "<b>x</b>"));

    static const char rtf[] = "{\\rtf1 x}";
    CHECK(copyAs(&clipboard, VRCClipboardFormatRtf, (const uint8_t*)rtf, sizeof(rtf), SERVER_RTF_ID, "{\\rtf1 x}"));

    vrcClipboardDestroy(&clipboard);
    return true;
}

/* A copy that takes the answer as bytes, for the formats that are not text */
static bool copyBytes(VRCClipboard* clipboard, const uint8_t* answer, UINT32 answerLength, UINT32 expectedId,
                      FormatCopy* copy)
{
    *copy = (FormatCopy){ .clipboard = clipboard, .format = VRCClipboardFormatImage };
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, runFormatCopy, copy) == 0);
    usleep(SETTLE_US);
    CHECK(channel.lastRequestedFormatId == expectedId);
    CHECK(serverAnswers(answer, answerLength) == CHANNEL_RC_OK);
    CHECK(pthread_join(thread, NULL) == 0);
    CHECK(copy->result == VRCResultOK);
    return true;
}

/* A one-pixel red bitmap as Windows keeps it: the header, then blue, green, red and a byte of padding */
static const uint8_t onePixelDib[] = { 40, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 24, 0, 0, 0, 0, 0,
                                       4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                       0, 0, 255, 0 };

/* The same image as PNG */
static bool onePixelPng(uint8_t** png, size_t* length)
{
    CHECK(vrcDibToPng(onePixelDib, sizeof(onePixelDib), png, length));
    CHECK(*length <= sizeof(channel.lastResponse));
    return true;
}

/* An image goes out both as "PNG" and as CF_DIB; the server gets the one it asks for */
static bool testOfferImage(void)
{
    VRCClipboard clipboard;
    CHECK(setUp(&clipboard));
    CHECK(serverMonitorReady() == CHANNEL_RC_OK);
    const VRCClipboardFormat image = VRCClipboardFormatImage;
    CHECK(vrcClipboardOffer(&clipboard, &image, 1) == VRCResultOK);
    CHECK(channel.lastFormatCount == 2);
    CHECK(channel.lastFormatIds[0] >= 0xC000u);
    CHECK(strcmp(channel.lastFormatNames[0], "PNG") == 0);
    CHECK(channel.lastFormatIds[1] == CF_DIB);
    const UINT32 pngId = channel.lastFormatIds[0];

    uint8_t* png = NULL;
    size_t pngLength = 0;
    CHECK(onePixelPng(&png, &pngLength));

    /* PNG goes as it is */
    CHECK(serverAsks(pngId) == CHANNEL_RC_OK);
    CHECK(channel.lastQuestion == VRCClipboardFormatImage);
    CHECK(vrcClipboardProvide(&clipboard, VRCClipboardFormatText, "x", 1) == VRCResultInvalidState);
    CHECK(vrcClipboardProvide(&clipboard, VRCClipboardFormatImage, png, pngLength) == VRCResultOK);
    CHECK(channel.lastResponseLength == pngLength);
    CHECK(memcmp(channel.lastResponse, png, pngLength) == 0);

    /* CF_DIB gets the bitmap Windows keeps */
    CHECK(serverAsks(CF_DIB) == CHANNEL_RC_OK);
    CHECK(channel.dataQuestions == 2);
    CHECK(vrcClipboardProvide(&clipboard, VRCClipboardFormatImage, png, pngLength) == VRCResultOK);
    CHECK(channel.lastResponseFlags == CB_RESPONSE_OK);
    CHECK(channel.lastResponseLength == sizeof(onePixelDib));
    CHECK(memcmp(channel.lastResponse + 40, onePixelDib + 40, 4) == 0);

    /* Broken image data is a failure for the app, and the server still waits for its answer */
    CHECK(serverAsks(CF_DIB) == CHANNEL_RC_OK);
    CHECK(vrcClipboardProvide(&clipboard, VRCClipboardFormatImage, "junk", 4) == VRCResultFailure);
    CHECK(vrcClipboardProvide(&clipboard, VRCClipboardFormatImage, NULL, 0) == VRCResultOK);
    CHECK(channel.lastResponseFlags == CB_RESPONSE_FAIL);

    /* CF_DIBV5 is made by Windows from CF_DIB: it is never asked of this client */
    const int questions = channel.dataQuestions;
    CHECK(serverAsks(CF_DIBV5) == CHANNEL_RC_OK);
    CHECK(channel.dataQuestions == questions);
    CHECK(channel.lastResponseFlags == CB_RESPONSE_FAIL);

    free(png);
    vrcClipboardDestroy(&clipboard);
    return true;
}

/* The server offers an image in several formats: PNG is fetched first, then CF_DIBV5, then CF_DIB as PNG */
static bool testImageFromServer(void)
{
    VRCClipboard clipboard;
    CHECK(setUp(&clipboard));
    uint8_t* png = NULL;
    size_t pngLength = 0;
    CHECK(onePixelPng(&png, &pngLength));

    static const CLIPRDR_FORMAT all[] = {
        { CF_DIB, NULL },
        { CF_DIBV5, NULL },
        { SERVER_PNG_ID, (char*)"PNG" },
    };
    CHECK(serverOffers(all, 3) == CHANNEL_RC_OK);
    CHECK(channel.lastRemoteCount == 1);
    CHECK(channel.lastRemote[0] == VRCClipboardFormatImage);
    FormatCopy copy;
    CHECK(copyBytes(&clipboard, png, (UINT32)pngLength, SERVER_PNG_ID, &copy));
    CHECK(copy.length == pngLength && memcmp(copy.data, png, pngLength) == 0);
    free(copy.data);

    static const CLIPRDR_FORMAT bitmaps[] = { { CF_DIB, NULL }, { CF_DIBV5, NULL } };
    CHECK(serverOffers(bitmaps, 2) == CHANNEL_RC_OK);
    CHECK(copyBytes(&clipboard, onePixelDib, sizeof(onePixelDib), CF_DIBV5, &copy));
    free(copy.data);

    static const CLIPRDR_FORMAT dib[] = { { CF_DIB, NULL } };
    CHECK(serverOffers(dib, 1) == CHANNEL_RC_OK);
    CHECK(copyBytes(&clipboard, onePixelDib, sizeof(onePixelDib), CF_DIB, &copy));
    CHECK(copy.length == pngLength && memcmp(copy.data, png, pngLength) == 0);
    free(copy.data);

    free(png);
    vrcClipboardDestroy(&clipboard);
    return true;
}

/* The server asks this client about one of its files */
static UINT serverAsksFile(UINT32 index, UINT32 flags, UINT64 position, UINT32 requested, UINT32 stream)
{
    const CLIPRDR_FILE_CONTENTS_REQUEST request = {
        .common = { .msgType = CB_FILECONTENTS_REQUEST },
        .streamId = stream,
        .listIndex = index,
        .dwFlags = flags,
        .nPositionLow = (UINT32)position,
        .nPositionHigh = (UINT32)(position >> 32),
        .cbRequested = requested,
    };
    return channel.context.ServerFileContentsRequest(&channel.context, &request);
}

/* The index of a name in a list of files, or -1 */
static int indexOf(const VRCRemoteFiles* files, const char* name)
{
    for (size_t i = 0; i < files->count; i++)
        if (strcmp(files->items[i].name, name) == 0)
            return (int)i;
    return -1;
}

/* The paths of a folder and a file beside it, each ending with a zero byte */
static size_t twoPaths(const char* root, const char* first, const char* second, char* paths, size_t size)
{
    const int one = snprintf(paths, size, "%s/%s", root, first) + 1;
    const int two = snprintf(paths + one, size - (size_t)one, "%s/%s", root, second) + 1;
    return (size_t)(one + two);
}

/* The server pastes files of the Mac: it gets their list, then reads their sizes and ranges without the app */
static bool testServerReadsMacFiles(void)
{
    char root[FILE_TREE_PATH];
    CHECK(fileTreeMake(root));
    CHECK(fileTreeWrite(root, "d/a.txt", "hello world"));
    CHECK(fileTreeWrite(root, "b.txt", "bee"));

    VRCClipboard clipboard;
    CHECK(setUp(&clipboard));
    CHECK(serverMonitorReady() == CHANNEL_RC_OK);
    const VRCClipboardFormat files = VRCClipboardFormatFiles;
    CHECK(vrcClipboardOffer(&clipboard, &files, 1) == VRCResultOK);
    CHECK(channel.lastFormatCount == 1);
    CHECK(strcmp(channel.lastFormatNames[0], "FileGroupDescriptorW") == 0);

    CHECK(serverAsks(channel.lastFormatIds[0]) == CHANNEL_RC_OK);
    CHECK(channel.lastQuestion == VRCClipboardFormatFiles);
    char paths[2 * FILE_TREE_PATH];
    const size_t length = twoPaths(root, "d", "b.txt", paths, sizeof(paths));
    CHECK(vrcClipboardProvide(&clipboard, VRCClipboardFormatFiles, paths, length) == VRCResultOK);
    CHECK(channel.lastResponseFlags == CB_RESPONSE_OK);
    VRCRemoteFiles* list = vrcRemoteFilesParse(channel.lastResponse, channel.lastResponseLength);
    CHECK(list && list->count == 3);
    const int file = indexOf(list, "d/a.txt");
    const int folder = indexOf(list, "d");
    CHECK(file >= 0 && folder >= 0 && indexOf(list, "b.txt") >= 0);
    vrcRemoteFilesFree(list);

    CHECK(serverAsksFile((UINT32)file, FILECONTENTS_SIZE, 0, 8, 7) == CHANNEL_RC_OK);
    CHECK(channel.lastFileFlags == CB_RESPONSE_OK && channel.lastFileStream == 7 && channel.lastFileLength == 8);
    CHECK(channel.lastFileData[0] == 11 && channel.lastFileData[1] == 0);
    CHECK(serverAsksFile((UINT32)file, FILECONTENTS_RANGE, 6, 100, 8) == CHANNEL_RC_OK);
    CHECK(channel.lastFileLength == 5 && memcmp(channel.lastFileData, "world", 5) == 0);

    /* A folder has no contents, an index past the list is no file */
    CHECK(serverAsksFile((UINT32)folder, FILECONTENTS_RANGE, 0, 100, 9) == CHANNEL_RC_OK);
    CHECK(channel.lastFileFlags == CB_RESPONSE_FAIL && channel.lastFileStream == 9);
    CHECK(serverAsksFile(99, FILECONTENTS_SIZE, 0, 8, 10) == CHANNEL_RC_OK);
    CHECK(channel.lastFileFlags == CB_RESPONSE_FAIL);

    /* A new copy on the Mac leaves the list the server got: a paste there may still be reading it */
    const VRCClipboardFormat text = VRCClipboardFormatText;
    CHECK(vrcClipboardOffer(&clipboard, &text, 1) == VRCResultOK);
    CHECK(serverAsksFile((UINT32)file, FILECONTENTS_RANGE, 0, 5, 11) == CHANNEL_RC_OK);
    CHECK(channel.lastFileFlags == CB_RESPONSE_OK && memcmp(channel.lastFileData, "hello", 5) == 0);

    vrcClipboardDestroy(&clipboard);
    CHECK(fileTreeRemove(root));
    return true;
}

/* Plays the server for a copy of its files: the list on a request for data, sizes and ranges from the files */
typedef struct FileServer {
    const VRCLocalFiles* files;
    atomic_bool done;
} FileServer;

static void playFileServer(FileServer* server)
{
    int data = channel.dataRequests;
    int ranges = channel.fileRequests;
    while (!atomic_load(&server->done))
    {
        if (channel.dataRequests > data)
        {
            data++;
            (void)serverAnswers(server->files->descriptor, (UINT32)server->files->descriptorLength);
        }
        else if (channel.fileRequests > ranges)
        {
            ranges++;
            const CLIPRDR_FILE_CONTENTS_REQUEST request = channel.lastFileRequest;
            uint8_t answer[RESPONSE_ROOM];
            uint32_t length = 0;
            bool ok = request.listIndex < server->files->count;
            if (ok && (request.dwFlags & FILECONTENTS_SIZE))
            {
                const uint64_t size = server->files->items[request.listIndex].size;
                for (int i = 0; i < 8; i++)
                    answer[i] = (uint8_t)(size >> (8 * i));
                length = 8;
            }
            else if (ok)
            {
                const uint64_t position = ((uint64_t)request.nPositionHigh << 32) | request.nPositionLow;
                const uint32_t wanted = request.cbRequested < sizeof(answer) ? request.cbRequested : sizeof(answer);
                ok = vrcLocalFilesRead(server->files, request.listIndex, position, wanted, answer, &length);
            }
            const CLIPRDR_FILE_CONTENTS_RESPONSE response = {
                .common = { .msgType = CB_FILECONTENTS_RESPONSE, .msgFlags = ok ? CB_RESPONSE_OK : CB_RESPONSE_FAIL },
                .streamId = request.streamId,
                .cbRequested = ok ? length : 0,
                .requestedData = ok ? answer : NULL,
            };
            (void)channel.context.ServerFileContentsResponse(&channel.context, &response);
        }
        else
            usleep(1000);
    }
}

typedef struct FilesCopy {
    VRCClipboard* clipboard;
    const char* directory;
    VRCResult result;
    uint64_t lastDone;
    uint64_t lastTotal;
    int reports;
    /* The report on which the progress cancels the copy, 0 for never */
    int cancelOn;
    FileServer* server;
} FilesCopy;

static bool recordProgress(void* context, uint64_t done, uint64_t total)
{
    FilesCopy* copy = context;
    copy->lastDone = done;
    copy->lastTotal = total;
    copy->reports++;
    return copy->reports != copy->cancelOn;
}

static void* runFilesCopy(void* argument)
{
    FilesCopy* copy = argument;
    copy->result =
        vrcClipboardCopyRemoteFiles(copy->clipboard, copy->directory, ANSWER_TIMEOUT_MS, NULL, recordProgress, copy);
    atomic_store(&copy->server->done, true);
    return NULL;
}

static bool copyFilesInto(FilesCopy* copy)
{
    atomic_store(&copy->server->done, false);
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, runFilesCopy, copy) == 0);
    playFileServer(copy->server);
    CHECK(pthread_join(thread, NULL) == 0);
    return true;
}

/* The Mac pastes files of the server: the names at the top first, then the files into a folder, tree and all */
static bool testCopyFilesFromServer(void)
{
    char source[FILE_TREE_PATH];
    char target[FILE_TREE_PATH];
    CHECK(fileTreeMake(source));
    CHECK(fileTreeMake(target));
    CHECK(fileTreeWrite(source, "Отчёт/q.txt", "quarter"));
    CHECK(fileTreeWrite(source, "Отчёт/пусто", ""));
    CHECK(fileTreeWrite(source, "top.txt", "top"));
    CHECK(fileTreeSetTime(source, "top.txt", 1600000000));
    char paths[2 * FILE_TREE_PATH];
    VRCLocalFiles* served = vrcLocalFilesCreate(paths, twoPaths(source, "Отчёт", "top.txt", paths, sizeof(paths)));
    CHECK(served != NULL);

    VRCClipboard clipboard;
    CHECK(setUp(&clipboard));
    static const CLIPRDR_FORMAT offered[] = { { SERVER_FILES_ID, (char*)"FileGroupDescriptorW" } };
    CHECK(serverOffers(offered, 1) == CHANNEL_RC_OK);
    CHECK(channel.lastRemoteCount == 1 && channel.lastRemote[0] == VRCClipboardFormatFiles);

    /* The names at the top, for the items that stand for the files on the Mac */
    FormatCopy names = { .clipboard = &clipboard, .format = VRCClipboardFormatFiles };
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, runFormatCopy, &names) == 0);
    usleep(SETTLE_US);
    CHECK(channel.lastRequestedFormatId == SERVER_FILES_ID);
    CHECK(serverAnswers(served->descriptor, (UINT32)served->descriptorLength) == CHANNEL_RC_OK);
    CHECK(pthread_join(thread, NULL) == 0);
    CHECK(names.result == VRCResultOK);
    CHECK(names.length == strlen("Отчёт") + 1 + strlen("top.txt") + 1);
    free(names.data);

    /* The copy takes the list it already has, and reports its bytes as they come */
    FileServer server = { .files = served };
    FilesCopy copy = { .clipboard = &clipboard, .directory = target, .server = &server };
    const int requests = channel.dataRequests;
    CHECK(copyFilesInto(&copy));
    CHECK(copy.result == VRCResultOK);
    CHECK(channel.dataRequests == requests);
    CHECK(copy.lastDone == 10 && copy.lastTotal == 10);
    CHECK(fileTreeHolds(target, "Отчёт/q.txt", "quarter"));
    CHECK(fileTreeHolds(target, "Отчёт/пусто", ""));
    CHECK(fileTreeHolds(target, "top.txt", "top"));
    char path[FILE_TREE_PATH];
    snprintf(path, sizeof(path), "%s/top.txt", target);
    struct stat status;
    CHECK(stat(path, &status) == 0 && status.st_mtimespec.tv_sec == 1600000000);

    /* A new list of the server: the copy fetches it, and a file already there is not overwritten */
    CHECK(serverOffers(offered, 1) == CHANNEL_RC_OK);
    CHECK(copyFilesInto(&copy));
    CHECK(copy.result == VRCResultFailure);
    CHECK(channel.dataRequests == requests + 1);

    vrcLocalFilesFree(served);
    vrcClipboardDestroy(&clipboard);
    CHECK(fileTreeRemove(source));
    CHECK(fileTreeRemove(target));
    return true;
}

/* The progress cancels the copy: no range is asked for, and the result says why the copy stopped */
static bool testCancelFileCopy(void)
{
    char source[FILE_TREE_PATH];
    char target[FILE_TREE_PATH];
    CHECK(fileTreeMake(source));
    CHECK(fileTreeMake(target));
    CHECK(fileTreeWrite(source, "a.txt", "a"));
    CHECK(fileTreeWrite(source, "b.txt", "b"));
    char paths[2 * FILE_TREE_PATH];
    VRCLocalFiles* served = vrcLocalFilesCreate(paths, twoPaths(source, "a.txt", "b.txt", paths, sizeof(paths)));
    CHECK(served != NULL);

    VRCClipboard clipboard;
    CHECK(setUp(&clipboard));
    static const CLIPRDR_FORMAT offered[] = { { SERVER_FILES_ID, (char*)"FileGroupDescriptorW" } };
    CHECK(serverOffers(offered, 1) == CHANNEL_RC_OK);

    FileServer server = { .files = served };
    FilesCopy copy = { .clipboard = &clipboard, .directory = target, .server = &server, .cancelOn = 1 };
    CHECK(copyFilesInto(&copy));
    CHECK(copy.result == VRCResultCancelled);
    CHECK(channel.fileRequests == 0);

    /* A folder that does not exist is refused before anything goes out */
    copy.directory = "/nonexistent/viberdp";
    CHECK(vrcClipboardCopyRemoteFiles(&clipboard, copy.directory, SHORT_TIMEOUT_MS, NULL, NULL, NULL) ==
          VRCResultInvalidArgument);

    vrcLocalFilesFree(served);
    vrcClipboardDestroy(&clipboard);
    CHECK(fileTreeRemove(source));
    CHECK(fileTreeRemove(target));
    return true;
}

typedef struct Copy {
    VRCClipboard* clipboard;
    uint32_t timeoutMs;
    VRCResult result;
    void* data;
    size_t length;
} Copy;

static void* runCopy(void* argument)
{
    Copy* copy = argument;
    copy->result = vrcClipboardCopyRemote(copy->clipboard, VRCClipboardFormatText, copy->timeoutMs, NULL, &copy->data,
                                          &copy->length);
    return NULL;
}

/* The Mac pastes: the request names the format id of the server, and the answer comes back as UTF-8 with LF */
static bool testCopyFromServer(void)
{
    VRCClipboard clipboard;
    CHECK(setUp(&clipboard));
    CHECK(offerText());

    Copy copy = { .clipboard = &clipboard, .timeoutMs = ANSWER_TIMEOUT_MS };
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, runCopy, &copy) == 0);
    usleep(SETTLE_US);
    CHECK(channel.dataRequests == 1);
    CHECK(channel.lastRequestedFormatId == CF_UNICODETEXT);

    static const uint8_t answer[] = { 'x', 0, '\r', 0, '\n', 0, 'y', 0, 0, 0 };
    CHECK(serverAnswers(answer, sizeof(answer)) == CHANNEL_RC_OK);
    CHECK(pthread_join(thread, NULL) == 0);
    CHECK(copy.result == VRCResultOK);
    CHECK(copy.length == 3);
    CHECK(strcmp(copy.data, "x\ny") == 0);
    free(copy.data);

    vrcClipboardDestroy(&clipboard);
    return true;
}

/* A copy that times out leaves its answer due: the late answer is dropped, the next copy gets its own */
static bool testLateAnswerIsDropped(void)
{
    VRCClipboard clipboard;
    CHECK(setUp(&clipboard));
    CHECK(offerText());

    void* data = NULL;
    size_t length = 0;
    CHECK(vrcClipboardCopyRemote(&clipboard, VRCClipboardFormatText, SHORT_TIMEOUT_MS, NULL, &data, &length) ==
          VRCResultTimeout);
    CHECK(data == NULL);

    static const uint8_t late[] = { 'o', 0, 'l', 0, 'd', 0, 0, 0 };
    CHECK(serverAnswers(late, sizeof(late)) == CHANNEL_RC_OK);

    Copy copy = { .clipboard = &clipboard, .timeoutMs = ANSWER_TIMEOUT_MS };
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, runCopy, &copy) == 0);
    usleep(SETTLE_US);
    static const uint8_t fresh[] = { 'n', 0, 'e', 0, 'w', 0, 0, 0 };
    CHECK(serverAnswers(fresh, sizeof(fresh)) == CHANNEL_RC_OK);
    CHECK(pthread_join(thread, NULL) == 0);
    CHECK(copy.result == VRCResultOK);
    CHECK(strcmp(copy.data, "new") == 0);
    free(copy.data);

    vrcClipboardDestroy(&clipboard);
    return true;
}

/* A failed answer is a failure, a copy of what the server does not offer is refused before any request */
static bool testCopyFailures(void)
{
    VRCClipboard clipboard;
    CHECK(setUp(&clipboard));

    void* data = NULL;
    size_t length = 0;
    CHECK(vrcClipboardCopyRemote(&clipboard, VRCClipboardFormatText, SHORT_TIMEOUT_MS, NULL, &data, &length) ==
          VRCResultInvalidState);
    CHECK(channel.dataRequests == 0);

    CHECK(offerText());
    Copy copy = { .clipboard = &clipboard, .timeoutMs = ANSWER_TIMEOUT_MS };
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, runCopy, &copy) == 0);
    usleep(SETTLE_US);
    CHECK(serverAnswers(NULL, 0) == CHANNEL_RC_OK);
    CHECK(pthread_join(thread, NULL) == 0);
    CHECK(copy.result == VRCResultFailure);
    CHECK(copy.data == NULL);

    vrcClipboardDestroy(&clipboard);
    return true;
}

/* The channel goes down while a copy waits: the copy ends as a failure, not at its timeout */
static bool testDetachEndsCopy(void)
{
    VRCClipboard clipboard;
    CHECK(setUp(&clipboard));
    CHECK(offerText());

    Copy copy = { .clipboard = &clipboard, .timeoutMs = ANSWER_TIMEOUT_MS };
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, runCopy, &copy) == 0);
    usleep(SETTLE_US);
    vrcClipboardDetach(&clipboard, &channel.context);
    CHECK(pthread_join(thread, NULL) == 0);
    CHECK(copy.result == VRCResultFailure);

    /* Without the channel nothing goes out, and the offer waits for the next one */
    const VRCClipboardFormat text = VRCClipboardFormatText;
    const int lists = channel.formatLists;
    CHECK(vrcClipboardOffer(&clipboard, &text, 1) == VRCResultOK);
    CHECK(channel.formatLists == lists);
    CHECK(vrcClipboardProvide(&clipboard, VRCClipboardFormatText, "a", 1) == VRCResultInvalidState);

    vrcClipboardDestroy(&clipboard);
    return true;
}

/*
 * A list the server turned down goes again after growing pauses, three times, and then waits for the next copy;
 * a list the server took and a new copy end the repeats
 */
static bool testTurnedDownListGoesAgain(void)
{
    VRCClipboard clipboard;
    CHECK(setUp(&clipboard));
    const VRCClipboardFormat text = VRCClipboardFormatText;
    CHECK(vrcClipboardOffer(&clipboard, &text, 1) == VRCResultOK);
    CHECK(serverMonitorReady() == CHANNEL_RC_OK);
    CHECK(channel.formatLists == 1);
    CHECK(vrcClipboardRetryWait(&clipboard, GetTickCount64()) == INFINITE);

    static const uint32_t pauses[] = { 500, 2000, 5000 };
    for (size_t i = 0; i < sizeof(pauses) / sizeof(pauses[0]); i++)
    {
        const uint64_t before = GetTickCount64();
        CHECK(serverRespondsToList(false) == CHANNEL_RC_OK);
        CHECK(WaitForSingleObject(vrcClipboardRetryWake(&clipboard), 0) == WAIT_OBJECT_0);
        const DWORD wait = vrcClipboardRetryWait(&clipboard, before);
        CHECK(wait != INFINITE && wait >= pauses[i] && wait <= pauses[i] + 1000);
        /* Not yet due: nothing goes, and the wake is taken */
        vrcClipboardRetryDue(&clipboard, before);
        CHECK(channel.formatLists == (int)(1 + i));
        CHECK(WaitForSingleObject(vrcClipboardRetryWake(&clipboard), 0) == WAIT_TIMEOUT);
        vrcClipboardRetryDue(&clipboard, before + pauses[i] + 1000);
        CHECK(channel.formatLists == (int)(2 + i));
        CHECK(channel.lastFormatIds[0] == CF_UNICODETEXT);
        CHECK(vrcClipboardRetryWait(&clipboard, GetTickCount64()) == INFINITE);
    }
    CHECK(serverRespondsToList(false) == CHANNEL_RC_OK);
    CHECK(vrcClipboardRetryWait(&clipboard, GetTickCount64()) == INFINITE);

    /* A new copy starts the repeats afresh; a list the server took ends them */
    CHECK(vrcClipboardOffer(&clipboard, &text, 1) == VRCResultOK);
    CHECK(serverRespondsToList(false) == CHANNEL_RC_OK);
    CHECK(vrcClipboardRetryWait(&clipboard, GetTickCount64()) != INFINITE);
    CHECK(vrcClipboardOffer(&clipboard, &text, 1) == VRCResultOK);
    CHECK(vrcClipboardRetryWait(&clipboard, GetTickCount64()) == INFINITE);
    CHECK(serverRespondsToList(false) == CHANNEL_RC_OK);
    CHECK(serverRespondsToList(true) == CHANNEL_RC_OK);
    CHECK(vrcClipboardRetryWait(&clipboard, GetTickCount64()) == INFINITE);

    vrcClipboardDestroy(&clipboard);
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "offerWaitsForMonitorReady", testOfferWaitsForMonitorReady },
    { "serverPastesText", testServerPastesText },
    { "serverAsksForWhatIsNotOffered", testServerAsksForWhatIsNotOffered },
    { "serverOffersFormats", testServerOffersFormats },
    { "offerRegisteredFormats", testOfferRegisteredFormats },
    { "copyRegisteredFormats", testCopyRegisteredFormats },
    { "copyFromServer", testCopyFromServer },
    { "lateAnswerIsDropped", testLateAnswerIsDropped },
    { "copyFailures", testCopyFailures },
    { "detachEndsCopy", testDetachEndsCopy },
    { "offerImage", testOfferImage },
    { "imageFromServer", testImageFromServer },
    { "serverReadsMacFiles", testServerReadsMacFiles },
    { "copyFilesFromServer", testCopyFilesFromServer },
    { "cancelFileCopy", testCancelFileCopy },
    { "turnedDownListGoesAgain", testTurnedDownListGoesAgain },
};

int main(int argc, char* argv[])
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s <test name>\n", argv[0]);
        return 2;
    }
    for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); i++)
        if (strcmp(tests[i].name, argv[1]) == 0)
            return tests[i].run() ? 0 : 1;

    fprintf(stderr, "unknown test: %s\n", argv[1]);
    return 2;
}
