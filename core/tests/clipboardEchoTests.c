/*
 * Clipboard echo tests: the clipboard channel against the sample server of FreeRDP that build-core.sh starts
 * The server asks for the text the client offers and offers it back behind a prefix, so the text goes
 * from the Mac to the server and back through both directions of CLIPRDR
 * Without the server every test skips itself
 * Usage: clipboardEchoTests <test name>; CTest registers every test separately
 */

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "support.h"
#include "VibeRDPCore/VibeRDPCore.h"

/* A round trip on this Mac takes milliseconds; the margin is for a busy machine */
#define STATE_TIMEOUT_MS 10000
#define ECHO_TIMEOUT_MS 10000
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

/* The text of the Mac clipboard, with a line end and letters beyond ASCII */
static const char macText[] = "Привет\nмир 👋";
static const char echoPrefix[] = "echo: ";

/* What the clipboard callbacks saw; the recorder of support.c keeps the rest */
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static VRCSession* current;
static int questions;
static int remoteChanges;
static size_t remoteCount;
static VRCClipboardFormat remoteFormat;

/* Windows pastes: the answer goes out from the callback itself, as the app may answer from any thread */
static void onDataRequested(void* userData, VRCClipboardFormat format)
{
    (void)userData;
    pthread_mutex_lock(&mutex);
    questions++;
    pthread_mutex_unlock(&mutex);
    (void)VRCSessionProvideClipboardData(current, format, macText, strlen(macText));
}

static void onRemoteChanged(void* userData, const VRCClipboardFormat* formats, size_t count)
{
    (void)userData;
    pthread_mutex_lock(&mutex);
    remoteChanges++;
    remoteCount = count;
    remoteFormat = count > 0 ? formats[0] : (VRCClipboardFormat)0;
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

    const VRCClipboardFormat text = VRCClipboardFormatText;
    /* The sample server has no logon of its own: a name and a password spare the question */
    const VRCConnectionParams params = { .host = socket, .username = "tester", .password = "unused" };
    if (VRCSessionOfferClipboard(session, &text, 1) != VRCResultOK ||
        VRCSessionConnect(session, &params) != VRCResultOK || !recorderWaitForCertificate(recorder, STATE_TIMEOUT_MS) ||
        VRCSessionResolveCertificate(session, true) != VRCResultOK)
    {
        VRCSessionDestroy(session);
        return NULL;
    }
    return session;
}

/*
 * The offer goes out when the channel starts, the server takes the text and offers it back,
 * and the copy brings it home as UTF-8 with LF: both directions and the conversions on the way
 */
static bool testTextRoundTrip(const char* socket)
{
    Recorder* recorder = recorderNew();
    VRCSession* session = connectToEcho(recorder, socket);
    CHECK(session != NULL);
    CHECK(recorderWaitForState(recorder, VRCSessionStateConnected, STATE_TIMEOUT_MS));
    CHECK(waitForRemoteChange(ECHO_TIMEOUT_MS));

    pthread_mutex_lock(&mutex);
    const int asked = questions;
    const size_t count = remoteCount;
    const VRCClipboardFormat format = remoteFormat;
    pthread_mutex_unlock(&mutex);
    CHECK(asked == 1);
    CHECK(count == 1);
    CHECK(format == VRCClipboardFormatText);

    void* data = NULL;
    size_t length = 0;
    CHECK(VRCSessionCopyRemoteClipboard(session, VRCClipboardFormatText, ECHO_TIMEOUT_MS, &data, &length) ==
          VRCResultOK);
    char expected[128];
    CHECK(snprintf(expected, sizeof(expected), "%s%s", echoPrefix, macText) < (int)sizeof(expected));
    printf("the echo: %s\n", (const char*)data);
    CHECK(length == strlen(expected));
    CHECK(strcmp(data, expected) == 0);
    free(data);

    VRCSessionDisconnect(session);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS));
    const RecorderSnapshot snapshot = recorderSnapshot(recorder);
    CHECK(snapshot.errorCount == 0);

    /* The session is over: nothing is left to copy */
    CHECK(VRCSessionCopyRemoteClipboard(session, VRCClipboardFormatText, ECHO_TIMEOUT_MS, &data, &length) ==
          VRCResultInvalidState);
    VRCSessionDestroy(session);
    recorderFree(recorder);
    return true;
}

int main(int argc, char* argv[])
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s <test name>\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "textRoundTrip") != 0)
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
    return testTextRoundTrip(socket) ? 0 : 1;
}
