/*
 * Temporary folders of files for the file tests of the clipboard, see fileTrees.h
 */

#include "fileTrees.h"

#include <fts.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#define TREE_DIRECTORY_MODE 0755

bool fileTreeMake(char root[FILE_TREE_PATH])
{
    const char* temporary = getenv("TMPDIR");
    snprintf(root, FILE_TREE_PATH, "%s/viberdp-files-XXXXXX", temporary ? temporary : "/tmp");
    return mkdtemp(root) != NULL;
}

bool fileTreeWrite(const char* root, const char* name, const char* text)
{
    char path[FILE_TREE_PATH];
    if (snprintf(path, sizeof(path), "%s/%s", root, name) >= (int)sizeof(path))
        return false;
    for (char* slash = strchr(path + strlen(root) + 1, '/'); slash; slash = strchr(slash + 1, '/'))
    {
        *slash = '\0';
        (void)mkdir(path, TREE_DIRECTORY_MODE);
        *slash = '/';
    }
    FILE* file = fopen(path, "wb");
    if (!file)
        return false;
    const size_t length = strlen(text);
    const bool written = fwrite(text, 1, length, file) == length;
    return fclose(file) == 0 && written;
}

bool fileTreeSetTime(const char* root, const char* name, time_t modified)
{
    char path[FILE_TREE_PATH];
    snprintf(path, sizeof(path), "%s/%s", root, name);
    const struct timeval times[2] = { { .tv_sec = modified }, { .tv_sec = modified } };
    return utimes(path, times) == 0;
}

bool fileTreeHolds(const char* root, const char* name, const char* text)
{
    char path[FILE_TREE_PATH];
    snprintf(path, sizeof(path), "%s/%s", root, name);
    FILE* file = fopen(path, "rb");
    if (!file)
        return false;
    char contents[FILE_TREE_PATH];
    const size_t length = fread(contents, 1, sizeof(contents), file);
    fclose(file);
    return length == strlen(text) && memcmp(contents, text, length) == 0;
}

bool fileTreeRemove(const char* root)
{
    char* const roots[] = { (char*)root, NULL };
    FTS* walk = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (!walk)
        return false;
    bool ok = true;
    FTSENT* entry;
    while ((entry = fts_read(walk)) != NULL)
    {
        if (entry->fts_info == FTS_DP)
            ok = rmdir(entry->fts_path) == 0 && ok;
        else if (entry->fts_info != FTS_D)
            ok = unlink(entry->fts_path) == 0 && ok;
    }
    fts_close(walk);
    return ok;
}
