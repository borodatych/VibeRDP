/*
 * Session tests: the lifecycle and the threading of VRCSession against local fake servers
 * Usage: sessionTests <test name>; CTest registers every test separately
 */

#include <stdio.h>
#include <string.h>

#include "support.h"
#include "tlsServer.h"
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
    printf("error kind %d, engine error 0x%08x %s: %s\n", (int)data->errorKind, data->errorCode, data->errorName,
           data->errorMessage);
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
    /* No desktop before Connected, so no surface to draw */
    CHECK(VRCSessionCopyFrameSurface(bare) == NULL);
    CHECK(VRCSessionCopyFrameSurface(NULL) == NULL);
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
    VRCConnectionParams unknownAudio = params;
    unknownAudio.audio = (VRCAudioMode)3;
    /* Monitors: none primary, a primary away from 0,0, two primaries, a monitor without a size */
    const VRCMonitor noPrimary[] = { { 0, 0, 1920, 1080, 100, false }, { 1920, 0, 1920, 1080, 100, false } };
    const VRCMonitor movedPrimary[] = { { 10, 0, 1920, 1080, 100, true }, { 1930, 0, 1920, 1080, 100, false } };
    const VRCMonitor twoPrimaries[] = { { 0, 0, 1920, 1080, 100, true }, { 0, 0, 1920, 1080, 100, true } };
    const VRCMonitor empty[] = { { 0, 0, 1920, 1080, 100, true }, { 1920, 0, 0, 1080, 100, false } };
    const VRCMonitor* const wrong[] = { noPrimary, movedPrimary, twoPrimaries, empty };
    CHECK(VRCSessionConnect(NULL, &params) == VRCResultInvalidArgument);
    CHECK(VRCSessionConnect(session, NULL) == VRCResultInvalidArgument);
    CHECK(VRCSessionConnect(session, &noHost) == VRCResultInvalidArgument);
    CHECK(VRCSessionConnect(session, &emptyHost) == VRCResultInvalidArgument);
    CHECK(VRCSessionConnect(session, &unknownAudio) == VRCResultInvalidArgument);
    for (size_t i = 0; i < sizeof(wrong) / sizeof(wrong[0]); i++)
    {
        VRCConnectionParams monitors = params;
        monitors.monitors = wrong[i];
        monitors.monitorCount = 2;
        CHECK(VRCSessionConnect(session, &monitors) == VRCResultInvalidArgument);
    }
    VRCConnectionParams tooMany = params;
    tooMany.monitors = noPrimary;
    tooMany.monitorCount = VRC_MAX_MONITORS + 1;
    CHECK(VRCSessionConnect(session, &tooMany) == VRCResultInvalidArgument);

    /* Rejected arguments leave the session idle, so the first valid connect still starts it */
    CHECK(VRCSessionConnect(session, &params) == VRCResultOK);
    CHECK(VRCSessionConnect(session, &params) == VRCResultInvalidState);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS));

    VRCSessionDestroy(session);
    recorderFree(recorder);
    return true;
}

/* Input reaches only a connected session: refused before Connected, after a failed connection and with bad values */
static bool testInputNeedsAConnection(void)
{
    Recorder* recorder = recorderNew();
    const VRCCallbacks callbacks = recorderCallbacks();
    VRCSession* session = VRCSessionCreate(&callbacks, recorder);
    CHECK(session != NULL);

    CHECK(VRCSessionSendMouseMove(NULL, 1, 1) == VRCResultInvalidArgument);
    CHECK(VRCSessionSendMouseButton(NULL, VRCMouseButtonLeft, true, 1, 1) == VRCResultInvalidArgument);
    CHECK(VRCSessionSendMouseWheel(NULL, VRCWheelAxisVertical, 120, 1, 1) == VRCResultInvalidArgument);
    CHECK(VRCSessionSendMouseButton(session, (VRCMouseButton)5, true, 1, 1) == VRCResultInvalidArgument);
    CHECK(VRCSessionSendMouseWheel(session, (VRCWheelAxis)2, 120, 1, 1) == VRCResultInvalidArgument);
    CHECK(VRCSessionSendKey(NULL, 0x1E, true, false) == VRCResultInvalidArgument);
    CHECK(VRCSessionSendFocusIn(NULL, false, true) == VRCResultInvalidArgument);
    CHECK(VRCSessionReleaseKeys(NULL) == VRCResultInvalidArgument);
    CHECK(VRCSessionSendKey(session, 0, true, false) == VRCResultInvalidArgument);
    CHECK(VRCSessionSendKey(session, 0x80, true, false) == VRCResultInvalidArgument);
    CHECK(VRCSessionSendKey(session, 0xE01D, true, false) == VRCResultInvalidArgument);

    CHECK(VRCSessionSendMouseMove(session, 1, 1) == VRCResultInvalidState);
    CHECK(VRCSessionSendKey(session, VRC_KEY_EXTENDED | 0x1D, true, false) == VRCResultInvalidState);
    const VRCConnectionParams params = loopbackParams(unusedPort());
    CHECK(VRCSessionConnect(session, &params) == VRCResultOK);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS));
    CHECK(VRCSessionSendMouseButton(session, VRCMouseButtonLeft, true, 1, 1) == VRCResultInvalidState);
    CHECK(VRCSessionSendMouseWheel(session, VRCWheelAxisVertical, 120, 1, 1) == VRCResultInvalidState);
    CHECK(VRCSessionSendKey(session, VRC_KEY_PAUSE, true, false) == VRCResultInvalidState);
    CHECK(VRCSessionSendFocusIn(session, true, true) == VRCResultInvalidState);
    CHECK(VRCSessionReleaseKeys(session) == VRCResultInvalidState);
    CHECK(VRCSessionRefresh(session) == VRCResultInvalidState);
    CHECK(VRCSessionRefresh(NULL) == VRCResultInvalidArgument);
    CHECK(VRCSessionResizeDesktop(session, 1920, 1200, 200) == VRCResultInvalidState);
    CHECK(VRCSessionResizeDesktop(session, 0, 1200, 100) == VRCResultInvalidArgument);
    CHECK(VRCSessionResizeDesktop(NULL, 1920, 1200, 100) == VRCResultInvalidArgument);

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
    CHECK(data.errorKind == VRCErrorKindUnreachable);
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
    CHECK(data.errorKind == VRCErrorKindConnectionLost);
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

/* Starts a session against the TLS server; it runs until it asks about the certificate */
static VRCSession* connectToTlsServer(const TlsServer* server, const VRCCallbacks* callbacks, Recorder* recorder)
{
    VRCSession* session = VRCSessionCreate(callbacks, recorder);
    const VRCConnectionParams params = loopbackParams(tlsServerPort(server));
    if (!session || VRCSessionConnect(session, &params) != VRCResultOK)
        return NULL;
    return session;
}

/*
 * Over TLS the engine asks for missing credentials before the handshake: the answer lets the connection go on,
 * so the certificate question follows it; a second answer finds nothing pending
 */
static bool testCredentialsProvided(void)
{
    TlsServer* server = tlsServerStart();
    Recorder* recorder = recorderNew();
    VRCCallbacks callbacks = recorderCallbacks();
    callbacks.credentialsNeeded = recorderOnCredentialsNeeded;
    VRCSession* session = connectToTlsServer(server, &callbacks, recorder);
    CHECK(session != NULL);
    CHECK(recorderWaitForCredentials(recorder, STATE_TIMEOUT_MS));

    RecorderSnapshot data = recorderSnapshot(recorder);
    CHECK(data.credentialsTarget == VRCCredentialsTargetServer);
    CHECK(data.credentialsUsername[0] == '\0');
    CHECK(data.certificateCount == 0);
    CHECK(VRCSessionProvideCredentials(session, "CORP\\alice", NULL, "secret") == VRCResultOK);
    CHECK(VRCSessionProvideCredentials(session, "CORP\\alice", NULL, "secret") == VRCResultInvalidState);

    CHECK(recorderWaitForCertificate(recorder, STATE_TIMEOUT_MS));
    CHECK(VRCSessionResolveCertificate(session, false) == VRCResultOK);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS));
    data = recorderSnapshot(recorder);
    printError(&data);
    CHECK(data.credentialsCount == 1);
    CHECK(data.errorKind == VRCErrorKindCertificateRejected);

    VRCSessionDestroy(session);
    recorderFree(recorder);
    tlsServerStop(server);
    return true;
}

/* A user name without a password is asked about too, and the question shows it with its domain */
static bool testCredentialsShowTheUserName(void)
{
    TlsServer* server = tlsServerStart();
    Recorder* recorder = recorderNew();
    VRCCallbacks callbacks = recorderCallbacks();
    callbacks.credentialsNeeded = recorderOnCredentialsNeeded;
    VRCSession* session = VRCSessionCreate(&callbacks, recorder);
    CHECK(session != NULL);
    VRCConnectionParams params = loopbackParams(tlsServerPort(server));
    params.username = "CORP\\bob";
    CHECK(VRCSessionConnect(session, &params) == VRCResultOK);
    CHECK(recorderWaitForCredentials(recorder, STATE_TIMEOUT_MS));

    const RecorderSnapshot data = recorderSnapshot(recorder);
    CHECK(strcmp(data.credentialsUsername, "CORP\\bob") == 0);
    CHECK(VRCSessionCancelCredentials(session) == VRCResultOK);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS));

    VRCSessionDestroy(session);
    recorderFree(recorder);
    tlsServerStop(server);
    return true;
}

/* A declined question ends the session as the user's own disconnect does: no error, and no certificate asked */
static bool testCredentialsCancelled(void)
{
    TlsServer* server = tlsServerStart();
    Recorder* recorder = recorderNew();
    VRCCallbacks callbacks = recorderCallbacks();
    callbacks.credentialsNeeded = recorderOnCredentialsNeeded;
    VRCSession* session = connectToTlsServer(server, &callbacks, recorder);
    CHECK(session != NULL);
    CHECK(recorderWaitForCredentials(recorder, STATE_TIMEOUT_MS));
    CHECK(VRCSessionCancelCredentials(session) == VRCResultOK);
    CHECK(VRCSessionCancelCredentials(session) == VRCResultInvalidState);
    CHECK(VRCSessionResolveGatewayMessage(NULL, true) == VRCResultInvalidArgument);
    CHECK(VRCSessionResolveGatewayMessage(session, true) == VRCResultInvalidState);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS));

    const RecorderSnapshot data = recorderSnapshot(recorder);
    printError(&data);
    CHECK(endedWithoutConnecting(&data));
    CHECK(data.errorCount == 0);
    CHECK(data.certificateCount == 0);
    CHECK(tlsServerContinuedCount(server) == 0);

    VRCSessionDestroy(session);
    recorderFree(recorder);
    tlsServerStop(server);
    return true;
}

/* The user's disconnect ends a question nobody answered, and a late answer finds nothing pending */
static bool testDisconnectWhileCredentialsPending(void)
{
    TlsServer* server = tlsServerStart();
    Recorder* recorder = recorderNew();
    VRCCallbacks callbacks = recorderCallbacks();
    callbacks.credentialsNeeded = recorderOnCredentialsNeeded;
    VRCSession* session = connectToTlsServer(server, &callbacks, recorder);
    CHECK(session != NULL);
    CHECK(recorderWaitForCredentials(recorder, STATE_TIMEOUT_MS));

    const int64_t started = monotonicMs();
    VRCSessionDisconnect(session);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STOP_BUDGET_MS));
    CHECK(monotonicMs() - started < STOP_BUDGET_MS);
    CHECK(VRCSessionProvideCredentials(session, "alice", NULL, "secret") == VRCResultInvalidState);
    CHECK(recorderSnapshot(recorder).errorCount == 0);

    VRCSessionDestroy(session);
    recorderFree(recorder);
    tlsServerStop(server);
    return true;
}

/*
 * With a gateway the client talks TLS to the gateway before anything else, so the first certificate is the gateway's:
 * its host and port, not those of the computer behind it
 */
static bool testGatewayComesFirst(void)
{
    TlsServer* gateway = tlsServerStartPlain();
    Recorder* recorder = recorderNew();
    const VRCCallbacks callbacks = recorderCallbacks();
    VRCSession* session = VRCSessionCreate(&callbacks, recorder);
    CHECK(session != NULL);
    const VRCConnectionParams params = {
        .host = "desktop.internal.invalid",
        .username = "CORP\\alice",
        .password = "secret",
        .gatewayHost = "127.0.0.1",
        .gatewayPort = tlsServerPort(gateway),
        .gatewayUsesServerCredentials = true,
    };
    CHECK(VRCSessionConnect(session, &params) == VRCResultOK);
    CHECK(recorderWaitForCertificate(recorder, STATE_TIMEOUT_MS));

    const RecorderSnapshot data = recorderSnapshot(recorder);
    CHECK(strcmp(data.certificateHost, "127.0.0.1") == 0);
    CHECK(data.certificatePort == tlsServerPort(gateway));
    CHECK(strncmp(data.certificatePem, tlsServerCertificatePem(gateway), strlen(tlsServerCertificatePem(gateway))) == 0);
    /* The server credentials went to the gateway as well, so nobody was asked */
    CHECK(data.credentialsCount == 0);

    VRCSessionDisconnect(session);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STOP_BUDGET_MS));
    VRCSessionDestroy(session);
    recorderFree(recorder);
    tlsServerStop(gateway);
    return true;
}

static bool testResolveWithoutRequest(void)
{
    VRCSession* session = VRCSessionCreate(NULL, NULL);
    CHECK(session != NULL);
    CHECK(VRCSessionResolveCertificate(NULL, true) == VRCResultInvalidArgument);
    CHECK(VRCSessionResolveCertificate(session, true) == VRCResultInvalidState);
    CHECK(VRCSessionResolveCertificate(session, false) == VRCResultInvalidState);
    CHECK(VRCSessionProvideCredentials(NULL, "alice", NULL, "secret") == VRCResultInvalidArgument);
    CHECK(VRCSessionCancelCredentials(NULL) == VRCResultInvalidArgument);
    CHECK(VRCSessionProvideCredentials(session, "alice", NULL, "secret") == VRCResultInvalidState);
    CHECK(VRCSessionCancelCredentials(session) == VRCResultInvalidState);
    VRCSessionDestroy(session);
    return true;
}

/* The chain reaches the callback with the host and port the client dialed; a rejection ends the connection */
static bool testCertificateRejected(void)
{
    TlsServer* server = tlsServerStart();
    Recorder* recorder = recorderNew();
    const VRCCallbacks callbacks = recorderCallbacks();
    VRCSession* session = connectToTlsServer(server, &callbacks, recorder);
    CHECK(session != NULL);
    CHECK(recorderWaitForCertificate(recorder, STATE_TIMEOUT_MS));

    RecorderSnapshot data = recorderSnapshot(recorder);
    const char* serverPem = tlsServerCertificatePem(server);
    CHECK(strcmp(data.certificateHost, "127.0.0.1") == 0);
    CHECK(data.certificatePort == tlsServerPort(server));
    /* The server certificate comes first; the chain may follow it */
    CHECK(strncmp(data.certificatePem, serverPem, strlen(serverPem)) == 0);

    CHECK(VRCSessionResolveCertificate(session, false) == VRCResultOK);
    CHECK(VRCSessionResolveCertificate(session, true) == VRCResultInvalidState);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS));

    data = recorderSnapshot(recorder);
    printError(&data);
    CHECK(endedWithoutConnecting(&data));
    CHECK(data.certificateCount == 1);
    CHECK(data.errorCount == 1);
    CHECK(data.errorKind == VRCErrorKindCertificateRejected);
    CHECK(tlsServerContinuedCount(server) == 0);

    VRCSessionDestroy(session);
    recorderFree(recorder);
    tlsServerStop(server);
    return true;
}

/* An accepted certificate lets the client go on over TLS; the fake server then hangs up */
static bool testCertificateAccepted(void)
{
    TlsServer* server = tlsServerStart();
    Recorder* recorder = recorderNew();
    const VRCCallbacks callbacks = recorderCallbacks();
    VRCSession* session = connectToTlsServer(server, &callbacks, recorder);
    CHECK(session != NULL);
    CHECK(recorderWaitForCertificate(recorder, STATE_TIMEOUT_MS));
    CHECK(VRCSessionResolveCertificate(session, true) == VRCResultOK);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS));

    /*
     * The hang-up is a transport failure, and freerdp_connect retries once after one;
     * the retry reuses the certificate accepted in this session, so the question is asked only once
     */
    const RecorderSnapshot data = recorderSnapshot(recorder);
    printError(&data);
    printf("the client went on over TLS %d times\n", tlsServerContinuedCount(server));
    CHECK(tlsServerContinuedCount(server) >= 1);
    CHECK(data.certificateCount == 1);
    CHECK(data.errorCount == 1);
    CHECK(data.errorKind == VRCErrorKindConnectionLost);

    VRCSessionDestroy(session);
    recorderFree(recorder);
    tlsServerStop(server);
    return true;
}

/* No callback, no trust: the certificate is rejected without asking anyone */
static bool testCertificateWithoutCallback(void)
{
    TlsServer* server = tlsServerStart();
    Recorder* recorder = recorderNew();
    VRCCallbacks callbacks = recorderCallbacks();
    callbacks.verifyCertificate = NULL;
    VRCSession* session = connectToTlsServer(server, &callbacks, recorder);
    CHECK(session != NULL);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS));

    const RecorderSnapshot data = recorderSnapshot(recorder);
    printError(&data);
    CHECK(data.errorCount == 1);
    CHECK(data.errorKind == VRCErrorKindCertificateRejected);
    CHECK(tlsServerContinuedCount(server) == 0);

    VRCSessionDestroy(session);
    recorderFree(recorder);
    tlsServerStop(server);
    return true;
}

/* A dialog left open must not hold the session: the cancel ends the wait and is not an error */
static bool testDisconnectWhileCertificatePending(void)
{
    TlsServer* server = tlsServerStart();
    Recorder* recorder = recorderNew();
    const VRCCallbacks callbacks = recorderCallbacks();
    VRCSession* session = connectToTlsServer(server, &callbacks, recorder);
    CHECK(session != NULL);
    CHECK(recorderWaitForCertificate(recorder, STATE_TIMEOUT_MS));

    const int64_t started = monotonicMs();
    VRCSessionDisconnect(session);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STOP_BUDGET_MS));
    printf("disconnected in %lld ms\n", (long long)(monotonicMs() - started));

    const RecorderSnapshot data = recorderSnapshot(recorder);
    printError(&data);
    CHECK(data.errorCount == 0);
    CHECK(tlsServerContinuedCount(server) == 0);
    /* The late answer of a dialog closed after the cancel finds nothing to answer */
    CHECK(VRCSessionResolveCertificate(session, true) == VRCResultInvalidState);

    VRCSessionDestroy(session);
    recorderFree(recorder);
    tlsServerStop(server);
    return true;
}

static bool testDestroyWhileCertificatePending(void)
{
    TlsServer* server = tlsServerStart();
    Recorder* recorder = recorderNew();
    const VRCCallbacks callbacks = recorderCallbacks();
    VRCSession* session = connectToTlsServer(server, &callbacks, recorder);
    CHECK(session != NULL);
    CHECK(recorderWaitForCertificate(recorder, STATE_TIMEOUT_MS));

    const int64_t started = monotonicMs();
    VRCSessionDestroy(session);
    const int64_t elapsed = monotonicMs() - started;
    printf("destroyed in %lld ms\n", (long long)elapsed);
    CHECK(elapsed < STOP_BUDGET_MS);

    const RecorderSnapshot data = recorderSnapshot(recorder);
    CHECK(data.errorCount == 0);
    CHECK(tlsServerContinuedCount(server) == 0);

    recorderFree(recorder);
    tlsServerStop(server);
    return true;
}

/* The reserved .invalid domain never resolves (RFC 6761) */
static bool testHostNotFound(void)
{
    Recorder* recorder = recorderNew();
    const VRCCallbacks callbacks = recorderCallbacks();
    VRCSession* session = VRCSessionCreate(&callbacks, recorder);
    CHECK(session != NULL);

    const VRCConnectionParams params = { .host = "viberdp-test.invalid" };
    CHECK(VRCSessionConnect(session, &params) == VRCResultOK);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS));

    const RecorderSnapshot data = recorderSnapshot(recorder);
    printError(&data);
    CHECK(endedWithoutConnecting(&data));
    CHECK(data.errorCount == 1);
    CHECK(data.errorKind == VRCErrorKindHostNotFound);

    VRCSessionDestroy(session);
    recorderFree(recorder);
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "lifecycle", testLifecycle },
    { "invalidArguments", testInvalidArguments },
    { "inputNeedsAConnection", testInputNeedsAConnection },
    { "connectRefused", testConnectRefused },
    { "serverClosesConnection", testServerClosesConnection },
    { "disconnectWhileConnecting", testDisconnectWhileConnecting },
    { "destroyWhileConnecting", testDestroyWhileConnecting },
    { "hostNotFound", testHostNotFound },
    { "resolveWithoutRequest", testResolveWithoutRequest },
    { "certificateRejected", testCertificateRejected },
    { "certificateAccepted", testCertificateAccepted },
    { "credentialsProvided", testCredentialsProvided },
    { "credentialsShowTheUserName", testCredentialsShowTheUserName },
    { "credentialsCancelled", testCredentialsCancelled },
    { "disconnectWhileCredentialsPending", testDisconnectWhileCredentialsPending },
    { "gatewayComesFirst", testGatewayComesFirst },
    { "certificateWithoutCallback", testCertificateWithoutCallback },
    { "disconnectWhileCertificatePending", testDisconnectWhileCertificatePending },
    { "destroyWhileCertificatePending", testDestroyWhileCertificatePending },
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
