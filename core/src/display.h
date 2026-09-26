/*
 * The desktop that follows the window: the Display Control channel asks the server for a new desktop size,
 * and the server answers with a reset of the graphics, which the frame path handles already
 *
 * The server tells first what it takes, with the capabilities of the channel; a size asked for before that waits
 * Asks come on the session thread, the capabilities on the channel thread, so the state is under a mutex
 */

#ifndef VRC_DISPLAY_H
#define VRC_DISPLAY_H

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>

#include <freerdp/client/disp.h>

typedef struct VRCDisplay {
    pthread_mutex_t mutex;
    /* Set while the channel is up; the engine frees it after the channel goes down */
    DispClientContext* channel;
    /* The server sent its capabilities: layouts may go */
    bool ready;
    /* The size and scale asked for last and those last sent, 0 by 0 for none */
    uint32_t wantedWidth;
    uint32_t wantedHeight;
    uint32_t wantedScale;
    uint32_t sentWidth;
    uint32_t sentHeight;
    uint32_t sentScale;
} VRCDisplay;

void vrcDisplayInit(VRCDisplay* display);
void vrcDisplayDestroy(VRCDisplay* display);

/*
 * The channel came up or went down; the size and scale the desktop has now count as sent,
 * so asking for them sends nothing
 */
void vrcDisplayAttach(VRCDisplay* display, DispClientContext* channel, uint32_t width, uint32_t height,
                      uint32_t scale);
void vrcDisplayDetach(VRCDisplay* display, DispClientContext* channel);

/*
 * Asks for a desktop of this size and scale: sent at once when the server is ready and either is new,
 * else kept for later
 */
void vrcDisplayRequest(VRCDisplay* display, uint32_t width, uint32_t height, uint32_t scale);

/*
 * The layout of one monitor of this size and scale as the server takes it: the width even, both within the limits
 * of the protocol, the monitor primary, the scales as vrcDisplayDesktopScale and vrcDisplayDeviceScale give them
 */
DISPLAY_CONTROL_MONITOR_LAYOUT vrcDisplayLayout(uint32_t width, uint32_t height, uint32_t scale);

/* A scale of the desktop in percent within the limits of the protocol, 100 to 500; 0 is 100 */
uint32_t vrcDisplayDesktopScale(uint32_t scale);

/*
 * The scale of the device the protocol pairs with a desktop scale: it takes only 100, 140 and 180 percent,
 * and a desktop scale it does not pair with one of them it ignores
 */
uint32_t vrcDisplayDeviceScale(uint32_t scale);

#endif
