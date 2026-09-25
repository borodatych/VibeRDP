/*
 * VibeRDPCore: flat C API over FreeRDP for the macOS client
 * No FreeRDP type crosses this header, so Swift never sees the engine internals
 *
 * Threading:
 * Callbacks run on threads the core owns, never on the caller's thread: the session thread,
 * and for frameUpdated also the channel thread of the engine that carries the graphics pipeline
 * Callbacks must return quickly and must not call VRCSessionDestroy: it waits for those threads
 *
 * Server certificates:
 * The core trusts no certificate by itself: every chain goes to the verifyCertificate callback,
 * and the session waits until VRCSessionResolveCertificate answers or the session is asked to end
 *
 * The remote desktop:
 * The engine draws into an IOSurface of the desktop size, BGRA in memory; the app shows it without a copy
 * frameResized gives the size of a new surface, frameUpdated the rectangle that changed in it
 */

#ifndef VIBERDPCORE_H
#define VIBERDPCORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <CoreFoundation/CFBase.h>
#include <IOSurface/IOSurfaceRef.h>

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

/* Why a session ended: the app words the message itself, the engine code stays for diagnostics */
typedef VRC_ENUM(VRCErrorKind) {
    VRCErrorKindOther = 0,
    VRCErrorKindHostNotFound = 1,        /* The name does not resolve */
    VRCErrorKindUnreachable = 2,         /* Nothing accepts connections at the address and port */
    VRCErrorKindConnectionLost = 3,      /* The connection broke or the server hung up */
    VRCErrorKindSecurityFailed = 4,      /* No common security protocol, or the TLS handshake failed */
    VRCErrorKindCertificateRejected = 5, /* The server certificate was not trusted */
    VRCErrorKindAuthentication = 6,      /* Wrong or missing user name or password */
    VRCErrorKindAccountRestricted = 7,   /* The account is disabled, locked, expired or may not log on here */
    VRCErrorKindPasswordExpired = 8,     /* The password has to be changed first */
} VRCErrorKind;

typedef struct VRCSession VRCSession;

/* A certificate the server presented during the TLS handshake */
typedef struct VRCCertificateRequest {
    const char* host;   /* Name the client connects to: the certificate has to be issued for it */
    uint16_t port;
    const uint8_t* pem; /* Server certificate first, then the chain the server sent; PEM, not NUL-terminated */
    size_t pemLength;
} VRCCertificateRequest;

typedef struct VRCCallbacks {
    /* The session entered a new state */
    void (*stateChanged)(void* userData, VRCSessionState state);

    /*
     * The session ended for a reason other than VRCSessionDisconnect: a failure or a disconnect by the server
     * It comes right before Disconnected; code is the FreeRDP error code, name and message are its English text
     * name and message stay valid only during the call
     */
    void (*error)(void* userData, VRCErrorKind kind, uint32_t code, const char* name, const char* message);

    /*
     * The server presented a certificate: the connection waits for VRCSessionResolveCertificate
     * The request and its data stay valid only during the call: copy what the answer needs
     * Without this callback every certificate is rejected
     */
    void (*verifyCertificate)(void* userData, const VRCCertificateRequest* request);

    /* The desktop got a surface of this size in pixels: once before Connected, again whenever the server resizes it */
    void (*frameResized)(void* userData, uint32_t width, uint32_t height);

    /* Pixels changed inside this rectangle of the current surface */
    void (*frameUpdated)(void* userData, uint32_t x, uint32_t y, uint32_t width, uint32_t height);
} VRCCallbacks;

/*
 * Security is negotiated between NLA and TLS; the legacy RDP Security layer is refused:
 * its encryption is weak and it never authenticates the server
 */
typedef struct VRCConnectionParams {
    const char* host;     /* Required: host name or address */
    uint16_t port;        /* 0 keeps the default RDP port */
    uint32_t width;       /* Desktop size in pixels the client asks for; 0 keeps the engine default, 1024 */
    uint32_t height;      /* 0 keeps the engine default, 768 */
    const char* username; /* Optional; without a domain, DOMAIN\user is split and user@domain is kept whole */
    const char* domain;   /* Optional */
    const char* password; /* Optional; the engine settings keep it until VRCSessionDestroy */
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

/*
 * Answers the pending certificate request from any thread: accept continues the connection, reject ends it
 * Returns InvalidState when no request is pending: already answered, or the session ended meanwhile
 */
VRCResult VRCSessionResolveCertificate(VRCSession* session, bool accept);

/*
 * The surface the engine draws the desktop into, retained for the caller; NULL while there is none
 * After frameResized the engine draws into a new surface, and the old one stays valid until released
 */
CF_RETURNS_RETAINED IOSurfaceRef VRCSessionCopyFrameSurface(VRCSession* session);

#ifdef __cplusplus
}
#endif

#endif
