/*
 * The desktop that follows the window, over the Display Control channel of the engine, see display.h
 */

#include "display.h"

#include <string.h>

#include <freerdp/settings.h>

/* The scale the layout asks for: the desktop is as large as the window in points, scaling it is task 3.2 */
/* The scales of the protocol, in percent: the desktop one within its limits, the device one of three values */
#define DESKTOP_SCALE_MIN 100u
#define DESKTOP_SCALE_MAX 500u
#define DEVICE_SCALE_SMALL 100u
#define DEVICE_SCALE_MEDIUM 140u
#define DEVICE_SCALE_LARGE 180u

static uint32_t clamp(uint32_t value, uint32_t minimum, uint32_t maximum)
{
    return value < minimum ? minimum : value > maximum ? maximum : value;
}

uint32_t vrcDisplayDesktopScale(uint32_t scale)
{
    return scale == 0 ? DESKTOP_SCALE_MIN : clamp(scale, DESKTOP_SCALE_MIN, DESKTOP_SCALE_MAX);
}

uint32_t vrcDisplayDeviceScale(uint32_t scale)
{
    /* The device scale nearest below the desktop one: 200 percent of a Retina display pairs with 180 */
    const uint32_t desktop = vrcDisplayDesktopScale(scale);
    return desktop < DEVICE_SCALE_MEDIUM ? DEVICE_SCALE_SMALL
           : desktop < DEVICE_SCALE_LARGE ? DEVICE_SCALE_MEDIUM
                                          : DEVICE_SCALE_LARGE;
}

DISPLAY_CONTROL_MONITOR_LAYOUT vrcDisplayLayout(uint32_t width, uint32_t height, uint32_t scale)
{
    /* The protocol takes only even widths: one pixel less keeps the desktop inside the window */
    const uint32_t evenWidth =
        clamp(width, DISPLAY_CONTROL_MIN_MONITOR_WIDTH, DISPLAY_CONTROL_MAX_MONITOR_WIDTH) & ~(uint32_t)1;
    const DISPLAY_CONTROL_MONITOR_LAYOUT layout = {
        .Flags = DISPLAY_CONTROL_MONITOR_PRIMARY,
        .Width = evenWidth,
        .Height = clamp(height, DISPLAY_CONTROL_MIN_MONITOR_HEIGHT, DISPLAY_CONTROL_MAX_MONITOR_HEIGHT),
        .Orientation = ORIENTATION_LANDSCAPE,
        .DesktopScaleFactor = vrcDisplayDesktopScale(scale),
        .DeviceScaleFactor = vrcDisplayDeviceScale(scale),
    };
    return layout;
}

/*
 * The caller holds the mutex: the wanted size and scale go out when the server is ready and either differs from
 * the last sent
 */
static void sendWanted(VRCDisplay* display)
{
    if (!display->channel || !display->ready || display->wantedWidth == 0)
        return;
    DISPLAY_CONTROL_MONITOR_LAYOUT layout =
        vrcDisplayLayout(display->wantedWidth, display->wantedHeight, display->wantedScale);
    if (layout.Width == display->sentWidth && layout.Height == display->sentHeight &&
        layout.DesktopScaleFactor == display->sentScale)
        return;
    if (display->channel->SendMonitorLayout(display->channel, 1, &layout) == CHANNEL_RC_OK)
    {
        display->sentWidth = layout.Width;
        display->sentHeight = layout.Height;
        display->sentScale = layout.DesktopScaleFactor;
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

void vrcDisplayAttach(VRCDisplay* display, DispClientContext* channel, uint32_t width, uint32_t height,
                      uint32_t scale)
{
    pthread_mutex_lock(&display->mutex);
    channel->custom = display;
    channel->DisplayControlCaps = onCapabilities;
    display->channel = channel;
    display->ready = false;
    display->sentWidth = width;
    display->sentHeight = height;
    display->sentScale = vrcDisplayDesktopScale(scale);
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

void vrcDisplayRequest(VRCDisplay* display, uint32_t width, uint32_t height, uint32_t scale)
{
    pthread_mutex_lock(&display->mutex);
    display->wantedWidth = width;
    display->wantedHeight = height;
    display->wantedScale = scale;
    sendWanted(display);
    pthread_mutex_unlock(&display->mutex);
}
