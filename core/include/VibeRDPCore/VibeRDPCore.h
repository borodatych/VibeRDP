/*
 * VibeRDPCore: flat C API over FreeRDP for the macOS client
 * No FreeRDP type crosses this header, so Swift never sees the engine internals
 *
 * Threading:
 * Every callback runs on the session thread that the core owns, never on the caller's thread
 * Callbacks must return quickly and must not call VRCSessionDestroy: it waits for the session thread
 */

#ifndef VIBERDPCORE_H
#define VIBERDPCORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Clang imports such enums into Swift as native enums with short case names */
#if defined(__clang__)
#define VRC_ENUM(name) enum __attribute__((enum_extensibility(closed))) name : int32_t
#else
#define VRC_ENUM(name) enum name
#endif

typedef VRC_ENUM(VRCResult) {
    VRCResultOK = 0,
    VRCResultInvalidArgument = 1,
    VRCResultInvalidState = 2,
    VRCResultFailure = 3,
} VRCResult;

/* Lifecycle of a session as the callbacks report it: Connecting, then Connected if it succeeds, then Disconnected */
typedef VRC_ENUM(VRCSessionState) {
    VRCSessionStateIdle = 0,
    VRCSessionStateConnecting = 1,
    VRCSessionStateConnected = 2,
    VRCSessionStateDisconnected = 3,
} VRCSessionState;

typedef struct VRCSession VRCSession;

typedef struct VRCCallbacks {
    /* The session entered a new state */
    void (*stateChanged)(void* userData, VRCSessionState state);

    /*
     * The session ended for a reason other than VRCSessionDisconnect: a failure or a disconnect by the server
     * It comes right before Disconnected; code is the FreeRDP error code
     * name and message stay valid only during the call
     */
    void (*error)(void* userData, uint32_t code, const char* name, const char* message);
} VRCCallbacks;

typedef struct VRCConnectionParams {
    const char* host;     /* Required: host name or address */
    uint16_t port;        /* 0 keeps the default RDP port */
    const char* username; /* Optional */
    const char* domain;   /* Optional */
    const char* password; /* Optional */
} VRCConnectionParams;

/*
 * Creates an idle session: the callbacks are copied, userData goes back to them untouched
 * callbacks may be NULL, and so may any of its members
 * Returns NULL when the engine cannot allocate the session
 */
VRCSession* VRCSessionCreate(const VRCCallbacks* callbacks, void* userData);

/*
 * Stops the session thread if it runs and frees the session; NULL is ignored
 * Calling it from a callback aborts the process: the thread cannot wait for itself
 */
void VRCSessionDestroy(VRCSession* session);

/*
 * Starts connecting on the session thread and returns at once; the strings are copied
 * A session connects once: a new connection takes a new session
 */
VRCResult VRCSessionConnect(VRCSession* session, const VRCConnectionParams* params);

/* Asks the session to end and returns at once: Disconnected follows on the session thread */
void VRCSessionDisconnect(VRCSession* session);

#ifdef __cplusplus
}
#endif

#endif
