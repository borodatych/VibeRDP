/*
 * Display Control tests: core/src/display.c against a stand-in for the channel of the engine
 * Usage: displayTests <test name>; CTest registers every test separately
 */

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "display.h"

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

/* What the core sent on the channel */
static DispClientContext channel;
static int layouts;
static UINT32 lastCount;
static DISPLAY_CONTROL_MONITOR_LAYOUT last;

static UINT sentLayout(DispClientContext* context, UINT32 count, DISPLAY_CONTROL_MONITOR_LAYOUT* monitors)
{
    (void)context;
    layouts++;
    lastCount = count;
    last = monitors[0];
    return CHANNEL_RC_OK;
}

static void setUp(VRCDisplay* display)
{
    memset(&channel, 0, sizeof(channel));
    channel.SendMonitorLayout = sentLayout;
    layouts = 0;
    vrcDisplayInit(display);
    vrcDisplayAttach(display, &channel, 1024, 640, 100);
}

/* The width goes even, both stay within the protocol, the one monitor is primary at 100 percent */
static bool testLayoutLimits(void)
{
    DISPLAY_CONTROL_MONITOR_LAYOUT layout = vrcDisplayLayout(1921, 1199, 100);
    CHECK(layout.Width == 1920 && layout.Height == 1199);
    CHECK(layout.Flags == DISPLAY_CONTROL_MONITOR_PRIMARY);
    CHECK(layout.Left == 0 && layout.Top == 0);
    CHECK(layout.DesktopScaleFactor == 100 && layout.DeviceScaleFactor == 100);
    layout = vrcDisplayLayout(50, 10, 100);
    CHECK(layout.Width == DISPLAY_CONTROL_MIN_MONITOR_WIDTH && layout.Height == DISPLAY_CONTROL_MIN_MONITOR_HEIGHT);
    layout = vrcDisplayLayout(20000, 9000, 100);
    CHECK(layout.Width == DISPLAY_CONTROL_MAX_MONITOR_WIDTH && layout.Height == DISPLAY_CONTROL_MAX_MONITOR_HEIGHT);
    return true;
}

/* A size asked for before the capabilities waits for them, then goes once */
static bool testWaitsForCapabilities(void)
{
    VRCDisplay display;
    setUp(&display);
    vrcDisplayRequest(&display, 1920, 1200, 100);
    CHECK(layouts == 0);
    CHECK(channel.DisplayControlCaps(&channel, 16, 8192, 8192) == CHANNEL_RC_OK);
    CHECK(layouts == 1 && lastCount == 1);
    CHECK(last.Width == 1920 && last.Height == 1200);
    vrcDisplayDestroy(&display);
    return true;
}

/* Only a new size goes out: the one the desktop has and the one sent last stay home */
static bool testOnlyNewSizesGo(void)
{
    VRCDisplay display;
    setUp(&display);
    CHECK(channel.DisplayControlCaps(&channel, 16, 8192, 8192) == CHANNEL_RC_OK);
    CHECK(layouts == 0);
    vrcDisplayRequest(&display, 1024, 640, 100);
    CHECK(layouts == 0);
    vrcDisplayRequest(&display, 1281, 800, 100);
    vrcDisplayRequest(&display, 1280, 800, 100);
    CHECK(layouts == 1 && last.Width == 1280);
    vrcDisplayRequest(&display, 1440, 900, 100);
    CHECK(layouts == 2 && last.Height == 900);
    vrcDisplayDestroy(&display);
    return true;
}

/* Without the channel nothing goes, and a new channel starts over, waiting for its capabilities */
static bool testDetachStopsLayouts(void)
{
    VRCDisplay display;
    setUp(&display);
    CHECK(channel.DisplayControlCaps(&channel, 16, 8192, 8192) == CHANNEL_RC_OK);
    vrcDisplayDetach(&display, &channel);
    vrcDisplayRequest(&display, 1920, 1200, 100);
    CHECK(layouts == 0);
    vrcDisplayAttach(&display, &channel, 1024, 640, 100);
    CHECK(layouts == 0);
    CHECK(channel.DisplayControlCaps(&channel, 16, 8192, 8192) == CHANNEL_RC_OK);
    CHECK(layouts == 1 && last.Width == 1920);
    vrcDisplayDestroy(&display);
    return true;
}

/* The scale of a Retina display goes as 200 percent with the device at 180, and the scales stay within the protocol */
static bool testScales(void)
{
    DISPLAY_CONTROL_MONITOR_LAYOUT layout = vrcDisplayLayout(3008, 1942, 200);
    CHECK(layout.DesktopScaleFactor == 200 && layout.DeviceScaleFactor == 180);
    layout = vrcDisplayLayout(1920, 1200, 0);
    CHECK(layout.DesktopScaleFactor == 100 && layout.DeviceScaleFactor == 100);
    CHECK(vrcDisplayDesktopScale(50) == 100 && vrcDisplayDesktopScale(900) == 500);
    CHECK(vrcDisplayDeviceScale(125) == 100 && vrcDisplayDeviceScale(150) == 140 && vrcDisplayDeviceScale(300) == 180);
    return true;
}

/* A new scale at the same size goes out: the window moved to a display of another density */
static bool testNewScaleGoes(void)
{
    VRCDisplay display;
    setUp(&display);
    CHECK(channel.DisplayControlCaps(&channel, 16, 8192, 8192) == CHANNEL_RC_OK);
    vrcDisplayRequest(&display, 1024, 640, 100);
    CHECK(layouts == 0);
    vrcDisplayRequest(&display, 1024, 640, 200);
    CHECK(layouts == 1 && last.DesktopScaleFactor == 200 && last.DeviceScaleFactor == 180);
    vrcDisplayRequest(&display, 1024, 640, 200);
    CHECK(layouts == 1);
    vrcDisplayDestroy(&display);
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "layoutLimits", testLayoutLimits },
    { "waitsForCapabilities", testWaitsForCapabilities },
    { "onlyNewSizesGo", testOnlyNewSizesGo },
    { "detachStopsLayouts", testDetachStopsLayouts },
    { "scales", testScales },
    { "newScaleGoes", testNewScaleGoes },
};

int main(int argc, char* argv[])
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s <test name>\n", argv[0]);
        return 2;
    }
    for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); i++)
        if (strcmp(tests[i].name, argv[1]) == 0)
            return tests[i].run() ? 0 : 1;

    fprintf(stderr, "unknown test: %s\n", argv[1]);
    return 2;
}
