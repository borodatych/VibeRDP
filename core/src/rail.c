/*
 * RemoteApp: settings, window orders to the app, and commands of the app to the server
 */

#include "rail.h"

#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/codec/color.h>
#include <freerdp/rail.h>
#include <winpr/string.h>
#include <winpr/wlog.h>

#define TAG "com.vibebrains.viberdp.rail"

/* The window commands of RAIL are the SC_ values of Windows */
#define SYSTEM_COMMAND_MINIMIZE 0xF020
#define SYSTEM_COMMAND_MAXIMIZE 0xF030
#define SYSTEM_COMMAND_CLOSE 0xF060
#define SYSTEM_COMMAND_RESTORE 0xF120

_Static_assert(VRC_RAIL_ICON_SLOTS <= UINT16_MAX, "a slot count must fit the engine settings");

void vrcRailInit(VRCRail* rail, const VRCCallbacks* callbacks, void* const* userData)
{
    memset(rail, 0, sizeof(*rail));
    pthread_mutex_init(&rail->mutex, NULL);
    rail->callbacks = callbacks;
    rail->userData = userData;
}

void vrcRailDestroy(VRCRail* rail)
{
    for (size_t i = 0; i < rail->iconCount; i++)
        free(rail->icons[i].pixels);
    rail->iconCount = 0;
    pthread_mutex_destroy(&rail->mutex);
}

BOOL vrcRailApply(VRCRail* rail, rdpSettings* settings)
{
    rail->requested = true;
    /*
     * Without the graphics pipeline the server draws every window into the one desktop frame at its place,
     * which the windows of the app cut their parts from, as in the Seam mode; with it, each window would come
     * on a surface of its own
     */
    return freerdp_settings_set_bool(settings, FreeRDP_RemoteApplicationMode, TRUE) &&
           freerdp_settings_set_string(settings, FreeRDP_RemoteApplicationProgram, VRC_RAIL_PROGRAM) &&
           freerdp_settings_set_bool(settings, FreeRDP_RemoteAppLanguageBarSupported, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_Workarea, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_DisableWallpaper, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_DisableFullWindowDrag, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, FALSE);
}

static void reportState(VRCRail* rail, VRCRailState state, uint32_t code)
{
    if (rail->callbacks->railState)
        rail->callbacks->railState(*rail->userData, state, code);
}

void vrcRailConnected(VRCRail* rail, rdpSettings* settings)
{
    /* The engine takes the capability of the server over the request: false means a desktop session */
    if (rail->requested && !freerdp_settings_get_bool(settings, FreeRDP_RemoteApplicationMode))
    {
        WLog_WARN(TAG, "the server does not grant RemoteApp: the session is a desktop");
        reportState(rail, VRCRailStateRefused, 0);
    }
}

static char* titleOf(const RAIL_UNICODE_STRING* title)
{
    if (!title->string || title->length == 0)
        return _strdup("");
    return ConvertWCharNToUtf8Alloc(title->string, title->length / sizeof(WCHAR), NULL);
}

void vrcRailWindowOrder(VRCRail* rail, const WINDOW_ORDER_INFO* info, const WINDOW_STATE_ORDER* state)
{
    if (!rail->callbacks->railWindow)
        return;
    const uint32_t flags = info->fieldFlags;
    VRCRailWindow window = {
        .id = info->windowId,
        .created = (flags & WINDOW_ORDER_STATE_NEW) != 0,
    };
    char* title = NULL;
    if (flags & WINDOW_ORDER_FIELD_OWNER)
    {
        window.fields |= VRCRailFieldOwner;
        window.owner = state->ownerWindowId;
    }
    if (flags & WINDOW_ORDER_FIELD_STYLE)
    {
        window.fields |= VRCRailFieldStyle;
        window.style = state->style;
        window.extendedStyle = state->extendedStyle;
    }
    if (flags & WINDOW_ORDER_FIELD_SHOW)
    {
        window.fields |= VRCRailFieldShow;
        window.showState = state->showState;
    }
    if (flags & WINDOW_ORDER_FIELD_TITLE)
    {
        title = titleOf(&state->titleInfo);
        if (title)
        {
            window.fields |= VRCRailFieldTitle;
            window.title = title;
        }
    }
    if (flags & WINDOW_ORDER_FIELD_WND_OFFSET)
    {
        window.fields |= VRCRailFieldOffset;
        window.x = state->windowOffsetX;
        window.y = state->windowOffsetY;
    }
    if (flags & WINDOW_ORDER_FIELD_WND_SIZE)
    {
        window.fields |= VRCRailFieldSize;
        window.width = state->windowWidth;
        window.height = state->windowHeight;
    }
    if (flags & WINDOW_ORDER_FIELD_VIS_OFFSET)
    {
        window.fields |= VRCRailFieldVisibleOffset;
        window.visibleX = state->visibleOffsetX;
        window.visibleY = state->visibleOffsetY;
    }
    /* The visible region as the rectangle around its parts, relative to the visible offset */
    if ((flags & WINDOW_ORDER_FIELD_VISIBILITY) && state->numVisibilityRects > 0 && state->visibilityRects)
    {
        const RECTANGLE_16* rects = state->visibilityRects;
        uint16_t left = rects[0].left, top = rects[0].top, right = rects[0].right, bottom = rects[0].bottom;
        for (uint32_t i = 1; i < state->numVisibilityRects; i++)
        {
            left = rects[i].left < left ? rects[i].left : left;
            top = rects[i].top < top ? rects[i].top : top;
            right = rects[i].right > right ? rects[i].right : right;
            bottom = rects[i].bottom > bottom ? rects[i].bottom : bottom;
        }
        window.fields |= VRCRailFieldVisibleRegion;
        window.regionX = left;
        window.regionY = top;
        window.regionWidth = right > left ? (uint32_t)(right - left) : 0;
        window.regionHeight = bottom > top ? (uint32_t)(bottom - top) : 0;
    }
    rail->callbacks->railWindow(*rail->userData, &window);
    free(title);
}

void vrcRailWindowDeleted(VRCRail* rail, const WINDOW_ORDER_INFO* info)
{
    if (rail->callbacks->railWindowDeleted)
        rail->callbacks->railWindowDeleted(*rail->userData, info->windowId);
}

static VRCRailIcon* cachedIcon(VRCRail* rail, uint32_t key)
{
    for (size_t i = 0; i < rail->iconCount; i++)
        if (rail->icons[i].key == key)
            return &rail->icons[i];
    return NULL;
}

static void sendIcon(VRCRail* rail, uint32_t id, const VRCRailIcon* icon)
{
    if (rail->callbacks->railIcon && icon->pixels)
        rail->callbacks->railIcon(*rail->userData, id, icon->pixels, icon->width, icon->height);
}

void vrcRailWindowIcon(VRCRail* rail, const WINDOW_ORDER_INFO* info, const ICON_INFO* icon)
{
    if (!icon || icon->width == 0 || icon->height == 0 || icon->width > UINT16_MAX || icon->height > UINT16_MAX)
        return;
    VRCRailIcon converted = { .width = icon->width, .height = icon->height };
    converted.pixels = calloc((size_t)icon->width * icon->height, 4);
    if (!converted.pixels)
        return;
    if (!freerdp_image_copy_from_icon_data(converted.pixels, PIXEL_FORMAT_BGRA32, icon->width * 4, 0, 0,
                                           (UINT16)icon->width, (UINT16)icon->height, icon->bitsColor,
                                           (UINT16)icon->cbBitsColor, icon->bitsMask, (UINT16)icon->cbBitsMask,
                                           icon->colorTable, (UINT16)icon->cbColorTable, icon->bpp))
    {
        WLog_WARN(TAG, "icon of window 0x%08" PRIx32 " not converted", info->windowId);
        free(converted.pixels);
        return;
    }
    sendIcon(rail, info->windowId, &converted);

    /* An icon the server caches comes back later by its cache and entry alone */
    if (icon->cacheEntry == 0xFFFF)
    {
        free(converted.pixels);
        return;
    }
    converted.key = icon->cacheId << 16 | (icon->cacheEntry & 0xFFFF);
    VRCRailIcon* slot = cachedIcon(rail, converted.key);
    if (!slot && rail->iconCount < VRC_RAIL_ICON_SLOTS)
        slot = &rail->icons[rail->iconCount++];
    if (!slot)
    {
        free(converted.pixels);
        return;
    }
    free(slot->pixels);
    *slot = converted;
}

void vrcRailWindowCachedIcon(VRCRail* rail, const WINDOW_ORDER_INFO* info, const CACHED_ICON_INFO* cached)
{
    const VRCRailIcon* icon = cachedIcon(rail, cached->cacheId << 16 | (cached->cacheEntry & 0xFFFF));
    if (icon)
        sendIcon(rail, info->windowId, icon);
}

void vrcRailDesktop(VRCRail* rail, const WINDOW_ORDER_INFO* info, const MONITORED_DESKTOP_ORDER* desktop)
{
    const uint32_t flags = info->fieldFlags;
    /* The server has sent every window: the program goes now, as the reference clients start it */
    if ((flags & WINDOW_ORDER_FIELD_DESKTOP_ARC_COMPLETED) && !rail->started)
    {
        pthread_mutex_lock(&rail->mutex);
        const UINT rc = rail->channel ? client_rail_server_start_cmd(rail->channel) : ERROR_INVALID_STATE;
        pthread_mutex_unlock(&rail->mutex);
        rail->started = rc == CHANNEL_RC_OK;
        if (rail->started)
            reportState(rail, VRCRailStateStarted, 0);
        else
        {
            WLog_ERR(TAG, "RemoteApp not started: 0x%08" PRIX32, rc);
            reportState(rail, VRCRailStateRefused, rc);
        }
    }
    if (!rail->callbacks->railDesktop)
        return;
    const bool hasActive = (flags & WINDOW_ORDER_FIELD_DESKTOP_ACTIVE_WND) != 0;
    const bool hasOrder = (flags & WINDOW_ORDER_FIELD_DESKTOP_ZORDER) != 0 && desktop;
    if (hasActive || hasOrder)
        rail->callbacks->railDesktop(*rail->userData, hasActive && desktop ? desktop->activeWindowId : 0, hasActive,
                                     hasOrder ? desktop->windowIds : NULL, hasOrder ? desktop->numWindowIds : 0,
                                     hasOrder);
}

void vrcRailExecuteResult(VRCRail* rail, const RAIL_EXEC_RESULT_ORDER* result)
{
    if (result->execResult == RAIL_EXEC_S_OK)
        return;
    /* Most often the program is not in the allow list of the server: RemoteApp is refused for it */
    WLog_ERR(TAG, "RemoteApp program refused: result %" PRIu16 ", raw 0x%08" PRIX32, result->execResult,
             result->rawResult);
    rail->started = false;
    reportState(rail, VRCRailStateRefused, result->execResult);
}

/* The engine callbacks: each finds the rail of its session and hands over */

static BOOL onWindowCreate(rdpContext* context, const WINDOW_ORDER_INFO* info, const WINDOW_STATE_ORDER* state)
{
    vrcRailWindowOrder(vrcSessionRail(context), info, state);
    return TRUE;
}

static BOOL onWindowDelete(rdpContext* context, const WINDOW_ORDER_INFO* info)
{
    vrcRailWindowDeleted(vrcSessionRail(context), info);
    return TRUE;
}

static BOOL onWindowIcon(rdpContext* context, const WINDOW_ORDER_INFO* info, const WINDOW_ICON_ORDER* icon)
{
    vrcRailWindowIcon(vrcSessionRail(context), info, icon ? icon->iconInfo : NULL);
    return TRUE;
}

static BOOL onWindowCachedIcon(rdpContext* context, const WINDOW_ORDER_INFO* info,
                               const WINDOW_CACHED_ICON_ORDER* cached)
{
    vrcRailWindowCachedIcon(vrcSessionRail(context), info, &cached->cachedIcon);
    return TRUE;
}

static BOOL onMonitoredDesktop(rdpContext* context, const WINDOW_ORDER_INFO* info,
                               const MONITORED_DESKTOP_ORDER* desktop)
{
    vrcRailDesktop(vrcSessionRail(context), info, desktop);
    return TRUE;
}

static BOOL onNonMonitoredDesktop(rdpContext* context, const WINDOW_ORDER_INFO* info)
{
    vrcRailDesktop(vrcSessionRail(context), info, NULL);
    return TRUE;
}

static UINT onExecuteResult(RailClientContext* channel, const RAIL_EXEC_RESULT_ORDER* result)
{
    vrcRailExecuteResult((VRCRail*)channel->custom, result);
    return CHANNEL_RC_OK;
}

void vrcRailAttach(VRCRail* rail, RailClientContext* channel, rdpUpdate* update)
{
    pthread_mutex_lock(&rail->mutex);
    rail->channel = channel;
    pthread_mutex_unlock(&rail->mutex);
    channel->custom = rail;
    channel->ServerExecuteResult = onExecuteResult;
    rdpWindowUpdate* window = update->window;
    window->WindowCreate = onWindowCreate;
    window->WindowUpdate = onWindowCreate;
    window->WindowDelete = onWindowDelete;
    window->WindowIcon = onWindowIcon;
    window->WindowCachedIcon = onWindowCachedIcon;
    window->MonitoredDesktop = onMonitoredDesktop;
    window->NonMonitoredDesktop = onNonMonitoredDesktop;
}

void vrcRailDetach(VRCRail* rail, RailClientContext* channel)
{
    pthread_mutex_lock(&rail->mutex);
    if (rail->channel == channel)
        rail->channel = NULL;
    pthread_mutex_unlock(&rail->mutex);
    rail->started = false;
}

/* Commands: each goes while the channel is up and the program started, else InvalidState */

static VRCResult result(UINT rc)
{
    return rc == CHANNEL_RC_OK ? VRCResultOK : VRCResultFailure;
}

VRCResult vrcRailActivate(VRCRail* rail, uint32_t id)
{
    VRCResult outcome = VRCResultInvalidState;
    pthread_mutex_lock(&rail->mutex);
    if (rail->channel && rail->started)
    {
        const RAIL_ACTIVATE_ORDER order = { .windowId = id, .enabled = TRUE };
        outcome = result(rail->channel->ClientActivate(rail->channel, &order));
    }
    pthread_mutex_unlock(&rail->mutex);
    return outcome;
}

VRCResult vrcRailSystemCommand(VRCRail* rail, uint32_t id, VRCRailCommand command)
{
    uint16_t code = 0;
    switch (command)
    {
        case VRCRailCommandMinimize:
            code = SYSTEM_COMMAND_MINIMIZE;
            break;
        case VRCRailCommandMaximize:
            code = SYSTEM_COMMAND_MAXIMIZE;
            break;
        case VRCRailCommandRestore:
            code = SYSTEM_COMMAND_RESTORE;
            break;
        case VRCRailCommandClose:
            code = SYSTEM_COMMAND_CLOSE;
            break;
        default:
            return VRCResultInvalidArgument;
    }
    VRCResult outcome = VRCResultInvalidState;
    pthread_mutex_lock(&rail->mutex);
    if (rail->channel && rail->started)
    {
        const RAIL_SYSCOMMAND_ORDER order = { .windowId = id, .command = code };
        outcome = result(rail->channel->ClientSystemCommand(rail->channel, &order));
    }
    pthread_mutex_unlock(&rail->mutex);
    return outcome;
}

VRCResult vrcRailMove(VRCRail* rail, uint32_t id, int32_t x, int32_t y, uint32_t width, uint32_t height)
{
    /* The order carries 16-bit edges: a rectangle past them cannot be said */
    const int64_t right = (int64_t)x + width, bottom = (int64_t)y + height;
    if (x < INT16_MIN || y < INT16_MIN || right > INT16_MAX || bottom > INT16_MAX)
        return VRCResultInvalidArgument;
    VRCResult outcome = VRCResultInvalidState;
    pthread_mutex_lock(&rail->mutex);
    if (rail->channel && rail->started)
    {
        const RAIL_WINDOW_MOVE_ORDER order = {
            .windowId = id, .left = (INT16)x, .top = (INT16)y, .right = (INT16)right, .bottom = (INT16)bottom
        };
        outcome = result(rail->channel->ClientWindowMove(rail->channel, &order));
    }
    pthread_mutex_unlock(&rail->mutex);
    return outcome;
}
