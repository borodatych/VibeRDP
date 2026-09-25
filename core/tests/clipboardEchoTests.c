/*
 * Clipboard echo tests: the clipboard channel against the sample server of FreeRDP that build-core.sh starts
 * The server asks for the text, HTML, RTF and CF_DIB the client offers and offers them back,
 * the text behind a prefix
 * The data so goes from the Mac to the server and back through both directions of CLIPRDR
 * Without the server every test skips itself
 * Usage: clipboardEchoTests <test name>; CTest registers every test separately
 */

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pictures.h"
#include "support.h"
#include "VibeRDPCore/VibeRDPCore.h"

/*
 * Alone a round trip takes a fifth of a second, under Rosetta too
 * Among the other tests, which CTest runs at once, it took up to 12 s under Rosetta: the margin covers that
 */
#define STATE_TIMEOUT_MS 20000
#define ECHO_TIMEOUT_MS 20000
/* The exit code CTest takes for a skipped test */
#define SKIPPED 77

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

/* The Mac clipboard: text with a line end and letters beyond ASCII, HTML without a page around it, RTF, an image */
static const char macText[] = "Привет\nмир 👋";
static const char macHtml[] = "<p>Жирный <b>текст</b></p>";
static const char macRtf[] = "{\\rtf1\\ansi \\b bold\\b0 }";
static const char echoPrefix[] = "echo: ";
/* The HTML comes back as the page "HTML Format" wraps it in */
static const char htmlBack[] =
    "<html><body><!--StartFragment--><p>Жирный <b>текст</b></p><!--EndFragment--></body></html>";
/* Opaque, since CF_DIB keeps no alpha; each pixel its own colour, so a flip or a swap of channels shows */
static const Picture macImage = { 2, 2, { { 255, 0, 0, 255 }, { 0, 255, 0, 255 }, { 0, 0, 255, 255 },
                                          { 255, 255, 255, 255 } } };
static uint8_t* macPng;
static size_t macPngLength;

/* The formats the Mac offers, all of them */
#define OFFERED_COUNT 4

/* What the clipboard callbacks saw; the recorder of support.c keeps the rest */
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static VRCSession* current;
static int questions;
static int remoteChanges;
static size_t remoteCount;
static VRCClipboardFormat remoteFormats[OFFERED_COUNT];

/* Windows pastes: the answer goes out from the callback itself, as the app may answer from any thread */
static void onDataRequested(void* userData, VRCClipboardFormat format)
{
    (void)userData;
    pthread_mutex_lock(&mutex);
    questions++;
    pthread_mutex_unlock(&mutex);
    if (format == VRCClipboardFormatImage)
    {
        (void)VRCSessionProvideClipboardData(current, format, macPng, macPngLength);
        return;
    }
    const char* data = format == VRCClipboardFormatHtml ? macHtml : format == VRCClipboardFormatRtf ? macRtf : macText;
    (void)VRCSessionProvideClipboardData(current, format, data, strlen(data));
}

static void onRemoteChanged(void* userData, const VRCClipboardFormat* formats, size_t count)
{
    (void)userData;
    pthread_mutex_lock(&mutex);
    remoteChanges++;
    remoteCount = count;
    for (size_t i = 0; i < count && i < OFFERED_COUNT; i++)
        remoteFormats[i] = formats[i];
    pthread_mutex_unlock(&mutex);
}

static bool waitForRemoteChange(int timeoutMs)
{
    const int64_t deadline = monotonicMs() + timeoutMs;
    pthread_mutex_lock(&mutex);
    while (remoteChanges == 0 && monotonicMs() < deadline)
    {
        pthread_mutex_unlock(&mutex);
        sleepMs(10);
        pthread_mutex_lock(&mutex);
    }
    const bool seen = remoteChanges > 0;
    pthread_mutex_unlock(&mutex);
    return seen;
}

/* Connects to the echo server with the text offered before the connection, as the app does */
static VRCSession* connectToEcho(Recorder* recorder, const char* socket)
{
    VRCCallbacks callbacks = recorderCallbacks();
    callbacks.clipboardDataRequested = onDataRequested;
    callbacks.remoteClipboardChanged = onRemoteChanged;
    VRCSession* session = VRCSessionCreate(&callbacks, recorder);
    if (!session)
        return NULL;
    current = session;

    const VRCClipboardFormat offered[OFFERED_COUNT] = { VRCClipboardFormatText, VRCClipboardFormatHtml,
                                                        VRCClipboardFormatRtf, VRCClipboardFormatImage };
    /* The sample server has no logon of its own: a name and a password spare the question */
    const VRCConnectionParams params = { .host = socket, .username = "tester", .password = "unused" };
    if (VRCSessionOfferClipboard(session, offered, OFFERED_COUNT) != VRCResultOK ||
        VRCSessionConnect(session, &params) != VRCResultOK || !recorderWaitForCertificate(recorder, STATE_TIMEOUT_MS) ||
        VRCSessionResolveCertificate(session, true) != VRCResultOK)
    {
        VRCSessionDestroy(session);
        return NULL;
    }
    return session;
}

/* A copy of one format from the server, compared with what it should be */
static bool copyIs(VRCSession* session, VRCClipboardFormat format, const char* expected)
{
    void* data = NULL;
    size_t length = 0;
    CHECK(VRCSessionCopyRemoteClipboard(session, format, ECHO_TIMEOUT_MS, &data, &length) == VRCResultOK);
    printf("format %d came back: %s\n", (int)format, (const char*)data);
    CHECK(length == strlen(expected));
    CHECK(strcmp(data, expected) == 0);
    free(data);
    return true;
}

/* The image went to the server as CF_DIB and comes back as PNG, pixel for pixel */
static bool imageCameBack(VRCSession* session)
{
    void* data = NULL;
    size_t length = 0;
    CHECK(VRCSessionCopyRemoteClipboard(session, VRCClipboardFormatImage, ECHO_TIMEOUT_MS, &data, &length) ==
          VRCResultOK);
    Picture back;
    const bool decoded = pictureDecodePng(data, length, &back);
    free(data);
    CHECK(decoded);
    printf("image came back: %zux%zu\n", back.width, back.height);
    CHECK(back.width == macImage.width && back.height == macImage.height);
    for (size_t i = 0; i < macImage.width * macImage.height; i++)
        CHECK(pictureNear(back.pixels[i], macImage.pixels[i]));
    return true;
}

/*
 * The offer goes out when the channel starts, the server takes each format and offers them back,
 * and the copies bring them home: both directions, the registered formats and the conversions on the way
 */
static bool testRoundTrip(const char* socket)
{
    CHECK(pictureEncodePng(&macImage, &macPng, &macPngLength));
    Recorder* recorder = recorderNew();
    VRCSession* session = connectToEcho(recorder, socket);
    CHECK(session != NULL);
    CHECK(recorderWaitForState(recorder, VRCSessionStateConnected, STATE_TIMEOUT_MS));
    CHECK(waitForRemoteChange(ECHO_TIMEOUT_MS));

    pthread_mutex_lock(&mutex);
    const int asked = questions;
    const size_t count = remoteCount;
    VRCClipboardFormat formats[OFFERED_COUNT];
    memcpy(formats, remoteFormats, sizeof(formats));
    pthread_mutex_unlock(&mutex);
    CHECK(asked == OFFERED_COUNT);
    CHECK(count == OFFERED_COUNT);
    CHECK(formats[0] == VRCClipboardFormatText);
    CHECK(formats[1] == VRCClipboardFormatHtml);
    CHECK(formats[2] == VRCClipboardFormatRtf);
    CHECK(formats[3] == VRCClipboardFormatImage);

    char text[128];
    CHECK(snprintf(text, sizeof(text), "%s%s", echoPrefix, macText) < (int)sizeof(text));
    CHECK(copyIs(session, VRCClipboardFormatText, text));
    CHECK(copyIs(session, VRCClipboardFormatHtml, htmlBack));
    CHECK(copyIs(session, VRCClipboardFormatRtf, macRtf));
    CHECK(imageCameBack(session));

    void* data = NULL;
    size_t length = 0;

    VRCSessionDisconnect(session);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS));
    const RecorderSnapshot snapshot = recorderSnapshot(recorder);
    CHECK(snapshot.errorCount == 0);

    /* The session is over: nothing is left to copy */
    CHECK(VRCSessionCopyRemoteClipboard(session, VRCClipboardFormatText, ECHO_TIMEOUT_MS, &data, &length) ==
          VRCResultInvalidState);
    VRCSessionDestroy(session);
    recorderFree(recorder);
    free(macPng);
    return true;
}

int main(int argc, char* argv[])
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s <test name>\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "roundTrip") != 0)
    {
        fprintf(stderr, "unknown test: %s\n", argv[1]);
        return 2;
    }
    const char* socket = getenv("VIBERDP_CLIPBOARD_SERVER_SOCKET");
    if (!socket)
    {
        printf("no clipboard test server: build-test-server.sh builds it, build-core.sh starts it\n");
        return SKIPPED;
    }
    return testRoundTrip(socket) ? 0 : 1;
}
