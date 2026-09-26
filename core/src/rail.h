/*
 * RemoteApp (RAIL, MS-RDPERP): the windows of the server as the window orders describe them, and commands to them
 *
 * The session asks for RAIL when the app does; a server without it answers with a desktop, and the app hears it
 * refused, as it does when the server does not start the program
 * The window orders come on the session thread, the orders of the channel on its own thread;
 * the app sends commands from its threads, so the channel pointer is under a mutex
 */

#ifndef VRC_RAIL_H
#define VRC_RAIL_H

#include "VibeRDPCore/VibeRDPCore.h"

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>

#include <freerdp/client/rail.h>
#include <freerdp/freerdp.h>
#include <freerdp/window.h>

/* The program RAIL starts: the file manager, from which the user opens the rest */
#define VRC_RAIL_PROGRAM "explorer.exe"

/* Icons the server caches and later names by cache and entry: as many as the engine announces by default */
#define VRC_RAIL_ICON_SLOTS 64

typedef struct VRCRailIcon {
    uint32_t key; /* cache id in the high half, entry in the low one */
    uint32_t width;
    uint32_t height;
    uint8_t* pixels; /* BGRA, top-down */
} VRCRailIcon;

typedef struct VRCRail {
    pthread_mutex_t mutex;
    RailClientContext* channel; /* set while the channel is up */
    bool requested;             /* the app asked for RAIL on this connection */
    bool started;               /* the program was sent: the windows are the server's */
    VRCRailIcon icons[VRC_RAIL_ICON_SLOTS];
    size_t iconCount;
    const VRCCallbacks* callbacks;
    void* const* userData;
} VRCRail;

void vrcRailInit(VRCRail* rail, const VRCCallbacks* callbacks, void* const* userData);
void vrcRailDestroy(VRCRail* rail);

/* Asks for RAIL in the settings: the program, the language bar, the work area and no graphics pipeline */
BOOL vrcRailApply(VRCRail* rail, rdpSettings* settings);

/* After the connection: a server that did not grant RAIL answered with a desktop, and the app hears it refused */
void vrcRailConnected(VRCRail* rail, rdpSettings* settings);

/* The channel came up or went down; up, the window orders of the update go to the core */
void vrcRailAttach(VRCRail* rail, RailClientContext* channel, rdpUpdate* update);
void vrcRailDetach(VRCRail* rail, RailClientContext* channel);

/* The orders themselves, apart from the engine for the tests */
void vrcRailWindowOrder(VRCRail* rail, const WINDOW_ORDER_INFO* info, const WINDOW_STATE_ORDER* state);
void vrcRailWindowDeleted(VRCRail* rail, const WINDOW_ORDER_INFO* info);
void vrcRailWindowIcon(VRCRail* rail, const WINDOW_ORDER_INFO* info, const ICON_INFO* icon);
void vrcRailWindowCachedIcon(VRCRail* rail, const WINDOW_ORDER_INFO* info, const CACHED_ICON_INFO* cached);
void vrcRailDesktop(VRCRail* rail, const WINDOW_ORDER_INFO* info, const MONITORED_DESKTOP_ORDER* desktop);
void vrcRailExecuteResult(VRCRail* rail, const RAIL_EXEC_RESULT_ORDER* result);

VRCResult vrcRailActivate(VRCRail* rail, uint32_t id);
VRCResult vrcRailSystemCommand(VRCRail* rail, uint32_t id, VRCRailCommand command);
VRCResult vrcRailMove(VRCRail* rail, uint32_t id, int32_t x, int32_t y, uint32_t width, uint32_t height);

/* The rail of the session whose engine context this is: session.c knows the layout of the session */
VRCRail* vrcSessionRail(rdpContext* context);

#endif
