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
 * Credentials:
 * When the engine needs a user name or password it was not given, credentialsNeeded asks the app,
 * and the session waits until VRCSessionProvideCredentials or VRCSessionCancelCredentials answers
 * or the session is asked to end; a wrong password ends the session, and the app retries with a new one
 *
 * Reconnection:
 * A connection that drops by itself, not ended by the server or the user, is restored: Reconnecting,
 * then Connected again with a new surface, or Disconnected once the attempts run out
 * Input queued while the connection is down is dropped, and no key stays held on the server
 *
 * RD Gateway:
 * With a gateway the engine reaches the computer through it: the gateway presents its own certificate
 * and may ask for its own credentials, and a message that needs consent waits for VRCSessionResolveGatewayMessage
 *
 * The remote desktop:
 * The engine draws into an IOSurface of the desktop size, BGRA in memory; the app shows it without a copy
 * frameResized gives the size of a new surface, frameUpdated the rectangle that changed in it
 *
 * Input:
 * The app queues mouse and keyboard events from any thread and never waits for the network
 * The session thread sends them
 * The queue holds them until the connection is active, also while the server reactivates it, and keeps their order
 * pointerChanged brings the pointer the server draws with, so the app can show it as its cursor
 * Keys go by scan code: the server turns them into characters with the keyboard layout of the remote session
 *
 * Clipboard:
 * Each side announces what its clipboard offers, and the data moves only when the other side pastes it
 * The app offers the formats of the Mac with VRCSessionOfferClipboard, even before Connected;
 * clipboardDataRequested asks for the data when Windows pastes, VRCSessionProvideClipboardData answers
 * remoteClipboardChanged announces what the clipboard of Windows offers,
 * and VRCSessionCopyRemoteClipboard fetches it when the Mac pastes, waiting for the server
 *
 * Files:
 * To Windows the app gives absolute paths, each ending with a zero byte; a folder brings everything inside it,
 * and the core reads the files itself whenever Windows asks for their contents
 * From Windows VRCSessionCopyRemoteClipboard gives the names at the top of the copy, each ending with a zero byte,
 * and VRCSessionCopyRemoteFiles brings the files themselves into a folder of the Mac
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
    VRCResultTimeout = 4,
    VRCResultCancelled = 5,
} VRCResult;

/*
 * Lifecycle of a session as the callbacks report it: Connecting, then Connected if it succeeds, then Disconnected
 * A connection that drops goes from Connected to Reconnecting, and back to Connected when it is restored
 */
typedef VRC_ENUM(VRCSessionState) {
    VRCSessionStateIdle = 0,
    VRCSessionStateConnecting = 1,
    VRCSessionStateConnected = 2,
    VRCSessionStateDisconnected = 3,
    VRCSessionStateReconnecting = 4,
} VRCSessionState;

/* The buttons of a mouse; Back and Forward are the side buttons that Windows calls X1 and X2 */
typedef VRC_ENUM(VRCMouseButton) {
    VRCMouseButtonLeft = 0,
    VRCMouseButtonRight = 1,
    VRCMouseButtonMiddle = 2,
    VRCMouseButtonBack = 3,
    VRCMouseButtonForward = 4,
} VRCMouseButton;

/* A positive rotation scrolls up, as a wheel turned away from the user, or right */
typedef VRC_ENUM(VRCWheelAxis) {
    VRCWheelAxisVertical = 0,
    VRCWheelAxisHorizontal = 1,
} VRCWheelAxis;

/* What the pointer over the desktop looks like */
typedef VRC_ENUM(VRCPointerKind) {
    VRCPointerKindImage = 0,  /* An image of the server: the request carries it */
    VRCPointerKindHidden = 1, /* The server hides the pointer, as over a playing video */
    VRCPointerKindSystem = 2, /* The client's own arrow */
} VRCPointerKind;

/* Where the sound of the remote computer plays */
typedef VRC_ENUM(VRCAudioMode) {
    VRCAudioModeOff = 0,    /* Nowhere: the server does not send it */
    VRCAudioModeLocal = 1,  /* On this Mac */
    VRCAudioModeRemote = 2, /* On the remote computer itself */
} VRCAudioMode;

/* What a clipboard holds, in the form the app works with; the core converts to and from the formats of Windows */
typedef VRC_ENUM(VRCClipboardFormat) {
    VRCClipboardFormatText = 1,  /* UTF-8, lines end in LF */
    VRCClipboardFormatHtml = 2,  /* UTF-8 HTML, a whole page or a part of one */
    VRCClipboardFormatRtf = 3,   /* RTF as it is written */
    VRCClipboardFormatImage = 4, /* A PNG file */
    VRCClipboardFormatFiles = 5, /* Files and folders, see VRCSessionCopyRemoteFiles */
} VRCClipboardFormat;

/* The image of a server pointer: BGRA in memory with straight alpha, rows top to bottom */
typedef struct VRCPointerImage {
    uint32_t width; /* Pixels of the remote desktop */
    uint32_t height;
    uint32_t hotspotX; /* The point that clicks, from the top left corner */
    uint32_t hotspotY;
    const uint8_t* pixels; /* width * 4 bytes per row */
} VRCPointerImage;

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

/*
 * A key of the PC keyboard is its scan code of set 1, as RDP carries it: the code in the low byte,
 * with VRC_KEY_EXTENDED for the keys a real keyboard prefixes with E0, such as the right Ctrl or the arrows
 */
#define VRC_KEY_EXTENDED 0x100u

/* Pause has no scan code of its own: for this key the core sends the sequence Windows expects */
#define VRC_KEY_PAUSE (VRC_KEY_EXTENDED | 0x46u)

typedef struct VRCSession VRCSession;

/* Whose credentials the engine asks for: the remote computer, or the RD Gateway in front of it */
typedef VRC_ENUM(VRCCredentialsTarget) {
    VRCCredentialsTargetServer = 0,
    VRCCredentialsTargetGateway = 1,
} VRCCredentialsTarget;

/* What a gateway says: a consent message before the connection, or a service message along the way */
typedef VRC_ENUM(VRCGatewayMessageKind) {
    VRCGatewayMessageKindConsent = 0,
    VRCGatewayMessageKindService = 1,
} VRCGatewayMessageKind;

typedef struct VRCGatewayMessage {
    VRCGatewayMessageKind kind;
    bool needsConsent; /* The connection waits for VRCSessionResolveGatewayMessage; otherwise it goes on */
    const char* text;  /* UTF-8, as the gateway administrator wrote it */
} VRCGatewayMessage;

/* The engine lacks a user name or a password for the target */
typedef struct VRCCredentialsRequest {
    VRCCredentialsTarget target;
    const char* username; /* What the engine holds, DOMAIN\user when it has a domain; NULL when nothing */
} VRCCredentialsRequest;

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

    /*
     * The server changed its pointer; image is set only for VRCPointerKindImage and stays valid only during the call
     * A server request to move the pointer is not passed on: macOS does not move the cursor from under the user
     */
    void (*pointerChanged)(void* userData, VRCPointerKind kind, const VRCPointerImage* image);

    /*
     * The engine needs credentials it was not given: the connection waits for an answer
     * The request stays valid only during the call
     * Without this callback the engine goes on without them: NLA then fails, TLS shows the logon screen of Windows
     */
    void (*credentialsNeeded)(void* userData, const VRCCredentialsRequest* request);

    /*
     * The gateway has a message for the user; the message stays valid only during the call
     * Without this callback a message that needs consent is declined, and the connection ends
     */
    void (*gatewayMessage)(void* userData, const VRCGatewayMessage* message);

    /* While Reconnecting: attempt of maxAttempts is about to start, the first one at once, the next ones after a pause */
    void (*reconnecting)(void* userData, uint32_t attempt, uint32_t maxAttempts);

    /*
     * The clipboard of the remote computer changed and offers these formats
     * None when it holds nothing the app takes; the array stays valid only during the call
     */
    void (*remoteClipboardChanged)(void* userData, const VRCClipboardFormat* formats, size_t count);

    /*
     * Something on the remote computer pastes the clipboard of the Mac: it waits for the data in this format
     * Answer with VRCSessionProvideClipboardData; without this callback the remote side gets no data
     */
    void (*clipboardDataRequested)(void* userData, VRCClipboardFormat format);
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
    uint32_t scale;       /* Scale of the desktop in percent, 200 on a Retina display at its pixels; 0 keeps 100 */
    VRCAudioMode audio;   /* Where the sound plays; 0 plays none */
    bool microphone;      /* The microphone of the Mac goes to Windows; macOS asks the user the first time */
    /* A folder of the Mac Windows sees as a drive, under the name given; NULL or empty shares none */
    const char* sharedFolder;
    const char* sharedFolderName; /* NULL or empty takes the last part of the path */
    const char* username; /* Optional; without a domain, DOMAIN\user is split and user@domain is kept whole */
    const char* domain;   /* Optional */
    const char* password; /* Optional; the engine settings keep it until VRCSessionDestroy */

    /* RD Gateway: NULL or empty connects directly */
    const char* gatewayHost;
    uint16_t gatewayPort;              /* 0 keeps the default, 443 */
    bool gatewayUsesServerCredentials; /* The gateway gets the user name and password of the computer */
    bool gatewayBypassLocal;           /* Addresses of the local network are reached directly */
    const char* gatewayUsername;       /* Optional, as username; ignored when the server credentials are used */
    const char* gatewayDomain;         /* Optional */
    const char* gatewayPassword;       /* Optional */
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
 * Answers the pending credentials request from any thread; the core copies the strings
 * Without a domain the user name is read as in VRCConnectionParams: DOMAIN\user is split, user@domain kept whole
 * An empty password goes on without one: over TLS Windows then asks on its own logon screen
 * InvalidState when no request is pending: already answered, or the session ended meanwhile
 */
VRCResult VRCSessionProvideCredentials(VRCSession* session, const char* username, const char* domain,
                                       const char* password);

/* Declines the pending credentials request: the session ends as after VRCSessionDisconnect, with no error */
VRCResult VRCSessionCancelCredentials(VRCSession* session);

/*
 * Answers a gateway message that needs consent: accept goes on, decline ends the connection
 * InvalidState when no such message is pending
 */
VRCResult VRCSessionResolveGatewayMessage(VRCSession* session, bool accept);

/*
 * The surface the engine draws the desktop into, retained for the caller; NULL while there is none
 * After frameResized the engine draws into a new surface, and the old one stays valid until released
 */
CF_RETURNS_RETAINED IOSurfaceRef VRCSessionCopyFrameSurface(VRCSession* session);

/*
 * Pointer input from any thread, in desktop pixels: the core clamps the point to the desktop
 * A move right after a move replaces it, so a slow link gets the latest position, not a backlog
 * InvalidState before Connected and after the session ends; Failure when the queue is full
 */
VRCResult VRCSessionSendMouseMove(VRCSession* session, uint32_t x, uint32_t y);

/*
 * A press or a release; Back and Forward go only to a server that announced them, and to others not at all
 * InvalidArgument for a value outside VRCMouseButton
 */
VRCResult VRCSessionSendMouseButton(VRCSession* session, VRCMouseButton button, bool pressed, uint32_t x,
                                    uint32_t y);

/*
 * A wheel rotation in the units of Windows: 120 is one notch, a smaller delta is a finer scroll
 * The core splits it into steps the protocol carries; a horizontal one goes only to a server that announced it
 * InvalidArgument for a value outside VRCWheelAxis
 */
VRCResult VRCSessionSendMouseWheel(VRCSession* session, VRCWheelAxis axis, int32_t delta, uint32_t x, uint32_t y);

/*
 * A press or a release of a key; repeat marks the presses the keyboard repeats while the key is held
 * The core remembers the keys the server holds down, so VRCSessionReleaseKeys can let them all go
 * InvalidArgument for a key that is no scan code: zero, above 0x7F, or with bits other than VRC_KEY_EXTENDED
 */
VRCResult VRCSessionSendKey(VRCSession* session, uint16_t key, bool pressed, bool repeat);

/* The desktop got the keyboard: the server learns the state of the lock keys, as from mstsc on focus */
VRCResult VRCSessionSendFocusIn(VRCSession* session, bool capsLock, bool numLock);

/* The desktop lost the keyboard: every key the server holds down is released, so none sticks there */
VRCResult VRCSessionReleaseKeys(VRCSession* session);

/*
 * The clipboard of the Mac changed: the formats it offers now, none when it holds nothing the remote side takes
 * The offer is kept and goes out again whenever the clipboard channel starts, so it may come before Connected
 * InvalidArgument for a value outside VRCClipboardFormat
 */
VRCResult VRCSessionOfferClipboard(VRCSession* session, const VRCClipboardFormat* formats, size_t count);

/*
 * The answer to clipboardDataRequested from any thread; the core copies the data
 * NULL data answers that the clipboard no longer holds the format
 * InvalidState when the remote side waits for no data in this format
 */
VRCResult VRCSessionProvideClipboardData(VRCSession* session, VRCClipboardFormat format, const void* data,
                                         size_t length);

/*
 * Fetches the data of the remote clipboard in a format it offers, waiting up to timeoutMs for the server
 * On OK *data holds a copy the caller frees with free
 * Text, HTML and RTF come zero-terminated, and *length does not count the zero
 * One fetch runs at a time, a second waits for the first; the end of the session ends the wait with Failure
 * InvalidState when the clipboard of the remote side does not offer the format or the channel is down,
 * Failure when the server could not give the data, Timeout when it did not answer in time
 */
VRCResult VRCSessionCopyRemoteClipboard(VRCSession* session, VRCClipboardFormat format, uint32_t timeoutMs,
                                        void** data, size_t* length);

/*
 * The progress of VRCSessionCopyRemoteFiles, on the thread that copies: bytes written and the bytes of all the files
 * Returning false cancels the copy
 */
typedef bool (*VRCFileProgress)(void* context, uint64_t done, uint64_t total);

/*
 * Copies the files and folders of the remote clipboard into an existing folder of the Mac, keeping their tree:
 * the names at its top are the ones VRCSessionCopyRemoteClipboard gives for VRCClipboardFormatFiles
 * Blocks until the copy ends, so it runs off the main thread; it waits up to timeoutMs for each answer of the server
 * progress may be NULL; a copy that stops leaves what it made so far, for the caller to remove
 * InvalidArgument when the folder cannot be opened, InvalidState when the remote side offers no files,
 * Failure when the server gives broken data or a file cannot be written, Timeout, or Cancelled by progress
 */
VRCResult VRCSessionCopyRemoteFiles(VRCSession* session, const char* directory, uint32_t timeoutMs,
                                    VRCFileProgress progress, void* context);

/*
 * Asks the server to send the whole desktop again, as after the Mac wakes:
 * a live connection repaints, and one that died during the sleep shows it at once rather than at its next timeout
 */
VRCResult VRCSessionRefresh(VRCSession* session);

/*
 * Asks the server for a desktop of this size, in pixels, and scale, in percent, as the window changes: the server
 * redraws the desktop at the new size and frameResized follows, as after any other change of size
 * The width goes even and both stay within 200 and 8192, the limits of the protocol; the scale stays within 100 and
 * 500, 0 is 100; a server without the Display Control channel keeps its size, and the app goes on scaling the frame
 * into the window
 * Requests go in order with the input, so a burst of them ends with the last one; InvalidState before Connected
 */
VRCResult VRCSessionResizeDesktop(VRCSession* session, uint32_t width, uint32_t height, uint32_t scale);

/*
 * Diagnostics log: the lines of the engine and of the app in one file, for someone to read when something goes wrong
 * The log is one for the process, not for a session: it is set before the first session, as the app starts
 */
typedef VRC_ENUM(VRCLogLevel) {
    VRCLogLevelDebug = 1,
    VRCLogLevelInfo = 2,
    VRCLogLevelWarning = 3,
    VRCLogLevelError = 4,
} VRCLogLevel;

/*
 * Writes the log of the engine and of VRCLog to this file from now on, appending; lines below the level are dropped
 * The folder is made when missing
 * InvalidArgument for a NULL path or a level outside VRCLogLevel, Failure when the file cannot be opened
 */
VRCResult VRCLogToFile(const char* path, VRCLogLevel level);

/* A line of the app in the log, under the category given; nothing happens while no log is set */
void VRCLog(VRCLogLevel level, const char* category, const char* message);

#ifdef __cplusplus
}
#endif

#endif
