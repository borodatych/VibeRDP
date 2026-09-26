/*
 * Diagnostics log tests: VRCLogToFile and VRCLog through the framework, as the app calls them
 * Usage: logTests <test name>; CTest registers every test separately
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "VibeRDPCore/VibeRDPCore.h"

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

#define PATH_SIZE 1024
#define CONTENTS_SIZE 8192

static bool readFile(const char* path, char* contents)
{
    FILE* file = fopen(path, "rb");
    CHECK(file != NULL);
    const size_t length = fread(contents, 1, CONTENTS_SIZE - 1, file);
    contents[length] = '\0';
    fclose(file);
    return true;
}

/* Lines at or above the level land in the file under the tag of their category, the folder is made on the way */
static bool testLinesReachTheFile(void)
{
    char folder[PATH_SIZE];
    const char* temporary = getenv("TMPDIR");
    snprintf(folder, sizeof(folder), "%s/viberdp-log-XXXXXX", temporary ? temporary : "/tmp");
    CHECK(mkdtemp(folder) != NULL);
    char path[PATH_SIZE];
    snprintf(path, sizeof(path), "%s/logs/session.log", folder);

    VRCLog(VRCLogLevelError, "test", "before the log");
    CHECK(VRCLogToFile(path, VRCLogLevelInfo) == VRCResultOK);
    VRCLog(VRCLogLevelInfo, "frame", "surface 1024x640");
    VRCLog(VRCLogLevelDebug, "frame", "below the level");
    VRCLog(VRCLogLevelWarning, NULL, "no category");

    char contents[CONTENTS_SIZE];
    CHECK(readFile(path, contents));
    CHECK(strstr(contents, "com.vibebrains.viberdp.frame") != NULL);
    CHECK(strstr(contents, "surface 1024x640") != NULL);
    CHECK(strstr(contents, "com.vibebrains.viberdp.app") != NULL);
    CHECK(strstr(contents, "below the level") == NULL);
    CHECK(strstr(contents, "before the log") == NULL);

    char logs[PATH_SIZE];
    snprintf(logs, sizeof(logs), "%s/logs", folder);
    CHECK(unlink(path) == 0 && rmdir(logs) == 0 && rmdir(folder) == 0);
    return true;
}

static bool testRefusals(void)
{
    CHECK(VRCLogToFile(NULL, VRCLogLevelInfo) == VRCResultInvalidArgument);
    CHECK(VRCLogToFile("/tmp/viberdp.log", (VRCLogLevel)9) == VRCResultInvalidArgument);
    CHECK(VRCLogToFile("/dev/null/viberdp.log", VRCLogLevelInfo) == VRCResultFailure);
    return true;
}

int main(int argc, char* argv[])
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s <test name>\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "linesReachTheFile") == 0)
        return testLinesReachTheFile() ? 0 : 1;
    if (strcmp(argv[1], "logRefusals") == 0)
        return testRefusals() ? 0 : 1;
    fprintf(stderr, "unknown test: %s\n", argv[1]);
    return 2;
}
