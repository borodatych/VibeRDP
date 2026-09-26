/*
 * The diagnostics log over WLog of WinPR: the engine logs through it already, the app joins under its own tags
 * One writer for the whole file keeps the lines of both whole and in order
 */

#include "VibeRDPCore/VibeRDPCore.h"

#include <libgen.h>
#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include <winpr/wlog.h>

/* The tags of the app: the engine logs under com.freerdp and com.winpr, so the app is told apart at a glance */
#define APP_TAG_PREFIX "com.vibebrains.viberdp."
#define TAG_SIZE 96

/*
 * Parts of the engine the log keeps in full, at DEBUG, whatever the level of the rest
 * The clipboard and device channels: what Windows does with the lists of the Mac and with a shared folder
 * shows only in their messages, and a Windows machine is not at hand to repeat a case
 */
static const char* const tracedTags[] = { "com.freerdp.channels.cliprdr.client",
                                           "com.freerdp.channels.rdpdr.client" };

/* Set once a file receives the log: before that, lines of the app go nowhere */
static pthread_mutex_t logMutex = PTHREAD_MUTEX_INITIALIZER;
static bool logging;

static DWORD wlogLevel(VRCLogLevel level)
{
    switch (level)
    {
        case VRCLogLevelDebug:
            return WLOG_DEBUG;
        case VRCLogLevelInfo:
            return WLOG_INFO;
        case VRCLogLevelWarning:
            return WLOG_WARN;
        case VRCLogLevelError:
            return WLOG_ERROR;
        default:
            return WLOG_OFF;
    }
}

VRCResult VRCLogToFile(const char* path, VRCLogLevel level)
{
    const DWORD wlog = wlogLevel(level);
    if (!path || wlog == WLOG_OFF || strlen(path) >= PATH_MAX)
        return VRCResultInvalidArgument;

    /* dirname and basename may change what they are given */
    char folder[PATH_MAX];
    char name[PATH_MAX];
    (void)strcpy(folder, path);
    (void)strcpy(name, path);

    pthread_mutex_lock(&logMutex);
    wLog* root = WLog_GetRoot();
    wLogAppender* appender = NULL;
    const bool opened = root && WLog_SetLogAppenderType(root, WLOG_APPENDER_FILE) &&
                        (appender = WLog_GetLogAppender(root)) != NULL &&
                        WLog_ConfigureAppender(appender, "outputfilepath", dirname(folder)) &&
                        WLog_ConfigureAppender(appender, "outputfilename", basename(name)) &&
                        WLog_OpenAppender(root) && WLog_SetLogLevel(root, wlog);
    for (size_t i = 0; opened && i < sizeof(tracedTags) / sizeof(tracedTags[0]); i++)
        (void)WLog_SetLogLevel(WLog_Get(tracedTags[i]), WLOG_DEBUG);
    logging = opened;
    pthread_mutex_unlock(&logMutex);
    return opened ? VRCResultOK : VRCResultFailure;
}

void VRCLog(VRCLogLevel level, const char* category, const char* message)
{
    const DWORD wlog = wlogLevel(level);
    if (wlog == WLOG_OFF || !message)
        return;

    pthread_mutex_lock(&logMutex);
    const bool active = logging;
    pthread_mutex_unlock(&logMutex);
    if (!active)
        return;

    char tag[TAG_SIZE];
    (void)snprintf(tag, sizeof(tag), APP_TAG_PREFIX "%s", category && *category ? category : "app");
    wLog* log = WLog_Get(tag);
    if (log && WLog_IsLevelActive(log, wlog))
        (void)WLog_PrintTextMessage(log, wlog, __LINE__, __FILE__, __func__, "%s", message);
}
