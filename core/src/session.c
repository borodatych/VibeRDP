/*
 * VibeRDPCore session: a FreeRDP client context driven by a thread of its own
 * The lifecycle follows the reference clients of FreeRDP: client/Sample and client/Mac
 */

#include "VibeRDPCore/VibeRDPCore.h"
#include "frame.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#include <freerdp/client.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/error.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <winpr/synch.h>
#include <winpr/thread.h>

/* Where the certificate question stands: only a pending request can be answered, and only once */
enum {
    CertificateIdle,
    CertificatePending,
    CertificateAccepted,
    CertificateRejected,
};

/* VerifyX509Certificate: above zero accepts; 2 accepts for this connection only, since the store is the app's */
#define CERTIFICATE_ACCEPTED 2
#define CERTIFICATE_REJECTED 0

struct VRCSession {
    /* Must stay first: FreeRDP allocates the session as its client context and casts between the two */
    rdpClientContext common;
    VRCCallbacks callbacks;
    void* userData;
    atomic_bool started;
    atomic_int certificateState;
    /* The core turned the certificate down: the TLS failure that follows is that decision, not a broken handshake */
    atomic_bool certificateRejected;
    /* Set by VRCSessionResolveCertificate; the session thread waits for it together with the abort event */
    HANDLE certificateAnswered;

    /*
     * The surface the engine draws into; it changes only under the update lock of FreeRDP,
     * which also serializes the paints, and frameMutex lets VRCSessionCopyFrameSurface read it from any thread
     */
    IOSurfaceRef frame;
    pthread_mutex_t frameMutex;
    /* The surface locked for CPU writes between BeginPaint and EndPaint */
    IOSurfaceRef lockedFrame;
};

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

static BOOL preConnect(freerdp* instance)
{
    wPubSub* pubSub = instance->context->pubSub;

    /* The common handlers set up the channels the client uses, the graphics pipeline among them */
    return PubSub_SubscribeChannelConnected(pubSub, freerdp_client_OnChannelConnectedEventHandler) >= 0 &&
           PubSub_SubscribeChannelDisconnected(pubSub, freerdp_client_OnChannelDisconnectedEventHandler) >= 0;
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

/* Runs until the session ends; a stop without a reason gets a generic one, so the caller always learns why */
static void runEventLoop(rdpContext* context)
{
    HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };

    while (!freerdp_shall_disconnect_context(context))
    {
        const DWORD count = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles));

        if (count == 0 || WaitForMultipleObjects(count, handles, FALSE, INFINITE) == WAIT_FAILED ||
            !freerdp_check_event_handles(context))
        {
            freerdp_set_last_error_if_not(context, FREERDP_ERROR_CONNECT_TRANSPORT_FAILED);
            break;
        }
    }
}

static DWORD WINAPI sessionThread(LPVOID arg)
{
    VRCSession* session = arg;
    rdpContext* context = &session->common.context;

    threadSession = session;
    notifyState(session, VRCSessionStateConnecting);
    if (freerdp_connect(context->instance))
    {
        notifyState(session, VRCSessionStateConnected);
        runEventLoop(context);
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

    (void)ResetEvent(session->certificateAnswered);
    atomic_store(&session->certificateState, CertificatePending);
    const VRCCertificateRequest request = { .host = hostname, .port = port, .pem = data, .pemLength = length };
    session->callbacks.verifyCertificate(session->userData, &request);

    HANDLE handles[] = { session->certificateAnswered, freerdp_abort_event(instance->context) };
    const DWORD status = WaitForMultipleObjects(ARRAYSIZE(handles), handles, FALSE, INFINITE);
    /* Back to idle before anything else: an answer racing with the abort now gets InvalidState */
    const int answer = atomic_exchange(&session->certificateState, CertificateIdle);
    if (status == WAIT_OBJECT_0 && answer == CertificateAccepted)
        return CERTIFICATE_ACCEPTED;
    atomic_store(&session->certificateRejected, true);
    return CERTIFICATE_REJECTED;
}

static BOOL clientNew(freerdp* instance, rdpContext* context)
{
    VRCSession* session = (VRCSession*)context;

    atomic_init(&session->certificateState, CertificateIdle);
    atomic_init(&session->certificateRejected, false);
    session->certificateAnswered = CreateEventA(NULL, TRUE, FALSE, NULL);
    session->frame = NULL;
    session->lockedFrame = NULL;
    /* A static initializer cannot fail, so ClientFree always meets a valid mutex */
    session->frameMutex = (pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;
    instance->PreConnect = preConnect;
    instance->PostConnect = postConnect;
    instance->PostDisconnect = postDisconnect;
    instance->VerifyX509Certificate = verifyX509Certificate;

    /*
     * The client library installs console prompts that read stdin and print to it; an app has neither
     * Without them the engine goes on without asking: missing credentials fail NLA with a reported error
     */
    instance->AuthenticateEx = NULL;
    instance->ChooseSmartcard = NULL;
    instance->VerifyCertificateEx = NULL;
    instance->VerifyChangedCertificateEx = NULL;
    instance->PresentGatewayMessage = NULL;
    instance->LogonErrorInfo = NULL;
    instance->GetAccessToken = NULL;
    return session->certificateAnswered != NULL;
}

static void clientFree(freerdp* instance, rdpContext* context)
{
    (void)instance;
    VRCSession* session = (VRCSession*)context;

    if (session->certificateAnswered)
        (void)CloseHandle(session->certificateAnswered);
    /* A session that connected released its surface in PostDisconnect; one that never did has none */
    replaceFrame(session, NULL);
    pthread_mutex_destroy(&session->frameMutex);
}

static int clientStart(rdpContext* context)
{
    rdpClientContext* common = (rdpClientContext*)context;

    common->thread = CreateThread(NULL, 0, sessionThread, context, 0, NULL);
    return common->thread ? 0 : -1;
}

/*
 * Without a separate domain the user name follows the engine rule: DOMAIN\user is split,
 * user@domain goes whole with an empty domain, which CredSSP and the Client Info PDU expect
 */
static BOOL applyCredentials(rdpSettings* settings, const VRCConnectionParams* params)
{
    if (params->domain || !params->username)
        return freerdp_settings_set_string(settings, FreeRDP_Username, params->username) &&
               freerdp_settings_set_string(settings, FreeRDP_Domain, params->domain) &&
               freerdp_settings_set_string(settings, FreeRDP_Password, params->password);

    char* user = NULL;
    char* domain = NULL;
    const BOOL applied = freerdp_parse_username(params->username, &user, &domain) &&
                         freerdp_settings_set_string(settings, FreeRDP_Username, user) &&
                         freerdp_settings_set_string(settings, FreeRDP_Domain, domain ? domain : "") &&
                         freerdp_settings_set_string(settings, FreeRDP_Password, params->password);
    free(user);
    free(domain);
    return applied;
}

static BOOL applyParams(rdpSettings* settings, const VRCConnectionParams* params)
{
    return freerdp_settings_set_string(settings, FreeRDP_ServerHostname, params->host) &&
           (params->port == 0 || freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, params->port)) &&
           (params->width == 0 || freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, params->width)) &&
           (params->height == 0 || freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, params->height)) &&
           applyCredentials(settings, params);
}

/*
 * The graphics pipeline carries the modern codecs, and RemoteFX serves the servers without it;
 * a client leaves both off by default, and a server may refuse a client with no codec at all
 */
static BOOL applyGraphics(rdpSettings* settings)
{
    return freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, TRUE);
}

/* NLA and TLS stay negotiable; the legacy RDP Security layer has weak encryption and no server authentication */
static BOOL applySecurity(rdpSettings* settings)
{
    return freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_ExternalCertificateManagement, TRUE);
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
    if (!session || !params || !params->host || params->host[0] == '\0')
        return VRCResultInvalidArgument;
    if (atomic_exchange(&session->started, true))
        return VRCResultInvalidState;

    rdpSettings* settings = session->common.context.settings;
    if (!applyParams(settings, params) || !applySecurity(settings) || !applyGraphics(settings) ||
        !disableFeaturesNeedingDeviceChannels(settings) || freerdp_client_start(&session->common.context) != 0)
        return VRCResultFailure;
    return VRCResultOK;
}

void VRCSessionDisconnect(VRCSession* session)
{
    if (session && atomic_load(&session->started))
        (void)freerdp_abort_connect_context(&session->common.context);
}

VRCResult VRCSessionResolveCertificate(VRCSession* session, bool accept)
{
    if (!session)
        return VRCResultInvalidArgument;

    int pending = CertificatePending;
    if (!atomic_compare_exchange_strong(&session->certificateState, &pending,
                                        accept ? CertificateAccepted : CertificateRejected))
        return VRCResultInvalidState;
    (void)SetEvent(session->certificateAnswered);
    return VRCResultOK;
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
