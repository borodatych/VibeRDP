/*
 * RemoteApp tests: core/src/rail.c against window orders built by hand, as the engine hands them over
 * Usage: railTests <test name>; CTest registers every test separately
 */

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "rail.h"

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

/* What the app heard */
static VRCRailWindow lastWindow;
static char lastTitle[64];
static int windows;
static int icons;
static uint8_t lastIconPixel[4];
static uint32_t lastIconWindow;
static int states;
static VRCRailState lastState;
static uint32_t lastActive;
static uint32_t lastOrder[4];
static size_t lastOrderCount;
static bool lastHasOrder;

static void onWindow(void* userData, const VRCRailWindow* window)
{
    (void)userData;
    windows++;
    lastWindow = *window;
    snprintf(lastTitle, sizeof(lastTitle), "%s", window->title ? window->title : "");
}

static void onIcon(void* userData, uint32_t id, const uint8_t* pixels, uint32_t width, uint32_t height)
{
    (void)userData;
    (void)width;
    (void)height;
    icons++;
    lastIconWindow = id;
    memcpy(lastIconPixel, pixels, 4);
}

static void onState(void* userData, VRCRailState state, uint32_t code)
{
    (void)userData;
    (void)code;
    states++;
    lastState = state;
}

static void onDesktop(void* userData, uint32_t active, bool hasActive, const uint32_t* order, size_t count,
                      bool hasOrder)
{
    (void)userData;
    lastActive = hasActive ? active : 0;
    lastHasOrder = hasOrder;
    lastOrderCount = count;
    for (size_t i = 0; i < count && i < 4; i++)
        lastOrder[i] = order[i];
}

/* The session side, which these tests do not have */
VRCRail* vrcSessionRail(rdpContext* context)
{
    (void)context;
    return NULL;
}

static const VRCCallbacks callbacks = {
    .railState = onState,
    .railWindow = onWindow,
    .railIcon = onIcon,
    .railDesktop = onDesktop,
};
static void* userData;

static void setUp(VRCRail* rail)
{
    windows = icons = states = 0;
    lastOrderCount = 0;
    vrcRailInit(rail, &callbacks, &userData);
}

static bool testNewWindowCarriesItsFields(void)
{
    VRCRail rail;
    setUp(&rail);
    WCHAR title[] = { 'N', 'o', 't', 'e', 'p', 'a', 'd' };
    RECTANGLE_16 visible[] = { { 8, 0, 208, 100 }, { 8, 100, 108, 150 } };
    const WINDOW_ORDER_INFO info = {
        .windowId = 0x1234,
        .fieldFlags = WINDOW_ORDER_TYPE_WINDOW | WINDOW_ORDER_STATE_NEW | WINDOW_ORDER_FIELD_TITLE |
                      WINDOW_ORDER_FIELD_SHOW | WINDOW_ORDER_FIELD_WND_OFFSET | WINDOW_ORDER_FIELD_WND_SIZE |
                      WINDOW_ORDER_FIELD_VIS_OFFSET | WINDOW_ORDER_FIELD_VISIBILITY,
    };
    const WINDOW_STATE_ORDER state = {
        .titleInfo = { .length = sizeof(title), .string = title },
        .showState = 5,
        .windowOffsetX = -8,
        .windowOffsetY = 40,
        .windowWidth = 216,
        .windowHeight = 158,
        .visibleOffsetX = -8,
        .visibleOffsetY = 40,
        .numVisibilityRects = 2,
        .visibilityRects = visible,
    };
    vrcRailWindowOrder(&rail, &info, &state);
    CHECK(windows == 1 && lastWindow.id == 0x1234 && lastWindow.created);
    CHECK(strcmp(lastTitle, "Notepad") == 0);
    CHECK(lastWindow.showState == 5 && lastWindow.x == -8 && lastWindow.y == 40);
    CHECK(lastWindow.width == 216 && lastWindow.height == 158);
    CHECK((lastWindow.fields & VRCRailFieldOwner) == 0);
    CHECK(lastWindow.regionX == 8 && lastWindow.regionY == 0);
    CHECK(lastWindow.regionWidth == 200 && lastWindow.regionHeight == 150);
    vrcRailDestroy(&rail);
    return true;
}

static bool testUpdateCarriesOnlyItsFields(void)
{
    VRCRail rail;
    setUp(&rail);
    const WINDOW_ORDER_INFO info = {
        .windowId = 7, .fieldFlags = WINDOW_ORDER_TYPE_WINDOW | WINDOW_ORDER_FIELD_WND_OFFSET
    };
    const WINDOW_STATE_ORDER state = { .windowOffsetX = 300, .windowOffsetY = 200 };
    vrcRailWindowOrder(&rail, &info, &state);
    CHECK(!lastWindow.created && lastWindow.fields == VRCRailFieldOffset);
    CHECK(lastWindow.x == 300 && lastWindow.y == 200);
    vrcRailDestroy(&rail);
    return true;
}

static bool testCachedIconComesBack(void)
{
    VRCRail rail;
    setUp(&rail);
    /* 2 by 2 at 32 bits, bottom-up as the protocol has them, and an AND mask of 4 bytes a row */
    BYTE color[16] = { 1, 2, 3, 255, 1, 2, 3, 255, 9, 8, 7, 255, 9, 8, 7, 255 };
    BYTE mask[8] = { 0 };
    ICON_INFO icon = {
        .cacheEntry = 3, .cacheId = 1, .bpp = 32, .width = 2, .height = 2,
        .cbBitsMask = sizeof(mask), .cbBitsColor = sizeof(color), .bitsMask = mask, .bitsColor = color,
    };
    const WINDOW_ORDER_INFO info = { .windowId = 5, .fieldFlags = WINDOW_ORDER_TYPE_WINDOW | WINDOW_ORDER_ICON };
    vrcRailWindowIcon(&rail, &info, &icon);
    CHECK(icons == 1 && lastIconWindow == 5);
    const uint8_t first[4] = { lastIconPixel[0], lastIconPixel[1], lastIconPixel[2], lastIconPixel[3] };
    const WINDOW_ORDER_INFO other = {
        .windowId = 6, .fieldFlags = WINDOW_ORDER_TYPE_WINDOW | WINDOW_ORDER_CACHED_ICON
    };
    const CACHED_ICON_INFO cached = { .cacheEntry = 3, .cacheId = 1 };
    vrcRailWindowCachedIcon(&rail, &other, &cached);
    CHECK(icons == 2 && lastIconWindow == 6 && memcmp(first, lastIconPixel, 4) == 0);
    const CACHED_ICON_INFO missing = { .cacheEntry = 4, .cacheId = 1 };
    vrcRailWindowCachedIcon(&rail, &other, &missing);
    CHECK(icons == 2);
    vrcRailDestroy(&rail);
    return true;
}

static bool testDesktopOrderAndFocus(void)
{
    VRCRail rail;
    setUp(&rail);
    UINT32 ids[] = { 9, 5, 7 };
    const WINDOW_ORDER_INFO info = {
        .fieldFlags =
            WINDOW_ORDER_TYPE_DESKTOP | WINDOW_ORDER_FIELD_DESKTOP_ACTIVE_WND | WINDOW_ORDER_FIELD_DESKTOP_ZORDER
    };
    const MONITORED_DESKTOP_ORDER desktop = { .activeWindowId = 5, .numWindowIds = 3, .windowIds = ids };
    vrcRailDesktop(&rail, &info, &desktop);
    CHECK(lastActive == 5 && lastHasOrder && lastOrderCount == 3 && lastOrder[0] == 9 && lastOrder[2] == 7);
    vrcRailDestroy(&rail);
    return true;
}

static bool testRefusalsReachTheApp(void)
{
    VRCRail rail;
    setUp(&rail);
    const RAIL_EXEC_RESULT_ORDER ok = { .execResult = RAIL_EXEC_S_OK };
    vrcRailExecuteResult(&rail, &ok);
    CHECK(states == 0);
    const RAIL_EXEC_RESULT_ORDER refused = { .execResult = RAIL_EXEC_E_NOT_IN_ALLOWLIST };
    vrcRailExecuteResult(&rail, &refused);
    CHECK(states == 1 && lastState == VRCRailStateRefused);
    /* The program starts only once the server sent its windows, and without a channel it cannot */
    const WINDOW_ORDER_INFO arc = {
        .fieldFlags = WINDOW_ORDER_TYPE_DESKTOP | WINDOW_ORDER_FIELD_DESKTOP_ARC_COMPLETED
    };
    vrcRailDesktop(&rail, &arc, NULL);
    CHECK(states == 2 && lastState == VRCRailStateRefused);
    vrcRailDestroy(&rail);
    return true;
}

static bool testCommandsWaitForTheProgram(void)
{
    VRCRail rail;
    setUp(&rail);
    CHECK(vrcRailActivate(&rail, 5) == VRCResultInvalidState);
    CHECK(vrcRailSystemCommand(&rail, 5, VRCRailCommandClose) == VRCResultInvalidState);
    CHECK(vrcRailSystemCommand(&rail, 5, (VRCRailCommand)99) == VRCResultInvalidArgument);
    CHECK(vrcRailMove(&rail, 5, 0, 0, 100, 100) == VRCResultInvalidState);
    CHECK(vrcRailMove(&rail, 5, 32000, 0, 1000, 100) == VRCResultInvalidArgument);
    vrcRailDestroy(&rail);
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "newWindowCarriesItsFields", testNewWindowCarriesItsFields },
    { "updateCarriesOnlyItsFields", testUpdateCarriesOnlyItsFields },
    { "cachedIconComesBack", testCachedIconComesBack },
    { "desktopOrderAndFocus", testDesktopOrderAndFocus },
    { "refusalsReachTheApp", testRefusalsReachTheApp },
    { "commandsWaitForTheProgram", testCommandsWaitForTheProgram },
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
