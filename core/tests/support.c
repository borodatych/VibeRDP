#include "support.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define ACCEPT_POLL_MS 50
#define HELD_CONNECTIONS_MAX 16

struct Recorder {
    pthread_mutex_t mutex;
    pthread_cond_t changed;
    RecorderSnapshot data;
};

Recorder* recorderNew(void)
{
    Recorder* recorder = calloc(1, sizeof(Recorder));
    if (!recorder)
        abort();
    pthread_mutex_init(&recorder->mutex, NULL);
    pthread_cond_init(&recorder->changed, NULL);
    return recorder;
}

void recorderFree(Recorder* recorder)
{
    pthread_cond_destroy(&recorder->changed);
    pthread_mutex_destroy(&recorder->mutex);
    free(recorder);
}

static void onStateChanged(void* userData, VRCSessionState state)
{
    Recorder* recorder = userData;

    pthread_mutex_lock(&recorder->mutex);
    if (recorder->data.stateCount < RECORDED_STATES_MAX)
        recorder->data.states[recorder->data.stateCount++] = state;
    pthread_cond_broadcast(&recorder->changed);
    pthread_mutex_unlock(&recorder->mutex);
}

static void onError(void* userData, uint32_t code, const char* name, const char* message)
{
    Recorder* recorder = userData;

    pthread_mutex_lock(&recorder->mutex);
    recorder->data.errorCount++;
    recorder->data.errorCode = code;
    snprintf(recorder->data.errorName, sizeof(recorder->data.errorName), "%s", name ? name : "");
    snprintf(recorder->data.errorMessage, sizeof(recorder->data.errorMessage), "%s", message ? message : "");
    pthread_cond_broadcast(&recorder->changed);
    pthread_mutex_unlock(&recorder->mutex);
}

VRCCallbacks recorderCallbacks(void)
{
    VRCCallbacks callbacks = { .stateChanged = onStateChanged, .error = onError };
    return callbacks;
}

static bool hasState(const RecorderSnapshot* data, VRCSessionState state)
{
    for (int i = 0; i < data->stateCount; i++)
        if (data->states[i] == state)
            return true;
    return false;
}

bool recorderWaitForState(Recorder* recorder, VRCSessionState state, int timeoutMs)
{
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeoutMs / 1000;
    deadline.tv_nsec += (long)(timeoutMs % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L)
    {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000L;
    }

    pthread_mutex_lock(&recorder->mutex);
    int status = 0;
    while (!hasState(&recorder->data, state) && status != ETIMEDOUT)
        status = pthread_cond_timedwait(&recorder->changed, &recorder->mutex, &deadline);
    const bool reached = hasState(&recorder->data, state);
    pthread_mutex_unlock(&recorder->mutex);
    return reached;
}

RecorderSnapshot recorderSnapshot(Recorder* recorder)
{
    pthread_mutex_lock(&recorder->mutex);
    const RecorderSnapshot copy = recorder->data;
    pthread_mutex_unlock(&recorder->mutex);
    return copy;
}

struct FakeServer {
    FakeServerMode mode;
    int listener;
    uint16_t port;
    pthread_t thread;
    atomic_bool stopping;
    atomic_int accepted;
    int held[HELD_CONNECTIONS_MAX];
    int heldCount;
};

static int bindLoopback(uint16_t* port)
{
    const int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;

    struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = 0 };
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t length = sizeof(address);
    if (bind(fd, (struct sockaddr*)&address, sizeof(address)) != 0 ||
        getsockname(fd, (struct sockaddr*)&address, &length) != 0)
    {
        close(fd);
        return -1;
    }
    *port = ntohs(address.sin_port);
    return fd;
}

/* Polls the listener, so that the stop flag is seen without closing a socket under a blocked accept */
static void* serveLoop(void* arg)
{
    FakeServer* server = arg;
    struct pollfd listener = { .fd = server->listener, .events = POLLIN };

    while (!atomic_load(&server->stopping))
    {
        if (poll(&listener, 1, ACCEPT_POLL_MS) <= 0)
            continue;
        const int client = accept(server->listener, NULL, NULL);
        if (client < 0)
            continue;
        atomic_fetch_add(&server->accepted, 1);
        if (server->mode == FakeServerHolds && server->heldCount < HELD_CONNECTIONS_MAX)
            server->held[server->heldCount++] = client;
        else
            close(client);
    }
    return NULL;
}

FakeServer* fakeServerStart(FakeServerMode mode)
{
    FakeServer* server = calloc(1, sizeof(FakeServer));
    if (!server)
        abort();
    server->mode = mode;
    server->listener = bindLoopback(&server->port);
    if (server->listener < 0 || listen(server->listener, HELD_CONNECTIONS_MAX) != 0 ||
        pthread_create(&server->thread, NULL, serveLoop, server) != 0)
    {
        fprintf(stderr, "fake server failed to start: %s\n", strerror(errno));
        abort();
    }
    return server;
}

uint16_t fakeServerPort(const FakeServer* server)
{
    return server->port;
}

int fakeServerAcceptedCount(FakeServer* server)
{
    return atomic_load(&server->accepted);
}

void fakeServerStop(FakeServer* server)
{
    atomic_store(&server->stopping, true);
    pthread_join(server->thread, NULL);
    for (int i = 0; i < server->heldCount; i++)
        close(server->held[i]);
    close(server->listener);
    free(server);
}

uint16_t unusedPort(void)
{
    uint16_t port = 0;
    const int fd = bindLoopback(&port);
    if (fd < 0)
        abort();
    close(fd);
    return port;
}

int64_t monotonicMs(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

void sleepMs(int milliseconds)
{
    struct timespec interval = { .tv_sec = milliseconds / 1000, .tv_nsec = (long)(milliseconds % 1000) * 1000000L };
    nanosleep(&interval, NULL);
}
