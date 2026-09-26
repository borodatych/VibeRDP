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
    /* The size asked for last and the size last sent, 0 by 0 for none */
    uint32_t wantedWidth;
    uint32_t wantedHeight;
    uint32_t sentWidth;
    uint32_t sentHeight;
} VRCDisplay;

void vrcDisplayInit(VRCDisplay* display);
void vrcDisplayDestroy(VRCDisplay* display);

/* The channel came up or went down; the size the desktop has now counts as sent, so asking for it sends nothing */
void vrcDisplayAttach(VRCDisplay* display, DispClientContext* channel, uint32_t width, uint32_t height);
void vrcDisplayDetach(VRCDisplay* display, DispClientContext* channel);

/* Asks for a desktop of this size: sent at once when the server is ready and the size is new, else kept for later */
void vrcDisplayRequest(VRCDisplay* display, uint32_t width, uint32_t height);

/*
 * The layout of one monitor of this size as the server takes it: the width even, both within the limits of the
 * protocol, the monitor primary, the scale 100 percent
 */
DISPLAY_CONTROL_MONITOR_LAYOUT vrcDisplayLayout(uint32_t width, uint32_t height);

#endif
