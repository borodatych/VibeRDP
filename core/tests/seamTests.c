/*
 * Seam channel tests: core/src/seam.c against a stand-in for the dynamic channel of the engine
 * Usage: seamTests <test name>; CTest registers every test separately
 */

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "seam.h"

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

/* What the app heard */
static int opened;
static int closed;
static int bodies;
static uint8_t lastBody[64];
static size_t lastLength;

/* What the core wrote on the channel */
static uint8_t written[64];
static ULONG writtenLength;

static void onOpened(void* userData)
{
    (void)userData;
    opened++;
}

static void onClosed(void* userData)
{
    (void)userData;
    closed++;
}

static void onReceived(void* userData, const uint8_t* body, size_t length)
{
    (void)userData;
    bodies++;
    lastLength = length;
    memcpy(lastBody, body, length < sizeof(lastBody) ? length : sizeof(lastBody));
}

static UINT channelWrite(IWTSVirtualChannel* channel, ULONG length, const BYTE* buffer, void* reserved)
{
    (void)channel;
    (void)reserved;
    writtenLength = length;
    memcpy(written, buffer, length < sizeof(written) ? length : sizeof(written));
    return CHANNEL_RC_OK;
}

/* The session side of the plugin, which these tests do not load */
VRCSeam* vrcSessionSeam(rdpContext* context)
{
    (void)context;
    return NULL;
}

static const VRCCallbacks callbacks = {
    .seamOpened = onOpened,
    .seamReceived = onReceived,
    .seamClosed = onClosed,
};
static void* userData;
static IWTSVirtualChannel channel;

static void setUp(VRCSeam* seam)
{
    opened = closed = bodies = 0;
    lastLength = 0;
    writtenLength = 0;
    memset(&channel, 0, sizeof(channel));
    channel.Write = channelWrite;
    vrcSeamInit(seam, &callbacks, &userData);
    vrcSeamOpened(seam, &channel);
}

static bool testFrameSplitAcrossChunks(void)
{
    VRCSeam seam;
    setUp(&seam);
    const uint8_t frame[] = { 3, 0, 0, 0, 0x81, 0xa1, 0x78 };
    for (size_t i = 0; i < sizeof(frame); i++)
        vrcSeamReceived(&seam, &frame[i], 1);
    CHECK(opened == 1 && bodies == 1 && lastLength == 3);
    CHECK(memcmp(lastBody, frame + 4, 3) == 0);
    vrcSeamDestroy(&seam);
    return true;
}

static bool testFramesInOneChunk(void)
{
    VRCSeam seam;
    setUp(&seam);
    const uint8_t chunk[] = { 1, 0, 0, 0, 0xc0, 0, 0, 0, 0, 2, 0, 0, 0, 0x92, 0xc3 };
    vrcSeamReceived(&seam, chunk, sizeof(chunk));
    CHECK(bodies == 3 && lastLength == 2 && lastBody[0] == 0x92 && lastBody[1] == 0xc3);
    vrcSeamDestroy(&seam);
    return true;
}

static bool testLongFrameBreaksOnce(void)
{
    VRCSeam seam;
    setUp(&seam);
    const uint32_t tooLong = VRC_SEAM_MAX_BODY + 1;
    const uint8_t header[] = { (uint8_t)tooLong, (uint8_t)(tooLong >> 8), (uint8_t)(tooLong >> 16),
                               (uint8_t)(tooLong >> 24) };
    vrcSeamReceived(&seam, header, sizeof(header));
    CHECK(closed == 1 && bodies == 0);
    const uint8_t next[] = { 1, 0, 0, 0, 0xc0 };
    vrcSeamReceived(&seam, next, sizeof(next));
    CHECK(bodies == 0);
    CHECK(vrcSeamSend(&seam, next, 1) == VRCResultInvalidState);
    vrcSeamClosed(&seam);
    CHECK(closed == 1);
    vrcSeamDestroy(&seam);
    return true;
}

static bool testSendPutsLengthInFront(void)
{
    VRCSeam seam;
    setUp(&seam);
    const uint8_t body[] = { 0x81, 0xa1, 0x78, 0x01 };
    CHECK(vrcSeamSend(&seam, body, sizeof(body)) == VRCResultOK);
    CHECK(writtenLength == 8);
    CHECK(written[0] == 4 && written[1] == 0 && written[2] == 0 && written[3] == 0);
    CHECK(memcmp(written + 4, body, sizeof(body)) == 0);
    CHECK(vrcSeamSend(&seam, body, VRC_SEAM_MAX_BODY + 1) == VRCResultInvalidArgument);
    vrcSeamDestroy(&seam);
    return true;
}

static bool testClosedChannelRefusesSends(void)
{
    VRCSeam seam;
    setUp(&seam);
    vrcSeamClosed(&seam);
    CHECK(closed == 1);
    const uint8_t body[] = { 0xc0 };
    CHECK(vrcSeamSend(&seam, body, sizeof(body)) == VRCResultInvalidState && writtenLength == 0);
    vrcSeamOpened(&seam, &channel);
    CHECK(opened == 2 && vrcSeamSend(&seam, body, sizeof(body)) == VRCResultOK);
    vrcSeamDestroy(&seam);
    return true;
}

static bool testReopenDropsHalfAFrame(void)
{
    VRCSeam seam;
    setUp(&seam);
    const uint8_t half[] = { 3, 0, 0, 0, 0x81 };
    vrcSeamReceived(&seam, half, sizeof(half));
    vrcSeamClosed(&seam);
    vrcSeamOpened(&seam, &channel);
    const uint8_t whole[] = { 1, 0, 0, 0, 0xc2 };
    vrcSeamReceived(&seam, whole, sizeof(whole));
    CHECK(bodies == 1 && lastLength == 1 && lastBody[0] == 0xc2);
    vrcSeamDestroy(&seam);
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "frameSplitAcrossChunks", testFrameSplitAcrossChunks },
    { "framesInOneChunk", testFramesInOneChunk },
    { "longFrameBreaksOnce", testLongFrameBreaksOnce },
    { "sendPutsLengthInFront", testSendPutsLengthInFront },
    { "closedChannelRefusesSends", testClosedChannelRefusesSends },
    { "reopenDropsHalfAFrame", testReopenDropsHalfAFrame },
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
