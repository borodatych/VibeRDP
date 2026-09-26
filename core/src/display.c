/*
 * The desktop that follows the window, over the Display Control channel of the engine, see display.h
 */

#include "display.h"

#include <string.h>

#include <freerdp/settings.h>

/* The scale the layout asks for: the desktop is as large as the window in points, scaling it is task 3.2 */
#define DISPLAY_SCALE_PERCENT 100u

static uint32_t clamp(uint32_t value, uint32_t minimum, uint32_t maximum)
{
    return value < minimum ? minimum : value > maximum ? maximum : value;
}

DISPLAY_CONTROL_MONITOR_LAYOUT vrcDisplayLayout(uint32_t width, uint32_t height)
{
    /* The protocol takes only even widths: one pixel less keeps the desktop inside the window */
    const uint32_t evenWidth =
        clamp(width, DISPLAY_CONTROL_MIN_MONITOR_WIDTH, DISPLAY_CONTROL_MAX_MONITOR_WIDTH) & ~(uint32_t)1;
    const DISPLAY_CONTROL_MONITOR_LAYOUT layout = {
        .Flags = DISPLAY_CONTROL_MONITOR_PRIMARY,
        .Width = evenWidth,
        .Height = clamp(height, DISPLAY_CONTROL_MIN_MONITOR_HEIGHT, DISPLAY_CONTROL_MAX_MONITOR_HEIGHT),
        .Orientation = ORIENTATION_LANDSCAPE,
        .DesktopScaleFactor = DISPLAY_SCALE_PERCENT,
        .DeviceScaleFactor = DISPLAY_SCALE_PERCENT,
    };
    return layout;
}

/* The caller holds the mutex: the wanted size goes out when the server is ready and it differs from the last one */
static void sendWanted(VRCDisplay* display)
{
    if (!display->channel || !display->ready || display->wantedWidth == 0)
        return;
    DISPLAY_CONTROL_MONITOR_LAYOUT layout = vrcDisplayLayout(display->wantedWidth, display->wantedHeight);
    if (layout.Width == display->sentWidth && layout.Height == display->sentHeight)
        return;
    if (display->channel->SendMonitorLayout(display->channel, 1, &layout) == CHANNEL_RC_OK)
    {
        display->sentWidth = layout.Width;
        display->sentHeight = layout.Height;
    }
}

/* The server tells what it takes: from now on layouts go, the one asked for meanwhile first */
static UINT onCapabilities(DispClientContext* channel, UINT32 maxMonitors, UINT32 areaFactorA, UINT32 areaFactorB)
{
    (void)maxMonitors;
    (void)areaFactorA;
    (void)areaFactorB;
    VRCDisplay* display = channel->custom;

    pthread_mutex_lock(&display->mutex);
    display->ready = true;
    sendWanted(display);
    pthread_mutex_unlock(&display->mutex);
    return CHANNEL_RC_OK;
}

void vrcDisplayInit(VRCDisplay* display)
{
    memset(display, 0, sizeof(*display));
    display->mutex = (pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;
}

void vrcDisplayDestroy(VRCDisplay* display)
{
    pthread_mutex_destroy(&display->mutex);
}

void vrcDisplayAttach(VRCDisplay* display, DispClientContext* channel, uint32_t width, uint32_t height)
{
    pthread_mutex_lock(&display->mutex);
    channel->custom = display;
    channel->DisplayControlCaps = onCapabilities;
    display->channel = channel;
    display->ready = false;
    display->sentWidth = width;
    display->sentHeight = height;
    pthread_mutex_unlock(&display->mutex);
}

void vrcDisplayDetach(VRCDisplay* display, DispClientContext* channel)
{
    pthread_mutex_lock(&display->mutex);
    if (display->channel == channel)
    {
        channel->custom = NULL;
        display->channel = NULL;
        display->ready = false;
    }
    pthread_mutex_unlock(&display->mutex);
}

void vrcDisplayRequest(VRCDisplay* display, uint32_t width, uint32_t height)
{
    pthread_mutex_lock(&display->mutex);
    display->wantedWidth = width;
    display->wantedHeight = height;
    sendWanted(display);
    pthread_mutex_unlock(&display->mutex);
}
