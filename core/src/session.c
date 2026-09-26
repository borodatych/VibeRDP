/*
 * VibeRDPCore session: a FreeRDP client context driven by a thread of its own
 * The lifecycle follows the reference clients of FreeRDP: client/Sample and client/Mac
 */

/* memset_s clears a password so the compiler cannot drop the write; the header declares it only on request */
#define __STDC_WANT_LIB_EXT1__ 1

#include "VibeRDPCore/VibeRDPCore.h"
#include "clipboard.h"
#include "display.h"
#include "decision.h"
#include "frame.h"
#include "input.h"
#include "kerberos.h"
#include "pointer.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/client.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/error.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/graphics.h>
#include <freerdp/input.h>
#include <freerdp/scancode.h>
#include <winpr/string.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>
#include <winpr/thread.h>
#include <winpr/wlog.h>

/* The session in the diagnostics log, beside the lines the app writes under the same tag */
#define TAG "com.vibebrains.viberdp.session"

/* The public header keeps its own copies, since no FreeRDP type crosses it */
_Static_assert(VRC_KEY_EXTENDED == KBDEXT, "the extended bit of a key must be that of FreeRDP");
_Static_assert(VRC_KEY_PAUSE == RDP_SCANCODE_PAUSE, "Pause must be the key FreeRDP names so");

/* Where the credentials question stands; the answer itself is kept under credentialsMutex */
enum {
    CredentialsIdle,
    CredentialsPending,
    CredentialsProvided,
    CredentialsCancelled,
};

/* Pause between two reconnection attempts; FreeRDP pauses as long in its own reconnection loop */
#define RECONNECT_DELAY_MS 5000

/* VerifyX509Certificate: above zero accepts; 2 accepts for this connection only, since the store is the app's */
#define CERTIFICATE_ACCEPTED 2
#define CERTIFICATE_REJECTED 0

struct VRCSession {
    /* Must stay first: FreeRDP allocates the session as its client context and casts between the two */
    rdpClientContext common;
    VRCCallbacks callbacks;
    void* userData;
    atomic_bool started;
    /*
     * The user asked the session to end: the engine resets its own abort event before every reconnection attempt,
     * so the request must outlive it
     */
    atomic_bool ending;
    /* Answered by VRCSessionResolveCertificate */
    VRCDecision certificate;
    /* The core turned the certificate down: the TLS failure that follows is that decision, not a broken handshake */
    atomic_bool certificateRejected;
    /* Answered by VRCSessionResolveGatewayMessage */
    VRCDecision gatewayConsent;

    /* The credentials question: its state and the answer change together, under the mutex */
    pthread_mutex_t credentialsMutex;
    int credentialsState;
    char* answeredUsername;
    char* answeredDomain;
    char* answeredPassword;
    /* Set by VRCSessionProvideCredentials and VRCSessionCancelCredentials */
    HANDLE credentialsAnswered;

    /*
     * The surface the engine draws into; it changes only under the update lock of FreeRDP,
     * which also serializes the paints, and frameMutex lets VRCSessionCopyFrameSurface read it from any thread
     */
    IOSurfaceRef frame;
    pthread_mutex_t frameMutex;
    /* The surface locked for CPU writes between BeginPaint and EndPaint */
    IOSurfaceRef lockedFrame;

    /* Input the app queued; inputReady wakes the session thread, which alone sends it */
    VRCInputQueue input;
    HANDLE inputReady;
    /* The keys the server holds down: only the session thread touches it */
    VRCKeyState keys;

    /* The clipboard channel and what each side offers */
    VRCClipboard clipboard;

    /* The Display Control channel: the desktop follows the window */
    VRCDisplay display;
};

/* The pointer FreeRDP allocates with the size the core registers: the converted image rides along */
typedef struct VRCPointer {
    /* Must stay first: FreeRDP allocates the whole object and hands it over as its own type */
    rdpPointer pointer;
    uint8_t* image;
} VRCPointer;

/* The session served by the current thread: VRCSessionDestroy must not wait for its own thread */
static _Thread_local const VRCSession* threadSession = NULL;

static void notifyState(const VRCSession* session, VRCSessionState state)
{
    if (session->callbacks.stateChanged)
        session->callbacks.stateChanged(session->userData, state);
}

static VRCErrorKind errorKind(const VRCSession* session, UINT32 code)
{
    switch (code)
    {
        case FREERDP_ERROR_DNS_ERROR:
        case FREERDP_ERROR_DNS_NAME_NOT_FOUND:
            return VRCErrorKindHostNotFound;
        case FREERDP_ERROR_CONNECT_FAILED:
            return VRCErrorKindUnreachable;
        case FREERDP_ERROR_CONNECT_TRANSPORT_FAILED:
        case FREERDP_ERROR_MCS_CONNECT_INITIAL_ERROR:
            return VRCErrorKindConnectionLost;
        case FREERDP_ERROR_TLS_CONNECT_FAILED:
            return atomic_load(&session->certificateRejected) ? VRCErrorKindCertificateRejected
                                                              : VRCErrorKindSecurityFailed;
        case FREERDP_ERROR_SECURITY_NEGO_CONNECT_FAILED:
        case FREERDP_ERROR_CONNECT_HYBRID_REQUIRED_BY_SERVER:
            return VRCErrorKindSecurityFailed;
        case FREERDP_ERROR_AUTHENTICATION_FAILED:
        case FREERDP_ERROR_CONNECT_LOGON_FAILURE:
        case FREERDP_ERROR_CONNECT_WRONG_PASSWORD:
        case FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS:
            return VRCErrorKindAuthentication;
        case FREERDP_ERROR_INSUFFICIENT_PRIVILEGES:
        case FREERDP_ERROR_CONNECT_ACCESS_DENIED:
        case FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED:
        case FREERDP_ERROR_CONNECT_ACCOUNT_RESTRICTION:
        case FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT:
        case FREERDP_ERROR_CONNECT_ACCOUNT_EXPIRED:
        case FREERDP_ERROR_CONNECT_LOGON_TYPE_NOT_GRANTED:
            return VRCErrorKindAccountRestricted;
        case FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED:
        case FREERDP_ERROR_CONNECT_PASSWORD_CERTAINLY_EXPIRED:
        case FREERDP_ERROR_CONNECT_PASSWORD_MUST_CHANGE:
            return VRCErrorKindPasswordExpired;
        default:
            return VRCErrorKindOther;
    }
}

static void notifyError(const VRCSession* session, UINT32 code)
{
    if (session->callbacks.error)
        session->callbacks.error(session->userData, errorKind(session, code), code, freerdp_get_last_error_name(code),
                                 freerdp_get_last_error_string(code));
}

/* The common handlers leave the clipboard to the client: the core takes its channel here */
static void onChannelConnected(void* context, const ChannelConnectedEventArgs* event)
{
    VRCSession* session = (VRCSession*)context;
    WLog_INFO(TAG, "channel connected: %s", event->name);
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
        vrcClipboardAttach(&session->clipboard, (CliprdrClientContext*)event->pInterface);
    else if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0)
    {
        const rdpSettings* settings = session->common.context.settings;
        vrcDisplayAttach(&session->display, (DispClientContext*)event->pInterface,
                         freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
                         freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight),
                         freerdp_settings_get_uint32(settings, FreeRDP_DesktopScaleFactor));
    }
}

static void onChannelDisconnected(void* context, const ChannelDisconnectedEventArgs* event)
{
    VRCSession* session = (VRCSession*)context;
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
        vrcClipboardDetach(&session->clipboard, (CliprdrClientContext*)event->pInterface);
    else if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0)
        vrcDisplayDetach(&session->display, (DispClientContext*)event->pInterface);
}

static BOOL preConnect(freerdp* instance)
{
    wPubSub* pubSub = instance->context->pubSub;

    /* The common handlers set up the channels the client uses, the graphics pipeline among them */
    return PubSub_SubscribeChannelConnected(pubSub, freerdp_client_OnChannelConnectedEventHandler) >= 0 &&
           PubSub_SubscribeChannelDisconnected(pubSub, freerdp_client_OnChannelDisconnectedEventHandler) >= 0 &&
           PubSub_SubscribeChannelConnected(pubSub, onChannelConnected) >= 0 &&
           PubSub_SubscribeChannelDisconnected(pubSub, onChannelDisconnected) >= 0;
}

/* Swaps the surface the app reads; the caller holds the update lock, so no paint sees the change halfway */
static void replaceFrame(VRCSession* session, IOSurfaceRef surface)
{
    pthread_mutex_lock(&session->frameMutex);
    IOSurfaceRef old = session->frame;
    session->frame = surface;
    pthread_mutex_unlock(&session->frameMutex);
    if (old)
        CFRelease(old);
}

static void notifyFrameResized(const VRCSession* session, UINT32 width, UINT32 height)
{
    if (session->callbacks.frameResized)
        session->callbacks.frameResized(session->userData, width, height);
}

/* The changed rectangle, cut to the frame: the engine may invalidate beyond the edges */
static void notifyFrameUpdated(const VRCSession* session, const rdpGdi* gdi, const GDI_RGN* invalid)
{
    const INT32 left = invalid->x < 0 ? 0 : invalid->x;
    const INT32 top = invalid->y < 0 ? 0 : invalid->y;
    const INT32 right = invalid->x + invalid->w > gdi->width ? gdi->width : invalid->x + invalid->w;
    const INT32 bottom = invalid->y + invalid->h > gdi->height ? gdi->height : invalid->y + invalid->h;

    if (session->callbacks.frameUpdated && right > left && bottom > top)
        session->callbacks.frameUpdated(session->userData, (uint32_t)left, (uint32_t)top, (uint32_t)(right - left),
                                        (uint32_t)(bottom - top));
}

/* Paints run on engine threads under the update lock: with the graphics pipeline, on the channel thread */
static BOOL beginPaint(rdpContext* context)
{
    VRCSession* session = (VRCSession*)context;

    if (!session->lockedFrame && session->frame)
    {
        (void)IOSurfaceLock(session->frame, 0, NULL);
        session->lockedFrame = session->frame;
    }
    context->gdi->primary->hdc->hwnd->invalid->null = TRUE;
    return TRUE;
}

static BOOL endPaint(rdpContext* context)
{
    VRCSession* session = (VRCSession*)context;
    HGDI_WND window = context->gdi->primary->hdc->hwnd;

    if (session->lockedFrame)
    {
        (void)IOSurfaceUnlock(session->lockedFrame, 0, NULL);
        session->lockedFrame = NULL;
    }
    if (!window->invalid->null)
        notifyFrameUpdated(session, context->gdi, window->invalid);
    window->ninvalid = 0;
    return TRUE;
}

/* The server changed the desktop size: a new surface replaces the old one together with the engine buffer */
static BOOL desktopResize(rdpContext* context)
{
    VRCSession* session = (VRCSession*)context;
    const UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    const UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    IOSurfaceRef surface = vrcFrameSurfaceCreate(width, height);
    if (!surface)
        return FALSE;

    rdp_update_lock(context->update);
    const BOOL resized = gdi_resize_ex(context->gdi, width, height, (UINT32)IOSurfaceGetBytesPerRow(surface),
                                       PIXEL_FORMAT_BGRX32, IOSurfaceGetBaseAddress(surface), NULL);
    if (resized)
        replaceFrame(session, surface);
    else
        CFRelease(surface);
    rdp_update_unlock(context->update);

    if (resized)
        notifyFrameResized(session, width, height);
    return resized;
}

static void notifyPointer(const VRCSession* session, VRCPointerKind kind, const VRCPointerImage* image)
{
    if (session->callbacks.pointerChanged)
        session->callbacks.pointerChanged(session->userData, kind, image);
}

/*
 * A new server pointer, converted once and kept for every time the server selects it again
 * It always succeeds: FreeRDP drops the whole update on a failure, and a pointer without an image shows the arrow
 */
static BOOL pointerNew(rdpContext* context, rdpPointer* pointer)
{
    VRCPointer* own = (VRCPointer*)pointer;
    own->image = vrcPointerImageCreate(pointer->width, pointer->height, pointer->xorBpp, pointer->xorMaskData,
                                       pointer->lengthXorMask, pointer->andMaskData, pointer->lengthAndMask,
                                       context->gdi ? &context->gdi->palette : NULL);
    return TRUE;
}

static void pointerFree(rdpContext* context, rdpPointer* pointer)
{
    (void)context;
    VRCPointer* own = (VRCPointer*)pointer;
    free(own->image);
    own->image = NULL;
}

/* An empty pointer hides it; one that did not convert falls back to the arrow rather than leaving a stale image */
static BOOL pointerSet(rdpContext* context, rdpPointer* pointer)
{
    const VRCSession* session = (const VRCSession*)context;
    const VRCPointer* own = (const VRCPointer*)pointer;

    if (!own->image)
    {
        const bool empty = pointer->width == 0 || pointer->height == 0;
        notifyPointer(session, empty ? VRCPointerKindHidden : VRCPointerKindSystem, NULL);
        return TRUE;
    }
    const VRCPointerImage image = {
        .width = pointer->width,
        .height = pointer->height,
        .hotspotX = pointer->xPos,
        .hotspotY = pointer->yPos,
        .pixels = own->image,
    };
    notifyPointer(session, VRCPointerKindImage, &image);
    return TRUE;
}

static BOOL pointerSetNull(rdpContext* context)
{
    notifyPointer((const VRCSession*)context, VRCPointerKindHidden, NULL);
    return TRUE;
}

static BOOL pointerSetDefault(rdpContext* context)
{
    notifyPointer((const VRCSession*)context, VRCPointerKindSystem, NULL);
    return TRUE;
}

/* macOS does not move the cursor from under the user: the request is taken and dropped */
static BOOL pointerSetPosition(rdpContext* context, UINT32 x, UINT32 y)
{
    (void)context;
    (void)x;
    (void)y;
    return TRUE;
}

static void registerPointer(rdpContext* context)
{
    const rdpPointer prototype = {
        .size = sizeof(VRCPointer),
        .New = pointerNew,
        .Free = pointerFree,
        .Set = pointerSet,
        .SetNull = pointerSetNull,
        .SetDefault = pointerSetDefault,
        .SetPosition = pointerSetPosition,
    };
    graphics_register_pointer(context->graphics, &prototype);
}

/* BGRX32 is B, G, R, X in memory: the byte order of a BGRA IOSurface and of MTLPixelFormatBGRA8Unorm */
static BOOL postConnect(freerdp* instance)
{
    rdpContext* context = instance->context;
    VRCSession* session = (VRCSession*)context;
    const UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    const UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    IOSurfaceRef surface = vrcFrameSurfaceCreate(width, height);
    if (!surface)
        return FALSE;

    /* No free function: the surface owns the memory, and the engine only draws into it */
    if (!gdi_init_ex(instance, PIXEL_FORMAT_BGRX32, (UINT32)IOSurfaceGetBytesPerRow(surface),
                     IOSurfaceGetBaseAddress(surface), NULL))
    {
        CFRelease(surface);
        return FALSE;
    }
    replaceFrame(session, surface);
    context->update->BeginPaint = beginPaint;
    context->update->EndPaint = endPaint;
    context->update->DesktopResize = desktopResize;
    registerPointer(context);
    notifyFrameResized(session, width, height);
    return TRUE;
}

static void postDisconnect(freerdp* instance)
{
    VRCSession* session = (VRCSession*)instance->context;
    wPubSub* pubSub = instance->context->pubSub;

    (void)PubSub_UnsubscribeChannelConnected(pubSub, freerdp_client_OnChannelConnectedEventHandler);
    (void)PubSub_UnsubscribeChannelDisconnected(pubSub, freerdp_client_OnChannelDisconnectedEventHandler);
    gdi_free(instance);
    if (session->lockedFrame)
    {
        (void)IOSurfaceUnlock(session->lockedFrame, 0, NULL);
        session->lockedFrame = NULL;
    }
    replaceFrame(session, NULL);
}

/* The protocol carries 16-bit coordinates, and the server expects a point on its desktop */
static UINT16 clampCoordinate(uint32_t value, UINT32 size)
{
    const uint32_t last = size == 0 ? 0 : (size > UINT16_MAX ? UINT16_MAX : size - 1);
    return (UINT16)(value < last ? value : last);
}

/* Runs on the session thread only, so no input races the teardown of the connection */
static void sendInput(VRCSession* session, const VRCInputEvent* event)
{
    rdpContext* context = &session->common.context;
    rdpSettings* settings = context->settings;
    const UINT16 x = clampCoordinate(event->x, freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth));
    const UINT16 y = clampCoordinate(event->y, freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight));

    switch (event->kind)
    {
        case VRCInputKindMove:
            (void)freerdp_input_send_mouse_event(context->input, PTR_FLAGS_MOVE, x, y);
            break;
        case VRCInputKindButton:
        {
            uint16_t flags = 0;
            bool extended = false;
            (void)vrcButtonFlags(event->button, event->pressed, &flags, &extended);
            if (!extended)
                (void)freerdp_input_send_mouse_event(context->input, flags, x, y);
            else if (freerdp_settings_get_bool(settings, FreeRDP_HasExtendedMouseEvent))
                (void)freerdp_input_send_extended_mouse_event(context->input, flags, x, y);
            break;
        }
        case VRCInputKindWheel:
        {
            /* FreeRDP itself drops an unsupported horizontal step, with a warning for each */
            if (event->axis == VRCWheelAxisHorizontal &&
                !freerdp_settings_get_bool(settings, FreeRDP_HasHorizontalWheel))
                break;
            uint16_t steps[VRC_WHEEL_MAX_STEPS];
            const size_t count = vrcWheelFlags(event->axis, event->delta, steps, ARRAYSIZE(steps));
            for (size_t i = 0; i < count; i++)
                (void)freerdp_input_send_mouse_event(context->input, steps[i], x, y);
            break;
        }
        case VRCInputKindKey:
            /* Pause is a whole sequence of presses and releases, so the server never holds it down */
            if (event->key == VRC_KEY_PAUSE)
            {
                if (event->pressed)
                    (void)freerdp_input_send_keyboard_pause_event(context->input);
                break;
            }
            (void)freerdp_input_send_keyboard_event_ex(context->input, event->pressed, event->repeat, event->key);
            vrcKeyStateSet(&session->keys, event->key, event->pressed);
            break;
        case VRCInputKindFocusIn:
        {
            const UINT16 toggles =
                (event->capsLock ? KBD_SYNC_CAPS_LOCK : 0) | (event->numLock ? KBD_SYNC_NUM_LOCK : 0);
            (void)freerdp_input_send_focus_in_event(context->input, toggles);
            break;
        }
        case VRCInputKindReleaseKeys:
        {
            uint16_t keys[VRC_KEY_COUNT];
            const size_t count = vrcKeyStateTakeDown(&session->keys, keys, ARRAYSIZE(keys));
            for (size_t i = 0; i < count; i++)
                (void)freerdp_input_send_keyboard_event_ex(context->input, FALSE, FALSE, keys[i]);
            break;
        }
        case VRCInputKindRefresh:
        {
            const RECTANGLE_16 desktop = {
                .left = 0,
                .top = 0,
                .right = (UINT16)(freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth) - 1),
                .bottom = (UINT16)(freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight) - 1),
            };
            (void)IFCALLRESULT(TRUE, context->update->RefreshRect, context, 1, &desktop);
            break;
        }
        case VRCInputKindResize:
            vrcDisplayRequest(&session->display, event->x, event->y, event->scale);
            break;
    }
}

/*
 * The connect call returns during the finalization of the connection, and a reactivation passes through it again:
 * until the state is active, the input waits in the queue in its order
 */
static void sendPendingInput(VRCSession* session)
{
    VRCInputEvent events[VRC_INPUT_QUEUE_CAPACITY];

    /* Reset before taking: an event queued meanwhile is either taken now or sets the signal again */
    (void)ResetEvent(session->inputReady);
    if (freerdp_get_state(&session->common.context) != CONNECTION_STATE_ACTIVE)
        return;
    const size_t count = vrcInputQueueTake(&session->input, events, ARRAYSIZE(events));
    for (size_t i = 0; i < count; i++)
        sendInput(session, &events[i]);
}

/*
 * Serves the connection until it drops or the session is asked to end
 * A stop without a reason gets a generic one, so the caller always learns why
 * True when the connection dropped by itself, so it may be restored
 */
static bool serveConnection(VRCSession* session)
{
    rdpContext* context = &session->common.context;
    HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };

    while (!freerdp_shall_disconnect_context(context))
    {
        /*
         * The last slots are the input queue and the clipboard: queued input and a list of the Mac due again wake
         * the thread as the network does, and the wait ends no later than that list is due
         */
        DWORD count = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles) - 2);
        if (count > 0)
        {
            handles[count++] = session->inputReady;
            handles[count++] = vrcClipboardRetryWake(&session->clipboard);
        }
        const DWORD timeout = vrcClipboardRetryWait(&session->clipboard, GetTickCount64());

        if (count == 0 || WaitForMultipleObjects(count, handles, FALSE, timeout) == WAIT_FAILED ||
            !freerdp_check_event_handles(context))
        {
            freerdp_set_last_error_if_not(context, FREERDP_ERROR_CONNECT_TRANSPORT_FAILED);
            return !atomic_load(&session->ending) && !freerdp_shall_disconnect_context(context);
        }
        sendPendingInput(session);
        vrcClipboardRetryDue(&session->clipboard, GetTickCount64());
    }
    return false;
}

/* The reconnection loop of FreeRDP asks before every attempt how long to pause after a failed one */
static SSIZE_T reconnectAttempt(freerdp* instance, const char* what, size_t current, void* userarg)
{
    (void)what;
    (void)userarg;
    VRCSession* session = (VRCSession*)instance->context;
    if (atomic_load(&session->ending))
        return -1;
    if (session->callbacks.reconnecting)
        session->callbacks.reconnecting(
            session->userData, (uint32_t)current + 1,
            freerdp_settings_get_uint32(instance->context->settings, FreeRDP_AutoReconnectMaxRetries));
    return RECONNECT_DELAY_MS;
}

/* Polled during the pause between attempts: the user's disconnect ends the loop there */
static BOOL stillWanted(freerdp* instance)
{
    const VRCSession* session = (const VRCSession*)instance->context;
    return !atomic_load(&session->ending) && !freerdp_shall_disconnect_context(instance->context);
}

/*
 * Restores a dropped connection with the reconnection loop of FreeRDP, which leaves out the drops a new attempt
 * cannot mend: an end the server chose and credentials that stopped working
 * Queued input belonged to the lost connection and goes with it, and the new one starts with no key held
 */
static bool restoreConnection(VRCSession* session)
{
    rdpContext* context = &session->common.context;

    vrcInputQueueClose(&session->input);
    session->keys = (VRCKeyState){ 0 };
    notifyState(session, VRCSessionStateReconnecting);
    /* Every attempt starts by clearing the error the drop left, so a restored connection reports none */
    if (!client_auto_reconnect_ex(context->instance, stillWanted))
        return false;

    vrcInputQueueOpen(&session->input);
    notifyState(session, VRCSessionStateConnected);
    return true;
}

/* Runs until the session ends, restoring the connection whenever it drops by itself */
static void runEventLoop(VRCSession* session)
{
    while (serveConnection(session) && restoreConnection(session))
        ;
}

static DWORD WINAPI sessionThread(LPVOID arg)
{
    VRCSession* session = arg;
    rdpContext* context = &session->common.context;

    threadSession = session;
    notifyState(session, VRCSessionStateConnecting);
    if (freerdp_connect(context->instance))
    {
        vrcInputQueueOpen(&session->input);
        notifyState(session, VRCSessionStateConnected);
        runEventLoop(session);
        vrcInputQueueClose(&session->input);
    }
    else
    {
        freerdp_set_last_error_if_not(context, FREERDP_ERROR_CONNECT_FAILED);
    }

    const UINT32 code = freerdp_get_last_error(context);
    (void)freerdp_disconnect(context->instance);
    /* A cancel is the caller's own VRCSessionDisconnect, not a reason to report */
    if (code != FREERDP_ERROR_SUCCESS && code != FREERDP_ERROR_CONNECT_CANCELLED)
        notifyError(session, code);
    notifyState(session, VRCSessionStateDisconnected);
    return 0;
}

/* A copy that may hold a password: cleared before it is freed, so no stale copy stays in the heap */
static void freeSecret(char* secret)
{
    if (secret)
        (void)memset_s(secret, strlen(secret), 0, strlen(secret));
    free(secret);
}

/* Moves a string into a FreeRDP settings slot, which owns and later frees it */
static void replaceString(char** slot, char* value)
{
    freeSecret(*slot);
    *slot = value;
}

/*
 * Without a separate domain the user name follows the engine rule: DOMAIN\user is split,
 * user@domain goes whole with an empty domain, which CredSSP and the Client Info PDU expect
 */
static BOOL splitUsername(const char* username, const char* domain, char** user, char** userDomain)
{
    *user = NULL;
    *userDomain = NULL;
    if (domain || !username)
    {
        *user = username ? _strdup(username) : NULL;
        *userDomain = domain ? _strdup(domain) : NULL;
        return (!username || *user) && (!domain || *userDomain);
    }
    if (!freerdp_parse_username(username, user, userDomain))
        return FALSE;
    if (!*userDomain)
        *userDomain = _strdup("");
    return *userDomain != NULL;
}

/* DOMAIN\user, as the user typed it, for the question; NULL when the engine holds no user name */
static char* joinUsername(const char* username, const char* domain)
{
    if (!username || username[0] == '\0')
        return NULL;
    if (!domain || domain[0] == '\0')
        return _strdup(username);
    const size_t length = strlen(domain) + 1 + strlen(username) + 1;
    char* joined = malloc(length);
    if (joined)
        (void)snprintf(joined, length, "%s\\%s", domain, username);
    return joined;
}

/* The question the engine asks through AuthenticateEx: whose credentials, or none this client can answer */
static bool credentialsTarget(rdp_auth_reason reason, VRCCredentialsTarget* target)
{
    switch (reason)
    {
        case AUTH_NLA:
        case AUTH_TLS:
        case AUTH_RDP:
        case AUTH_RDSTLS:
            *target = VRCCredentialsTargetServer;
            return true;
        case GW_AUTH_HTTP:
        case GW_AUTH_RDG:
        case GW_AUTH_RPC:
            *target = VRCCredentialsTargetGateway;
            return true;
        default:
            /* Smart card and FIDO PINs: the client signs in with a password only */
            return false;
    }
}

/* Drops a stored answer; the caller holds credentialsMutex */
static void clearAnswer(VRCSession* session)
{
    freeSecret(session->answeredUsername);
    freeSecret(session->answeredDomain);
    freeSecret(session->answeredPassword);
    session->answeredUsername = NULL;
    session->answeredDomain = NULL;
    session->answeredPassword = NULL;
}

/*
 * Runs on the session thread when the engine lacks a user name or a password: the app answers, the thread waits
 * The slots belong to the engine settings: the server ones, or the gateway ones for a gateway reason
 */
static BOOL authenticate(freerdp* instance, char** username, char** password, char** domain, rdp_auth_reason reason)
{
    VRCSession* session = (VRCSession*)instance->context;
    VRCCredentialsTarget target = VRCCredentialsTargetServer;
    if (!credentialsTarget(reason, &target))
        return FALSE;
    /* Nothing to ask: the engine goes on without credentials, as it does without the callback of its own */
    if (!session->callbacks.credentialsNeeded)
        return TRUE;

    pthread_mutex_lock(&session->credentialsMutex);
    clearAnswer(session);
    session->credentialsState = CredentialsPending;
    (void)ResetEvent(session->credentialsAnswered);
    pthread_mutex_unlock(&session->credentialsMutex);

    char* shown = joinUsername(*username, *domain);
    const VRCCredentialsRequest request = { .target = target, .username = shown };
    session->callbacks.credentialsNeeded(session->userData, &request);
    free(shown);

    HANDLE handles[] = { session->credentialsAnswered, freerdp_abort_event(instance->context) };
    const DWORD status = WaitForMultipleObjects(ARRAYSIZE(handles), handles, FALSE, INFINITE);

    /* Back to idle before anything else: an answer racing with the abort now gets InvalidState */
    pthread_mutex_lock(&session->credentialsMutex);
    const int answer = session->credentialsState;
    session->credentialsState = CredentialsIdle;
    char* user = NULL;
    char* userDomain = NULL;
    BOOL provided = status == WAIT_OBJECT_0 && answer == CredentialsProvided &&
                    splitUsername(session->answeredUsername, session->answeredDomain, &user, &userDomain);
    if (provided)
    {
        char* secret = session->answeredPassword ? _strdup(session->answeredPassword) : _strdup("");
        provided = secret != NULL;
        if (provided)
        {
            replaceString(username, user);
            replaceString(domain, userDomain);
            replaceString(password, secret);
            user = NULL;
            userDomain = NULL;
        }
    }
    clearAnswer(session);
    pthread_mutex_unlock(&session->credentialsMutex);
    free(user);
    free(userDomain);
    return provided;
}

/* Runs on the session thread during the TLS handshake: the app decides, the engine keeps no certificate store */
static int verifyX509Certificate(freerdp* instance, const BYTE* data, size_t length, const char* hostname,
                                 UINT16 port, DWORD flags)
{
    (void)flags;
    VRCSession* session = (VRCSession*)instance->context;
    if (!session->callbacks.verifyCertificate)
    {
        atomic_store(&session->certificateRejected, true);
        return CERTIFICATE_REJECTED;
    }

    vrcDecisionOpen(&session->certificate);
    const VRCCertificateRequest request = { .host = hostname, .port = port, .pem = data, .pemLength = length };
    session->callbacks.verifyCertificate(session->userData, &request);

    if (vrcDecisionWait(&session->certificate, freerdp_abort_event(instance->context)))
        return CERTIFICATE_ACCEPTED;
    atomic_store(&session->certificateRejected, true);
    return CERTIFICATE_REJECTED;
}

/*
 * Runs on the session thread when the gateway has a message: the text goes to the app, and consent waits for it
 * length counts the bytes of UTF-16 text; a message that needs consent and has nobody to ask is declined
 */
static BOOL presentGatewayMessage(freerdp* instance, UINT32 type, BOOL isDisplayMandatory, BOOL isConsentMandatory,
                                  size_t length, const WCHAR* message)
{
    (void)isDisplayMandatory;
    VRCSession* session = (VRCSession*)instance->context;
    if (!session->callbacks.gatewayMessage)
        return !isConsentMandatory;

    char* text = message ? ConvertWCharNToUtf8Alloc(message, length / sizeof(WCHAR), NULL) : NULL;
    const VRCGatewayMessage request = {
        .kind = type == GATEWAY_MESSAGE_CONSENT ? VRCGatewayMessageKindConsent : VRCGatewayMessageKindService,
        .needsConsent = isConsentMandatory,
        .text = text ? text : "",
    };
    if (isConsentMandatory)
        vrcDecisionOpen(&session->gatewayConsent);
    session->callbacks.gatewayMessage(session->userData, &request);
    free(text);

    return !isConsentMandatory || vrcDecisionWait(&session->gatewayConsent, freerdp_abort_event(instance->context));
}

static BOOL clientNew(freerdp* instance, rdpContext* context)
{
    VRCSession* session = (VRCSession*)context;

    /* All are made even if one fails, so ClientFree meets them initialized */
    const bool certificate = vrcDecisionInit(&session->certificate);
    const bool gatewayConsent = vrcDecisionInit(&session->gatewayConsent);
    const bool clipboard = vrcClipboardInit(&session->clipboard, &session->callbacks, &session->userData);
    vrcDisplayInit(&session->display);
    atomic_init(&session->certificateRejected, false);
    /* A static initializer cannot fail, so ClientFree always meets a valid mutex */
    session->credentialsMutex = (pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;
    session->credentialsState = CredentialsIdle;
    session->answeredUsername = NULL;
    session->answeredDomain = NULL;
    session->answeredPassword = NULL;
    session->credentialsAnswered = CreateEventA(NULL, TRUE, FALSE, NULL);
    session->inputReady = CreateEventA(NULL, TRUE, FALSE, NULL);
    vrcInputQueueInit(&session->input);
    session->keys = (VRCKeyState){ 0 };
    session->frame = NULL;
    session->lockedFrame = NULL;
    /* A static initializer cannot fail, so ClientFree always meets a valid mutex */
    session->frameMutex = (pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;
    instance->PreConnect = preConnect;
    instance->PostConnect = postConnect;
    instance->PostDisconnect = postDisconnect;
    instance->VerifyX509Certificate = verifyX509Certificate;
    instance->AuthenticateEx = authenticate;
    instance->PresentGatewayMessage = presentGatewayMessage;
    instance->RetryDialog = reconnectAttempt;

    /*
     * The client library installs console prompts that read stdin and print to it; an app has neither
     * Credentials go through AuthenticateEx above; the rest the engine goes on without
     */
    instance->ChooseSmartcard = NULL;
    instance->VerifyCertificateEx = NULL;
    instance->VerifyChangedCertificateEx = NULL;
    instance->LogonErrorInfo = NULL;
    instance->GetAccessToken = NULL;
    return certificate && gatewayConsent && clipboard && session->credentialsAnswered != NULL &&
           session->inputReady != NULL;
}

static void clientFree(freerdp* instance, rdpContext* context)
{
    (void)instance;
    VRCSession* session = (VRCSession*)context;

    vrcDecisionDestroy(&session->certificate);
    vrcDecisionDestroy(&session->gatewayConsent);
    if (session->credentialsAnswered)
        (void)CloseHandle(session->credentialsAnswered);
    clearAnswer(session);
    pthread_mutex_destroy(&session->credentialsMutex);
    if (session->inputReady)
        (void)CloseHandle(session->inputReady);
    vrcInputQueueDestroy(&session->input);
    /* A session that connected released its surface in PostDisconnect; one that never did has none */
    replaceFrame(session, NULL);
    pthread_mutex_destroy(&session->frameMutex);
    /* A session that never connected named no cache */
    vrcKerberosCacheDestroy(freerdp_settings_get_string(context->settings, FreeRDP_KerberosCache));
    vrcClipboardDestroy(&session->clipboard);
    vrcDisplayDestroy(&session->display);
}

static int clientStart(rdpContext* context)
{
    rdpClientContext* common = (rdpClientContext*)context;

    common->thread = CreateThread(NULL, 0, sessionThread, context, 0, NULL);
    return common->thread ? 0 : -1;
}

static BOOL applyCredentials(rdpSettings* settings, const VRCConnectionParams* params)
{
    char* user = NULL;
    char* domain = NULL;
    const BOOL applied = splitUsername(params->username, params->domain, &user, &domain) &&
                         freerdp_settings_set_string(settings, FreeRDP_Username, user) &&
                         freerdp_settings_set_string(settings, FreeRDP_Domain, domain) &&
                         freerdp_settings_set_string(settings, FreeRDP_Password, params->password);
    free(user);
    free(domain);
    return applied;
}

/*
 * A gateway always, or only for addresses outside the local network; without a host the connection goes direct
 * With the server credentials the gateway starts with them too: the engine then asks for neither again
 */
static BOOL applyGateway(rdpSettings* settings, const VRCConnectionParams* params)
{
    if (!params->gatewayHost || params->gatewayHost[0] == '\0')
        return freerdp_set_gateway_usage_method(settings, TSC_PROXY_MODE_NONE_DIRECT);

    const bool same = params->gatewayUsesServerCredentials;
    char* user = NULL;
    char* domain = NULL;
    const BOOL split = splitUsername(same ? params->username : params->gatewayUsername,
                                     same ? params->domain : params->gatewayDomain, &user, &domain);
    const BOOL applied =
        split &&
        freerdp_set_gateway_usage_method(settings,
                                         params->gatewayBypassLocal ? TSC_PROXY_MODE_DETECT : TSC_PROXY_MODE_DIRECT) &&
        freerdp_settings_set_string(settings, FreeRDP_GatewayHostname, params->gatewayHost) &&
        (params->gatewayPort == 0 || freerdp_settings_set_uint32(settings, FreeRDP_GatewayPort, params->gatewayPort)) &&
        freerdp_settings_set_bool(settings, FreeRDP_GatewayUseSameCredentials, same) &&
        freerdp_settings_set_string(settings, FreeRDP_GatewayUsername, user) &&
        freerdp_settings_set_string(settings, FreeRDP_GatewayDomain, domain) &&
        freerdp_settings_set_string(settings, FreeRDP_GatewayPassword,
                                    same ? params->password : params->gatewayPassword);
    free(user);
    free(domain);
    return applied;
}

/*
 * The sound of the session: on the Mac the engine loads the audio channel, which needs the device channel as well,
 * and plays through AudioToolbox; on the remote computer the server keeps it; off, neither plays it
 */
static BOOL applyAudio(rdpSettings* settings, VRCAudioMode audio)
{
    return freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, audio == VRCAudioModeLocal) &&
           freerdp_settings_set_bool(settings, FreeRDP_RemoteConsoleAudio, audio == VRCAudioModeRemote);
}

static BOOL applyParams(rdpSettings* settings, const VRCConnectionParams* params)
{
    return freerdp_settings_set_string(settings, FreeRDP_ServerHostname, params->host) &&
           (params->port == 0 || freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, params->port)) &&
           (params->width == 0 || freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, params->width)) &&
           (params->height == 0 || freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, params->height)) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, vrcDisplayDesktopScale(params->scale)) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, vrcDisplayDeviceScale(params->scale)) &&
           applyAudio(settings, params->audio) && applyCredentials(settings, params) && applyGateway(settings, params);
}

/*
 * The graphics pipeline carries the modern codecs, and RemoteFX serves the servers without it;
 * a client leaves both off by default, and a server may refuse a client with no codec at all
 * H.264 in both forms, AVC420 and AVC444, decodes through VideoToolbox
 * Without these settings the client tells the server that it takes no H.264
 */
static BOOL applyGraphics(rdpSettings* settings)
{
    return freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_GfxH264, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, TRUE);
}

/* NLA and TLS stay negotiable; the legacy RDP Security layer has weak encryption and no server authentication */
static BOOL applySecurity(rdpSettings* settings)
{
    return freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_ExternalCertificateManagement, TRUE);
}

/*
 * Kerberos keeps the tickets of the session in a cache of its own, destroyed in ClientFree
 * Left to itself the engine switches to the default cache of the user once any cache holds the principal,
 * and when the default cache belongs to another principal, the new tickets overwrite it
 */
static BOOL applyKerberos(rdpSettings* settings)
{
    char name[VRC_KERBEROS_CACHE_NAME_SIZE];
    return vrcKerberosCacheName(name, sizeof(name)) &&
           freerdp_settings_set_string(settings, FreeRDP_KerberosCache, name);
}

/*
 * A dropped connection is restored: the client tells the server it can reconnect, and the server hands it
 * a cookie that brings it back to the same Windows session
 */
static BOOL applyReconnection(rdpSettings* settings)
{
    return freerdp_settings_set_bool(settings, FreeRDP_AutoReconnectionEnabled, TRUE);
}

/* FreeRDP loads the rdpdr and rdpsnd channels for these features, and the build leaves both channels out */
static BOOL disableFeaturesNeedingDeviceChannels(rdpSettings* settings)
{
    return freerdp_settings_set_bool(settings, FreeRDP_NetworkAutoDetect, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_SupportHeartbeatPdu, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_SupportMultitransport, FALSE);
}

VRCSession* VRCSessionCreate(const VRCCallbacks* callbacks, void* userData)
{
    RDP_CLIENT_ENTRY_POINTS entryPoints = { 0 };

    entryPoints.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
    entryPoints.Version = RDP_CLIENT_INTERFACE_VERSION;
    entryPoints.ContextSize = sizeof(VRCSession);
    entryPoints.ClientNew = clientNew;
    entryPoints.ClientFree = clientFree;
    entryPoints.ClientStart = clientStart;
    entryPoints.ClientStop = freerdp_client_common_stop;

    VRCSession* session = (VRCSession*)freerdp_client_context_new(&entryPoints);
    if (!session)
        return NULL;
    if (callbacks)
        session->callbacks = *callbacks;
    session->userData = userData;
    atomic_init(&session->started, false);
    atomic_init(&session->ending, false);
    return session;
}

void VRCSessionDestroy(VRCSession* session)
{
    if (!session)
        return;
    if (threadSession == session)
    {
        fputs("VRCSessionDestroy: called from a callback of the same session\n", stderr);
        abort();
    }
    (void)freerdp_client_stop(&session->common.context);
    freerdp_client_context_free(&session->common.context);
}

VRCResult VRCSessionConnect(VRCSession* session, const VRCConnectionParams* params)
{
    if (!session || !params || !params->host || params->host[0] == '\0' || params->audio > VRCAudioModeRemote)
        return VRCResultInvalidArgument;
    if (atomic_exchange(&session->started, true))
        return VRCResultInvalidState;

    rdpSettings* settings = session->common.context.settings;
    if (!applyParams(settings, params) || !applySecurity(settings) || !applyKerberos(settings) ||
        !applyReconnection(settings) || !applyGraphics(settings) ||
        !disableFeaturesNeedingDeviceChannels(settings) || freerdp_client_start(&session->common.context) != 0)
        return VRCResultFailure;
    return VRCResultOK;
}

void VRCSessionDisconnect(VRCSession* session)
{
    if (session && atomic_load(&session->started))
    {
        atomic_store(&session->ending, true);
        (void)freerdp_abort_connect_context(&session->common.context);
    }
}

/* Stores the answer and wakes the session thread, only while a question is pending */
static VRCResult answerCredentials(VRCSession* session, int answer, const char* username, const char* domain,
                                   const char* password)
{
    VRCResult result = VRCResultInvalidState;

    pthread_mutex_lock(&session->credentialsMutex);
    if (session->credentialsState == CredentialsPending)
    {
        session->answeredUsername = username ? _strdup(username) : NULL;
        session->answeredDomain = domain ? _strdup(domain) : NULL;
        session->answeredPassword = password ? _strdup(password) : NULL;
        const bool copied = (!username || session->answeredUsername) && (!domain || session->answeredDomain) &&
                            (!password || session->answeredPassword);
        /* An answer the core could not keep is a cancel: the session must not go on with half of it */
        session->credentialsState = copied ? answer : CredentialsCancelled;
        result = copied ? VRCResultOK : VRCResultFailure;
        (void)SetEvent(session->credentialsAnswered);
    }
    pthread_mutex_unlock(&session->credentialsMutex);
    return result;
}

VRCResult VRCSessionProvideCredentials(VRCSession* session, const char* username, const char* domain,
                                       const char* password)
{
    if (!session)
        return VRCResultInvalidArgument;
    return answerCredentials(session, CredentialsProvided, username, domain, password);
}

VRCResult VRCSessionCancelCredentials(VRCSession* session)
{
    if (!session)
        return VRCResultInvalidArgument;
    return answerCredentials(session, CredentialsCancelled, NULL, NULL, NULL);
}

VRCResult VRCSessionResolveCertificate(VRCSession* session, bool accept)
{
    if (!session)
        return VRCResultInvalidArgument;
    return vrcDecisionAnswer(&session->certificate, accept);
}

VRCResult VRCSessionResolveGatewayMessage(VRCSession* session, bool accept)
{
    if (!session)
        return VRCResultInvalidArgument;
    return vrcDecisionAnswer(&session->gatewayConsent, accept);
}

IOSurfaceRef VRCSessionCopyFrameSurface(VRCSession* session)
{
    if (!session)
        return NULL;

    pthread_mutex_lock(&session->frameMutex);
    IOSurfaceRef surface = session->frame;
    if (surface)
        CFRetain(surface);
    pthread_mutex_unlock(&session->frameMutex);
    return surface;
}

/* Queues the event and wakes the session thread; the caller never waits for the network */
static VRCResult queueInput(VRCSession* session, const VRCInputEvent* event)
{
    const VRCResult result = vrcInputQueuePush(&session->input, event);
    if (result == VRCResultOK)
        (void)SetEvent(session->inputReady);
    return result;
}

VRCResult VRCSessionSendMouseMove(VRCSession* session, uint32_t x, uint32_t y)
{
    if (!session)
        return VRCResultInvalidArgument;

    const VRCInputEvent event = { .kind = VRCInputKindMove, .x = x, .y = y };
    return queueInput(session, &event);
}

VRCResult VRCSessionSendMouseButton(VRCSession* session, VRCMouseButton button, bool pressed, uint32_t x,
                                    uint32_t y)
{
    uint16_t flags = 0;
    bool extended = false;
    if (!session || !vrcButtonFlags(button, pressed, &flags, &extended))
        return VRCResultInvalidArgument;

    const VRCInputEvent event = { .kind = VRCInputKindButton, .x = x, .y = y, .button = button, .pressed = pressed };
    return queueInput(session, &event);
}

VRCResult VRCSessionSendMouseWheel(VRCSession* session, VRCWheelAxis axis, int32_t delta, uint32_t x, uint32_t y)
{
    if (!session || (axis != VRCWheelAxisVertical && axis != VRCWheelAxisHorizontal))
        return VRCResultInvalidArgument;

    const VRCInputEvent event = { .kind = VRCInputKindWheel, .x = x, .y = y, .axis = axis, .delta = delta };
    return queueInput(session, &event);
}

VRCResult VRCSessionSendKey(VRCSession* session, uint16_t key, bool pressed, bool repeat)
{
    if (!session || !vrcKeyValid(key))
        return VRCResultInvalidArgument;

    const VRCInputEvent event = { .kind = VRCInputKindKey, .key = key, .pressed = pressed, .repeat = repeat };
    return queueInput(session, &event);
}

VRCResult VRCSessionSendFocusIn(VRCSession* session, bool capsLock, bool numLock)
{
    if (!session)
        return VRCResultInvalidArgument;

    const VRCInputEvent event = { .kind = VRCInputKindFocusIn, .capsLock = capsLock, .numLock = numLock };
    return queueInput(session, &event);
}

VRCResult VRCSessionReleaseKeys(VRCSession* session)
{
    if (!session)
        return VRCResultInvalidArgument;

    const VRCInputEvent event = { .kind = VRCInputKindReleaseKeys };
    return queueInput(session, &event);
}

VRCResult VRCSessionOfferClipboard(VRCSession* session, const VRCClipboardFormat* formats, size_t count)
{
    if (!session)
        return VRCResultInvalidArgument;
    return vrcClipboardOffer(&session->clipboard, formats, count);
}

VRCResult VRCSessionProvideClipboardData(VRCSession* session, VRCClipboardFormat format, const void* data,
                                         size_t length)
{
    if (!session)
        return VRCResultInvalidArgument;
    return vrcClipboardProvide(&session->clipboard, format, data, length);
}

VRCResult VRCSessionCopyRemoteClipboard(VRCSession* session, VRCClipboardFormat format, uint32_t timeoutMs,
                                        void** data, size_t* length)
{
    if (!session)
        return VRCResultInvalidArgument;
    return vrcClipboardCopyRemote(&session->clipboard, format, timeoutMs,
                                  freerdp_abort_event(&session->common.context), data, length);
}

VRCResult VRCSessionCopyRemoteFiles(VRCSession* session, const char* directory, uint32_t timeoutMs,
                                    VRCFileProgress progress, void* context)
{
    if (!session)
        return VRCResultInvalidArgument;
    return vrcClipboardCopyRemoteFiles(&session->clipboard, directory, timeoutMs,
                                       freerdp_abort_event(&session->common.context), progress, context);
}

VRCResult VRCSessionRefresh(VRCSession* session)
{
    if (!session)
        return VRCResultInvalidArgument;

    const VRCInputEvent event = { .kind = VRCInputKindRefresh };
    return queueInput(session, &event);
}

VRCResult VRCSessionResizeDesktop(VRCSession* session, uint32_t width, uint32_t height, uint32_t scale)
{
    if (!session || width == 0 || height == 0)
        return VRCResultInvalidArgument;

    /* The size rides in the coordinates of the event: a resize has no pointer */
    const VRCInputEvent event = { .kind = VRCInputKindResize, .x = width, .y = height, .scale = scale };
    return queueInput(session, &event);
}
