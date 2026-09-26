/*
 * Clipboard echo tests: the clipboard channel against the sample server of FreeRDP that build-core.sh starts
 * The server asks for the text, HTML, RTF, CF_DIB and files the client offers and offers them back,
 * the text behind a prefix; files come over by their list and contents and go back the same way
 * The data so goes from the Mac to the server and back through both directions of CLIPRDR
 * The large round trip carries text and an image of many chunks of the channel each, as a long copy does
 * Without the server every test skips itself
 * Usage: clipboardEchoTests <test name>; CTest registers every test separately
 */

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fileTrees.h"
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

/* The large copy: lines enough for a hundred kilobytes, an image of noise that PNG cannot shrink */
#define LARGE_LINES 1000
#define LARGE_SIDE 128
static const char largeLine[] = "Строка %04d: съешь же ещё этих мягких французских булок, да выпей чаю\n";

/* What the Mac answers when the server pastes: the small copy or the large one */
static const char* offeredText = macText;
static const uint8_t* offeredPng;
static size_t offeredPngLength;

/* A folder with a file inside and a file beside it, the paths the Mac offers for them */
static char macFiles[FILE_TREE_PATH];
static char macPaths[2 * FILE_TREE_PATH];
static size_t macPathsLength;

/* The formats the Mac offers, all of them */
#define OFFERED_COUNT 5

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
        (void)VRCSessionProvideClipboardData(current, format, offeredPng, offeredPngLength);
        return;
    }
    if (format == VRCClipboardFormatFiles)
    {
        (void)VRCSessionProvideClipboardData(current, format, macPaths, macPathsLength);
        return;
    }
    const char* data =
        format == VRCClipboardFormatHtml ? macHtml : format == VRCClipboardFormatRtf ? macRtf : offeredText;
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

/* Connects to the echo server with the formats offered before the connection, as the app does */
static VRCSession* connectToEcho(Recorder* recorder, const char* socket, const VRCClipboardFormat* offered,
                                 size_t offeredCount)
{
    VRCCallbacks callbacks = recorderCallbacks();
    callbacks.clipboardDataRequested = onDataRequested;
    callbacks.remoteClipboardChanged = onRemoteChanged;
    VRCSession* session = VRCSessionCreate(&callbacks, recorder);
    if (!session)
        return NULL;
    current = session;

    /* The sample server has no logon of its own: a name and a password spare the question */
    const VRCConnectionParams params = { .host = socket, .username = "tester", .password = "unused" };
    if (VRCSessionOfferClipboard(session, offered, offeredCount) != VRCResultOK ||
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
    /* A long copy is shown by its start */
    printf("format %d came back: %zu bytes, %.60s\n", (int)format, length, (const char*)data);
    CHECK(length == strlen(expected));
    CHECK(strcmp(data, expected) == 0);
    free(data);
    return true;
}

/* The image went to the server as CF_DIB and comes back as PNG, pixel for pixel */
static bool imageCameBack(VRCSession* session, const Picture* sent)
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
    CHECK(back.width == sent->width && back.height == sent->height);
    for (size_t i = 0; i < sent->width * sent->height; i++)
        CHECK(pictureNear(back.pixels[i], sent->pixels[i]));
    return true;
}

/* The files went to the server by their contents and come back into another folder, tree and all */
static bool filesCameBack(VRCSession* session)
{
    void* names = NULL;
    size_t length = 0;
    CHECK(VRCSessionCopyRemoteClipboard(session, VRCClipboardFormatFiles, ECHO_TIMEOUT_MS, &names, &length) ==
          VRCResultOK);
    const bool listed = length == strlen("Папка") + 1 + strlen("note.txt") + 1 && strcmp(names, "Папка") == 0;
    free(names);
    CHECK(listed);

    char target[FILE_TREE_PATH];
    CHECK(fileTreeMake(target));
    CHECK(VRCSessionCopyRemoteFiles(session, target, ECHO_TIMEOUT_MS, NULL, NULL) == VRCResultOK);
    CHECK(fileTreeHolds(target, "Папка/отчёт.txt", "квартал"));
    CHECK(fileTreeHolds(target, "Папка/пусто", ""));
    CHECK(fileTreeHolds(target, "note.txt", "note"));
    printf("files came back\n");
    CHECK(fileTreeRemove(target));
    return true;
}

/*
 * The offer goes out when the channel starts, the server takes each format and offers them back,
 * and the copies bring them home: both directions, the registered formats and the conversions on the way
 */
static bool testRoundTrip(const char* socket)
{
    CHECK(pictureEncodePng(&macImage, &macPng, &macPngLength));
    offeredPng = macPng;
    offeredPngLength = macPngLength;
    CHECK(fileTreeMake(macFiles));
    CHECK(fileTreeWrite(macFiles, "Папка/отчёт.txt", "квартал"));
    CHECK(fileTreeWrite(macFiles, "Папка/пусто", ""));
    CHECK(fileTreeWrite(macFiles, "note.txt", "note"));
    const int folder = snprintf(macPaths, sizeof(macPaths), "%s/Папка", macFiles) + 1;
    const int file = snprintf(macPaths + folder, sizeof(macPaths) - (size_t)folder, "%s/note.txt", macFiles) + 1;
    macPathsLength = (size_t)(folder + file);
    Recorder* recorder = recorderNew();
    const VRCClipboardFormat offered[OFFERED_COUNT] = { VRCClipboardFormatText, VRCClipboardFormatHtml,
                                                        VRCClipboardFormatRtf, VRCClipboardFormatImage,
                                                        VRCClipboardFormatFiles };
    VRCSession* session = connectToEcho(recorder, socket, offered, OFFERED_COUNT);
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
    CHECK(formats[4] == VRCClipboardFormatFiles);

    char text[128];
    CHECK(snprintf(text, sizeof(text), "%s%s", echoPrefix, macText) < (int)sizeof(text));
    CHECK(copyIs(session, VRCClipboardFormatText, text));
    CHECK(copyIs(session, VRCClipboardFormatHtml, htmlBack));
    CHECK(copyIs(session, VRCClipboardFormatRtf, macRtf));
    CHECK(imageCameBack(session, &macImage));
    CHECK(filesCameBack(session));

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
    CHECK(fileTreeRemove(macFiles));
    return true;
}

/*
 * A copy larger than one chunk of the channel, 1600 bytes, goes and comes back whole, and the session stays
 * The engine gathers such a message from its chunks; a wrong count there ended the session with a channel error
 */
static bool testLargeRoundTrip(const char* socket)
{
    static char text[LARGE_LINES * sizeof(largeLine)];
    size_t used = 0;
    for (int line = 0; line < LARGE_LINES; line++)
        used += (size_t)snprintf(text + used, sizeof(text) - used, largeLine, line);
    offeredText = text;
    static Picture noise;
    noise.width = LARGE_SIDE;
    noise.height = LARGE_SIDE;
    for (size_t i = 0; i < LARGE_SIDE * LARGE_SIDE; i++)
        noise.pixels[i] = (Rgba){ (uint8_t)(i * 37), (uint8_t)(i * 101 + 7), (uint8_t)((i * 13) ^ (i >> 7)), 255 };
    uint8_t* png = NULL;
    size_t pngLength = 0;
    CHECK(pictureEncodePng(&noise, &png, &pngLength));
    offeredPng = png;
    offeredPngLength = pngLength;
    printf("large copy: text %zu bytes, image %zu bytes as PNG\n", used, pngLength);

    Recorder* recorder = recorderNew();
    const VRCClipboardFormat offered[] = { VRCClipboardFormatText, VRCClipboardFormatImage };
    VRCSession* session = connectToEcho(recorder, socket, offered, sizeof(offered) / sizeof(offered[0]));
    CHECK(session != NULL);
    CHECK(recorderWaitForState(recorder, VRCSessionStateConnected, STATE_TIMEOUT_MS));
    CHECK(waitForRemoteChange(ECHO_TIMEOUT_MS));

    char* expected = malloc(strlen(echoPrefix) + used + 1);
    CHECK(expected != NULL);
    (void)snprintf(expected, strlen(echoPrefix) + used + 1, "%s%s", echoPrefix, text);
    const bool textBack = copyIs(session, VRCClipboardFormatText, expected);
    free(expected);
    const bool imageBack = textBack && imageCameBack(session, &noise);

    /* The session goes before the checks: a failed copy must not leave its thread running as the test exits */
    VRCSessionDisconnect(session);
    const bool ended = recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS);
    const RecorderSnapshot snapshot = recorderSnapshot(recorder);
    VRCSessionDestroy(session);
    recorderFree(recorder);
    free(png);
    CHECK(textBack);
    CHECK(imageBack);
    CHECK(ended);
    CHECK(snapshot.errorCount == 0);
    return true;
}

int main(int argc, char* argv[])
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s <test name>\n", argv[0]);
        return 2;
    }
    bool (*test)(const char* socket) = NULL;
    if (strcmp(argv[1], "roundTrip") == 0)
        test = testRoundTrip;
    else if (strcmp(argv[1], "largeRoundTrip") == 0)
        test = testLargeRoundTrip;
    else
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
    return test(socket) ? 0 : 1;
}
