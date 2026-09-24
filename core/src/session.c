/*
 * VibeRDPCore session: a FreeRDP client context driven by a thread of its own
 * The lifecycle follows the reference clients of FreeRDP: client/Sample and client/Mac
 */

#include "VibeRDPCore/VibeRDPCore.h"

#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#include <freerdp/client.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <winpr/synch.h>
#include <winpr/thread.h>

struct VRCSession {
    /* Must stay first: FreeRDP allocates the session as its client context and casts between the two */
    rdpClientContext common;
    VRCCallbacks callbacks;
    void* userData;
    atomic_bool started;
};

/* The session served by the current thread: VRCSessionDestroy must not wait for its own thread */
static _Thread_local const VRCSession* threadSession = NULL;

static void notifyState(const VRCSession* session, VRCSessionState state)
{
    if (session->callbacks.stateChanged)
        session->callbacks.stateChanged(session->userData, state);
}

static void notifyError(const VRCSession* session, UINT32 code)
{
    if (session->callbacks.error)
        session->callbacks.error(session->userData, code, freerdp_get_last_error_name(code),
                                 freerdp_get_last_error_string(code));
}

static BOOL preConnect(freerdp* instance)
{
    wPubSub* pubSub = instance->context->pubSub;

    /* The common handlers set up the channels the client uses, the graphics pipeline among them */
    return PubSub_SubscribeChannelConnected(pubSub, freerdp_client_OnChannelConnectedEventHandler) >= 0 &&
           PubSub_SubscribeChannelDisconnected(pubSub, freerdp_client_OnChannelDisconnectedEventHandler) >= 0;
}

static BOOL postConnect(freerdp* instance)
{
    return gdi_init(instance, PIXEL_FORMAT_XRGB32);
}

static void postDisconnect(freerdp* instance)
{
    wPubSub* pubSub = instance->context->pubSub;

    (void)PubSub_UnsubscribeChannelConnected(pubSub, freerdp_client_OnChannelConnectedEventHandler);
    (void)PubSub_UnsubscribeChannelDisconnected(pubSub, freerdp_client_OnChannelDisconnectedEventHandler);
    gdi_free(instance);
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

static BOOL clientNew(freerdp* instance, rdpContext* context)
{
    (void)context;
    instance->PreConnect = preConnect;
    instance->PostConnect = postConnect;
    instance->PostDisconnect = postDisconnect;
    return TRUE;
}

static int clientStart(rdpContext* context)
{
    rdpClientContext* common = (rdpClientContext*)context;

    common->thread = CreateThread(NULL, 0, sessionThread, context, 0, NULL);
    return common->thread ? 0 : -1;
}

static BOOL applyParams(rdpSettings* settings, const VRCConnectionParams* params)
{
    return freerdp_settings_set_string(settings, FreeRDP_ServerHostname, params->host) &&
           (params->port == 0 || freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, params->port)) &&
           freerdp_settings_set_string(settings, FreeRDP_Username, params->username) &&
           freerdp_settings_set_string(settings, FreeRDP_Domain, params->domain) &&
           freerdp_settings_set_string(settings, FreeRDP_Password, params->password);
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
    if (!applyParams(settings, params) || !disableFeaturesNeedingDeviceChannels(settings) ||
        freerdp_client_start(&session->common.context) != 0)
        return VRCResultFailure;
    return VRCResultOK;
}

void VRCSessionDisconnect(VRCSession* session)
{
    if (session && atomic_load(&session->started))
        (void)freerdp_abort_connect_context(&session->common.context);
}
