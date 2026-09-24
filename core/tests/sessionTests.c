/*
 * Session tests: the lifecycle and the threading of VRCSession against local fake servers
 * Usage: sessionTests <test name>; CTest registers every test separately
 */

#include <stdio.h>
#include <string.h>

#include "support.h"
#include "VibeRDPCore/VibeRDPCore.h"

/* Generous for a loopback connection, still short enough to catch a hang */
#define STATE_TIMEOUT_MS 10000
/* How long a disconnect or a destroy may take once the session is asked to end */
#define STOP_BUDGET_MS 5000
/* Lets the session thread reach the blocking wait for the server before the test interrupts it */
#define SETTLE_MS 300

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

static VRCConnectionParams loopbackParams(uint16_t port)
{
    VRCConnectionParams params = { .host = "127.0.0.1", .port = port };
    return params;
}

static void printError(const RecorderSnapshot* data)
{
    printf("engine error 0x%08x %s: %s\n", data->errorCode, data->errorName, data->errorMessage);
}

/* Connecting, then Disconnected, and nothing in between: the session never reached a real RDP server */
static bool endedWithoutConnecting(const RecorderSnapshot* data)
{
    return data->stateCount == 2 && data->states[0] == VRCSessionStateConnecting &&
           data->states[1] == VRCSessionStateDisconnected;
}

static bool testLifecycle(void)
{
    Recorder* recorder = recorderNew();
    const VRCCallbacks callbacks = recorderCallbacks();

    for (int i = 0; i < 20; i++)
    {
        VRCSession* session = VRCSessionCreate(&callbacks, recorder);
        CHECK(session != NULL);
        VRCSessionDisconnect(session);
        VRCSessionDestroy(session);
    }
    VRCSession* bare = VRCSessionCreate(NULL, NULL);
    CHECK(bare != NULL);
    VRCSessionDestroy(bare);
    VRCSessionDestroy(NULL);
    VRCSessionDisconnect(NULL);

    const RecorderSnapshot data = recorderSnapshot(recorder);
    CHECK(data.stateCount == 0);
    CHECK(data.errorCount == 0);
    recorderFree(recorder);
    return true;
}

static bool testInvalidArguments(void)
{
    Recorder* recorder = recorderNew();
    const VRCCallbacks callbacks = recorderCallbacks();
    VRCSession* session = VRCSessionCreate(&callbacks, recorder);
    CHECK(session != NULL);

    const VRCConnectionParams params = loopbackParams(unusedPort());
    VRCConnectionParams noHost = params;
    noHost.host = NULL;
    VRCConnectionParams emptyHost = params;
    emptyHost.host = "";
    CHECK(VRCSessionConnect(NULL, &params) == VRCResultInvalidArgument);
    CHECK(VRCSessionConnect(session, NULL) == VRCResultInvalidArgument);
    CHECK(VRCSessionConnect(session, &noHost) == VRCResultInvalidArgument);
    CHECK(VRCSessionConnect(session, &emptyHost) == VRCResultInvalidArgument);

    /* Rejected arguments leave the session idle, so the first valid connect still starts it */
    CHECK(VRCSessionConnect(session, &params) == VRCResultOK);
    CHECK(VRCSessionConnect(session, &params) == VRCResultInvalidState);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS));

    VRCSessionDestroy(session);
    recorderFree(recorder);
    return true;
}

static bool testConnectRefused(void)
{
    Recorder* recorder = recorderNew();
    const VRCCallbacks callbacks = recorderCallbacks();
    VRCSession* session = VRCSessionCreate(&callbacks, recorder);
    CHECK(session != NULL);

    const VRCConnectionParams params = loopbackParams(unusedPort());
    CHECK(VRCSessionConnect(session, &params) == VRCResultOK);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS));

    const RecorderSnapshot data = recorderSnapshot(recorder);
    printError(&data);
    CHECK(endedWithoutConnecting(&data));
    CHECK(data.errorCount == 1);
    CHECK(data.errorCode != 0);
    CHECK(strlen(data.errorName) > 0);

    VRCSessionDestroy(session);
    recorderFree(recorder);
    return true;
}

static bool testServerClosesConnection(void)
{
    FakeServer* server = fakeServerStart(FakeServerCloses);
    Recorder* recorder = recorderNew();
    const VRCCallbacks callbacks = recorderCallbacks();
    VRCSession* session = VRCSessionCreate(&callbacks, recorder);
    CHECK(session != NULL);

    const VRCConnectionParams params = loopbackParams(fakeServerPort(server));
    CHECK(VRCSessionConnect(session, &params) == VRCResultOK);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS));

    const RecorderSnapshot data = recorderSnapshot(recorder);
    printError(&data);
    /* The engine got as far as the transport: channel loading and the rest of the pre-connect work passed */
    CHECK(fakeServerAcceptedCount(server) >= 1);
    CHECK(endedWithoutConnecting(&data));
    CHECK(data.errorCount == 1);
    CHECK(data.errorCode != 0);

    VRCSessionDestroy(session);
    recorderFree(recorder);
    fakeServerStop(server);
    return true;
}

static bool testDisconnectWhileConnecting(void)
{
    FakeServer* server = fakeServerStart(FakeServerHolds);
    Recorder* recorder = recorderNew();
    const VRCCallbacks callbacks = recorderCallbacks();
    VRCSession* session = VRCSessionCreate(&callbacks, recorder);
    CHECK(session != NULL);

    const VRCConnectionParams params = loopbackParams(fakeServerPort(server));
    CHECK(VRCSessionConnect(session, &params) == VRCResultOK);
    CHECK(recorderWaitForState(recorder, VRCSessionStateConnecting, STATE_TIMEOUT_MS));
    sleepMs(SETTLE_MS);

    const int64_t started = monotonicMs();
    VRCSessionDisconnect(session);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STOP_BUDGET_MS));
    printf("disconnected in %lld ms\n", (long long)(monotonicMs() - started));

    const RecorderSnapshot data = recorderSnapshot(recorder);
    CHECK(fakeServerAcceptedCount(server) >= 1);
    CHECK(endedWithoutConnecting(&data));
    /* The caller asked for the end: that is not an error to report */
    CHECK(data.errorCount == 0);

    VRCSessionDestroy(session);
    recorderFree(recorder);
    fakeServerStop(server);
    return true;
}

static bool testDestroyWhileConnecting(void)
{
    FakeServer* server = fakeServerStart(FakeServerHolds);
    Recorder* recorder = recorderNew();
    const VRCCallbacks callbacks = recorderCallbacks();
    VRCSession* session = VRCSessionCreate(&callbacks, recorder);
    CHECK(session != NULL);

    const VRCConnectionParams params = loopbackParams(fakeServerPort(server));
    CHECK(VRCSessionConnect(session, &params) == VRCResultOK);
    CHECK(recorderWaitForState(recorder, VRCSessionStateConnecting, STATE_TIMEOUT_MS));
    sleepMs(SETTLE_MS);

    const int64_t started = monotonicMs();
    VRCSessionDestroy(session);
    const int64_t elapsed = monotonicMs() - started;
    printf("destroyed in %lld ms\n", (long long)elapsed);
    CHECK(elapsed < STOP_BUDGET_MS);

    /* Destroy waits for the thread, so its last callback has already run */
    const RecorderSnapshot data = recorderSnapshot(recorder);
    CHECK(endedWithoutConnecting(&data));
    CHECK(data.errorCount == 0);

    recorderFree(recorder);
    fakeServerStop(server);
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "lifecycle", testLifecycle },
    { "invalidArguments", testInvalidArguments },
    { "connectRefused", testConnectRefused },
    { "serverClosesConnection", testServerClosesConnection },
    { "disconnectWhileConnecting", testDisconnectWhileConnecting },
    { "destroyWhileConnecting", testDestroyWhileConnecting },
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
