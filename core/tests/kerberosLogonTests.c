/*
 * Kerberos logon tests: NLA against the Kerberos test peer that core/scripts/build-core.sh starts
 * That server takes Kerberos logons and nothing else, so a session that connects got its ticket from the test KDC
 * The realm comes from the environment; without it every test skips itself
 * Usage: kerberosLogonTests <test name>; CTest registers every test separately
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "support.h"
#include "VibeRDPCore/VibeRDPCore.h"

/* A Kerberos exchange with a KDC on the loopback takes milliseconds; the margin is for a busy machine */
#define STATE_TIMEOUT_MS 10000
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

/* The realm of this run, as build-core.sh made it */
typedef struct Realm {
    const char* host;
    uint16_t port;
    const char* name;
    const char* user;
    const char* password;
} Realm;

static Realm realm;

/* False when build-core.sh started no realm; the engine reads the realm from KRB5_CONFIG */
static bool readRealm(void)
{
    const char* host = getenv("VIBERDP_KERBEROS_HOST");
    const char* port = getenv("VIBERDP_KERBEROS_PORT");
    const char* config = getenv("VIBERDP_KERBEROS_CONFIG");
    realm.name = getenv("VIBERDP_KERBEROS_REALM");
    realm.user = getenv("VIBERDP_KERBEROS_USER");
    realm.password = getenv("VIBERDP_KERBEROS_PASSWORD");
    if (!host || !port || !config || !realm.name || !realm.user || !realm.password)
        return false;

    realm.host = host;
    realm.port = (uint16_t)strtoul(port, NULL, 10);
    return realm.port != 0 && setenv("KRB5_CONFIG", config, 1) == 0;
}

static void printError(const RecorderSnapshot* data)
{
    printf("error kind %d, engine error 0x%08x %s: %s\n", (int)data->errorKind, data->errorCode, data->errorName,
           data->errorMessage);
}

/* Connects as the user with the password, accepting the certificate of the test server */
static VRCSession* connectAs(Recorder* recorder, const VRCCallbacks* callbacks, const char* username,
                             const char* password)
{
    VRCSession* session = VRCSessionCreate(callbacks, recorder);
    if (!session)
        return NULL;
    const VRCConnectionParams params = {
        .host = realm.host, .port = realm.port, .username = username, .password = password
    };
    if (VRCSessionConnect(session, &params) != VRCResultOK || !recorderWaitForCertificate(recorder, STATE_TIMEOUT_MS) ||
        VRCSessionResolveCertificate(session, true) != VRCResultOK)
    {
        VRCSessionDestroy(session);
        return NULL;
    }
    return session;
}

/* The logon of the user written one way or another: the session connects and ends cleanly on request */
static bool logsOnAs(const char* username)
{
    Recorder* recorder = recorderNew();
    VRCCallbacks callbacks = recorderCallbacks();
    callbacks.credentialsNeeded = recorderOnCredentialsNeeded;
    VRCSession* session = connectAs(recorder, &callbacks, username, realm.password);
    CHECK(session != NULL);
    const bool connected = recorderWaitForState(recorder, VRCSessionStateConnected, STATE_TIMEOUT_MS);
    RecorderSnapshot data = recorderSnapshot(recorder);
    printError(&data);
    CHECK(connected);

    VRCSessionDisconnect(session);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS));
    data = recorderSnapshot(recorder);
    CHECK(data.errorCount == 0);
    CHECK(data.credentialsCount == 0);

    VRCSessionDestroy(session);
    recorderFree(recorder);
    return true;
}

/* The user principal name: user@REALM */
static bool testLogonWithPrincipalName(void)
{
    char username[256];
    CHECK(snprintf(username, sizeof(username), "%s@%s", realm.user, realm.name) < (int)sizeof(username));
    return logsOnAs(username);
}

/* The domain in front, written in lower case as users often do: the engine takes it for the realm */
static bool testLogonWithDomainPrefix(void)
{
    char username[256];
    CHECK(snprintf(username, sizeof(username), "%s\\%s", realm.name, realm.user) < (int)sizeof(username));
    for (char* c = username; *c != '\\'; c++)
        *c = (char)(*c >= 'A' && *c <= 'Z' ? *c - 'A' + 'a' : *c);
    return logsOnAs(username);
}

/* A wrong password gets no ticket, and the server takes nothing else: the app hears of a failed logon */
static bool testWrongPasswordFailsTheLogon(void)
{
    char username[256];
    CHECK(snprintf(username, sizeof(username), "%s@%s", realm.user, realm.name) < (int)sizeof(username));

    Recorder* recorder = recorderNew();
    VRCCallbacks callbacks = recorderCallbacks();
    callbacks.credentialsNeeded = recorderOnCredentialsNeeded;
    VRCSession* session = connectAs(recorder, &callbacks, username, "not the password");
    CHECK(session != NULL);
    CHECK(recorderWaitForState(recorder, VRCSessionStateDisconnected, STATE_TIMEOUT_MS));

    const RecorderSnapshot data = recorderSnapshot(recorder);
    printError(&data);
    CHECK(data.errorCount == 1);
    CHECK(data.errorKind == VRCErrorKindAuthentication);
    CHECK(data.credentialsCount == 0);
    for (int i = 0; i < data.stateCount; i++)
        CHECK(data.states[i] != VRCSessionStateConnected);

    VRCSessionDestroy(session);
    recorderFree(recorder);
    return true;
}

/*
 * The tickets go into the memory cache of the session and leave with it; no cache of the user gets any
 * The Kerberos trace shows it: the framework keeps its Kerberos inside, out of reach of this test
 */
static bool testTicketsLeaveWithTheSession(void)
{
    char trace[512];
    CHECK(snprintf(trace, sizeof(trace), "%s/krb5-trace.XXXXXX", getenv("HOME")) < (int)sizeof(trace));
    const int descriptor = mkstemp(trace);
    CHECK(descriptor >= 0);
    CHECK(setenv("KRB5_TRACE", trace, 1) == 0);

    char username[256];
    CHECK(snprintf(username, sizeof(username), "%s@%s", realm.user, realm.name) < (int)sizeof(username));
    const bool loggedOn = logsOnAs(username);

    static char text[1 << 18];
    FILE* file = fdopen(descriptor, "r");
    CHECK(file != NULL);
    const size_t length = fread(text, 1, sizeof(text) - 1, file);
    text[length] = '\0';
    (void)fclose(file);
    (void)unlink(trace);
    CHECK(loggedOn);

    char stored[512];
    CHECK(snprintf(stored, sizeof(stored), " -> TERMSRV/%s@%s in MEMORY:VibeRDP.", realm.host, realm.name) <
          (int)sizeof(stored));
    const char* ticket = strstr(text, stored);
    CHECK(ticket != NULL);
    CHECK(strstr(ticket, "Destroying ccache MEMORY:VibeRDP.") != NULL);
    /* The system cache, a file and the KCM daemon hold the caches of the user */
    CHECK(strstr(text, " in API:") == NULL);
    CHECK(strstr(text, " in FILE:") == NULL);
    CHECK(strstr(text, " in KCM:") == NULL);
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "logonWithPrincipalName", testLogonWithPrincipalName },
    { "logonWithDomainPrefix", testLogonWithDomainPrefix },
    { "wrongPasswordFailsTheLogon", testWrongPasswordFailsTheLogon },
    { "ticketsLeaveWithTheSession", testTicketsLeaveWithTheSession },
};

int main(int argc, char* argv[])
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s <test name>\n", argv[0]);
        return 2;
    }
    for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); i++)
    {
        if (strcmp(tests[i].name, argv[1]) != 0)
            continue;
        if (!readRealm())
        {
            printf("no Kerberos test realm: build-test-server.sh builds its peers, build-core.sh starts them\n");
            return SKIPPED;
        }
        return tests[i].run() ? 0 : 1;
    }

    fprintf(stderr, "unknown test: %s\n", argv[1]);
    return 2;
}
