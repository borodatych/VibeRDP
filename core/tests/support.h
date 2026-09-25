/*
 * Test support: a recorder of session callbacks and fake TCP servers on the loopback interface
 * The servers never speak RDP: they only let a test choose how the transport behaves
 */

#ifndef VRC_TEST_SUPPORT_H
#define VRC_TEST_SUPPORT_H

#include <stdbool.h>
#include <stdint.h>

#include "VibeRDPCore/VibeRDPCore.h"

#define RECORDED_STATES_MAX 16
#define RECORDED_TEXT_MAX 256
#define RECORDED_PEM_MAX 16384

typedef struct Recorder Recorder;

/* A consistent copy of everything the callbacks reported so far */
typedef struct RecorderSnapshot {
    VRCSessionState states[RECORDED_STATES_MAX];
    int stateCount;
    int errorCount;
    VRCErrorKind errorKind;
    uint32_t errorCode;
    char errorName[RECORDED_TEXT_MAX];
    char errorMessage[RECORDED_TEXT_MAX];
    int certificateCount;
    char certificateHost[RECORDED_TEXT_MAX];
    uint16_t certificatePort;
    /* NUL-terminated copy of the last chain, cut to the buffer */
    char certificatePem[RECORDED_PEM_MAX];
    int credentialsCount;
    VRCCredentialsTarget credentialsTarget;
    /* The user name of the last request; empty when it had none */
    char credentialsUsername[RECORDED_TEXT_MAX];
} RecorderSnapshot;

Recorder* recorderNew(void);
void recorderFree(Recorder* recorder);

/*
 * Callbacks that feed the recorder passed as userData; certificate requests are recorded and left pending
 * Credentials are not asked for: a test that wants the question sets recorderOnCredentialsNeeded itself
 */
VRCCallbacks recorderCallbacks(void);

/* Records a credentials request and leaves it pending */
void recorderOnCredentialsNeeded(void* userData, const VRCCredentialsRequest* request);

bool recorderWaitForState(Recorder* recorder, VRCSessionState state, int timeoutMs);
bool recorderWaitForCertificate(Recorder* recorder, int timeoutMs);
bool recorderWaitForCredentials(Recorder* recorder, int timeoutMs);
RecorderSnapshot recorderSnapshot(Recorder* recorder);

typedef enum FakeServerMode {
    /* Accepts every connection and closes it at once */
    FakeServerCloses,
    /* Accepts every connection and keeps it open without a byte in reply */
    FakeServerHolds,
} FakeServerMode;

typedef struct FakeServer FakeServer;

FakeServer* fakeServerStart(FakeServerMode mode);
uint16_t fakeServerPort(const FakeServer* server);
int fakeServerAcceptedCount(FakeServer* server);
void fakeServerStop(FakeServer* server);

/* A loopback port that was free a moment ago: connecting to it is refused */
uint16_t unusedPort(void);

int64_t monotonicMs(void);
void sleepMs(int milliseconds);

#endif
