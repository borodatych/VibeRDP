/*
 * Clipboard channel tests: core/src/clipboard.c against a stand-in for the CLIPRDR channel of the engine
 * The stand-in records what the core sends; a test plays the server by calling the handlers the core installed
 * Usage: clipboardTests <test name>; CTest registers every test separately
 */

#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <freerdp/channels/cliprdr.h>
#include <winpr/user.h>

#include "clipboard.h"

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
    int dataRequests;
    UINT32 lastRequestedFormatId;
    int dataResponses;
    UINT16 lastResponseFlags;
    uint8_t lastResponse[256];
    UINT32 lastResponseLength;
    int remoteChanges;
    size_t lastRemoteCount;
    VRCClipboardFormat lastRemote[MAX_FORMATS];
    int dataQuestions;
    VRCClipboardFormat lastQuestion;
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
