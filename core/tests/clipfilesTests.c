/*
 * Clipboard file tests: lists of files against FileGroupDescriptorW, built from core/src/clipfiles.c directly
 * The files of the Mac live in a fresh temporary folder; the lists of Windows are written byte by byte
 * Usage: clipfilesTests <test name>; CTest registers every test separately
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "clipfiles.h"
#include "fileTrees.h"

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

/* Offsets of FILEDESCRIPTORW, as Windows lays it out */
#define FLAGS_OFFSET 0
#define ATTRIBUTES_OFFSET 36
#define WRITE_TIME_OFFSET 56
#define SIZE_LOW_OFFSET 68
#define NAME_OFFSET 72

#define FD_ATTRIBUTES 0x04u
#define FD_WRITESTIME 0x20u
#define FD_FILESIZE 0x40u
#define DIRECTORY_ATTRIBUTE 0x10u

static void writeLE32(uint8_t* bytes, uint32_t value)
{
    for (int i = 0; i < 4; i++)
        bytes[i] = (uint8_t)(value >> (8 * i));
}

/* The item of a list with this name, NULL when there is none */
static const VRCRemoteFile* findItem(const VRCRemoteFiles* files, const char* name, size_t* index)
{
    for (size_t i = 0; i < files->count; i++)
        if (strcmp(files->items[i].name, name) == 0)
        {
            if (index)
                *index = i;
            return &files->items[i];
        }
    return NULL;
}

/* A copied folder and a file beside it: the list holds the tree with names from the folder that holds them */
static bool testLocalListOfATree(void)
{
    char root[FILE_TREE_PATH];
    CHECK(fileTreeMake(root));
    CHECK(fileTreeWrite(root, "Папка/a.txt", "hello"));
    CHECK(fileTreeWrite(root, "Папка/sub/b.bin", "xyz"));
    CHECK(fileTreeWrite(root, "Папка/.DS_Store", "finder"));
    CHECK(fileTreeWrite(root, "c.txt", ""));
    CHECK(fileTreeSetTime(root, "c.txt", 1700000000));
    char link[FILE_TREE_PATH];
    snprintf(link, sizeof(link), "%s/Папка/link", root);
    CHECK(symlink("a.txt", link) == 0);

    char paths[2 * FILE_TREE_PATH];
    const int first = snprintf(paths, sizeof(paths), "%s/Папка/", root) + 1;
    const int second = snprintf(paths + first, sizeof(paths) - (size_t)first, "%s/c.txt", root) + 1;
    VRCLocalFiles* local = vrcLocalFilesCreate(paths, (size_t)(first + second));
    CHECK(local != NULL);
    CHECK(local->count == 5);

    /* The list reads back as Windows sees it */
    VRCRemoteFiles* remote = vrcRemoteFilesParse(local->descriptor, local->descriptorLength);
    CHECK(remote != NULL);
    CHECK(remote->count == 5);
    size_t folder = 0;
    size_t inside = 0;
    const VRCRemoteFile* item = findItem(remote, "Папка", &folder);
    CHECK(item && item->directory);
    item = findItem(remote, "Папка/a.txt", &inside);
    CHECK(item && !item->directory && item->hasSize && item->size == 5);
    CHECK(folder < inside);
    item = findItem(remote, "Папка/sub", NULL);
    CHECK(item && item->directory);
    item = findItem(remote, "Папка/sub/b.bin", NULL);
    CHECK(item && item->size == 3);
    item = findItem(remote, "c.txt", NULL);
    CHECK(item && item->size == 0 && item->hasModified && item->modified.tv_sec == 1700000000);
    CHECK(findItem(remote, "Папка/.DS_Store", NULL) == NULL);
    CHECK(findItem(remote, "Папка/link", NULL) == NULL);

    char* top = NULL;
    size_t topLength = 0;
    CHECK(vrcRemoteFilesTopLevel(remote, &top, &topLength));
    CHECK(topLength == strlen("Папка") + 1 + strlen("c.txt") + 1);
    /* The order of the copied items is the one of the paths */
    CHECK(strcmp(top, "Папка") == 0);
    CHECK(strcmp(top + strlen("Папка") + 1, "c.txt") == 0);
    free(top);

    /* The contents come by range, a folder has none */
    uint8_t data[8];
    uint32_t read = 0;
    const uint32_t file = (uint32_t)inside;
    CHECK(vrcLocalFilesRead(local, file, 1, 3, data, &read) && read == 3 && memcmp(data, "ell", 3) == 0);
    CHECK(vrcLocalFilesRead(local, file, 3, 8, data, &read) && read == 2 && memcmp(data, "lo", 2) == 0);
    CHECK(vrcLocalFilesRead(local, file, 5, 8, data, &read) && read == 0);
    CHECK(!vrcLocalFilesRead(local, (uint32_t)folder, 0, 8, data, &read));
    CHECK(!vrcLocalFilesRead(local, 5, 0, 8, data, &read));

    vrcRemoteFilesFree(remote);
    vrcLocalFilesFree(local);
    CHECK(fileTreeRemove(root));
    return true;
}

/* Names go to Windows composed: a decomposed é of the Mac arrives as one character */
static bool testNamesGoComposed(void)
{
    char root[FILE_TREE_PATH];
    CHECK(fileTreeMake(root));
    CHECK(fileTreeWrite(root, "e\xCC\x81.txt", "1"));
    char path[FILE_TREE_PATH];
    const int length = snprintf(path, sizeof(path), "%s/e\xCC\x81.txt", root) + 1;

    VRCLocalFiles* local = vrcLocalFilesCreate(path, (size_t)length);
    CHECK(local != NULL);
    CHECK(local->descriptor[4 + NAME_OFFSET] == 0xE9 && local->descriptor[4 + NAME_OFFSET + 1] == 0);
    CHECK(local->descriptor[4 + NAME_OFFSET + 2] == '.');
    vrcLocalFilesFree(local);
    CHECK(fileTreeRemove(root));
    return true;
}

/* Lists that cannot be built are refused whole */
static bool testBrokenLocalLists(void)
{
    char root[FILE_TREE_PATH];
    CHECK(fileTreeMake(root));
    CHECK(vrcLocalFilesCreate("relative\0", 9) == NULL);
    CHECK(vrcLocalFilesCreate("/", 2) == NULL);

    char path[FILE_TREE_PATH];
    int length = snprintf(path, sizeof(path), "%s/missing", root) + 1;
    CHECK(vrcLocalFilesCreate(path, (size_t)length) == NULL);
    /* Without the zero at its end the last path could run past the data */
    CHECK(vrcLocalFilesCreate(path, (size_t)length - 1) == NULL);

    /* A name longer than the 259 characters Windows takes */
    char deep[FILE_TREE_PATH];
    char name[201];
    memset(name, 'd', sizeof(name) - 1);
    name[sizeof(name) - 1] = '\0';
    snprintf(deep, sizeof(deep), "%s/%.100s", name, name);
    CHECK(fileTreeWrite(root, deep, "x"));
    length = snprintf(path, sizeof(path), "%s/%s", root, name) + 1;
    CHECK(vrcLocalFilesCreate(path, (size_t)length) == NULL);

    CHECK(fileTreeRemove(root));
    return true;
}

/* A list of Windows with one item of this name, attributes and size */
static uint8_t* remoteList(const char* name, uint32_t flags, uint32_t attributes, uint32_t size, size_t* length)
{
    *length = 4 + VRC_FILE_DESCRIPTOR_SIZE;
    uint8_t* list = calloc(1, *length);
    writeLE32(list, 1);
    uint8_t* item = list + 4;
    writeLE32(item + FLAGS_OFFSET, flags);
    writeLE32(item + ATTRIBUTES_OFFSET, attributes);
    writeLE32(item + SIZE_LOW_OFFSET, size);
    for (size_t i = 0; name[i]; i++)
        item[NAME_OFFSET + 2 * i] = (uint8_t)name[i];
    return list;
}

/* Names of the server that would leave the folder of the copy are refused, the list with them */
static bool testRemoteNamesAreChecked(void)
{
    static const char* const unsafe[] = { "..\\evil", "a\\..\\b", "\\abs", "a\\\\b", "a\\", ".", "" };
    for (size_t i = 0; i < sizeof(unsafe) / sizeof(unsafe[0]); i++)
    {
        size_t length = 0;
        uint8_t* list = remoteList(unsafe[i], 0, 0, 0, &length);
        VRCRemoteFiles* files = vrcRemoteFilesParse(list, length);
        free(list);
        if (files)
            fprintf(stderr, "accepted: %s\n", unsafe[i]);
        CHECK(files == NULL);
    }

    size_t length = 0;
    uint8_t* list = remoteList("ok\\name.txt", FD_FILESIZE | FD_ATTRIBUTES, 0, 42, &length);
    VRCRemoteFiles* files = vrcRemoteFilesParse(list, length);
    CHECK(files && files->count == 1);
    CHECK(strcmp(files->items[0].name, "ok/name.txt") == 0);
    CHECK(files->items[0].hasSize && files->items[0].size == 42 && !files->items[0].directory);
    CHECK(!files->items[0].hasModified);
    vrcRemoteFilesFree(files);

    /* A name without its zero, a count past the data */
    memset(list + 4 + NAME_OFFSET, 'a', 2 * 260);
    CHECK(vrcRemoteFilesParse(list, length) == NULL);
    writeLE32(list, 2);
    CHECK(vrcRemoteFilesParse(list, length) == NULL);
    CHECK(vrcRemoteFilesParse(list, 3) == NULL);
    free(list);
    return true;
}

/* Folders, times, and names at the top when the list names a file inside a folder it does not list */
static bool testRemoteFoldersAndTimes(void)
{
    size_t length = 0;
    uint8_t* list = remoteList("dir", FD_ATTRIBUTES | FD_WRITESTIME, DIRECTORY_ATTRIBUTE, 0, &length);
    /* 2023-11-14 22:13:20 UTC, 1700000000 on the Mac */
    const uint64_t filetime = (1700000000ull + 11644473600ull) * 10000000ull + 5;
    writeLE32(list + 4 + WRITE_TIME_OFFSET, (uint32_t)filetime);
    writeLE32(list + 4 + WRITE_TIME_OFFSET + 4, (uint32_t)(filetime >> 32));
    VRCRemoteFiles* files = vrcRemoteFilesParse(list, length);
    free(list);
    CHECK(files && files->items[0].directory && files->items[0].hasModified);
    CHECK(files->items[0].modified.tv_sec == 1700000000 && files->items[0].modified.tv_nsec == 500);
    vrcRemoteFilesFree(files);

    list = remoteList("x\\y.txt", 0, 0, 0, &length);
    files = vrcRemoteFilesParse(list, length);
    free(list);
    CHECK(files != NULL);
    char* top = NULL;
    size_t topLength = 0;
    CHECK(vrcRemoteFilesTopLevel(files, &top, &topLength));
    CHECK(topLength == 2 && strcmp(top, "x") == 0);
    free(top);
    vrcRemoteFilesFree(files);
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "localListOfATree", testLocalListOfATree },
    { "namesGoComposed", testNamesGoComposed },
    { "brokenLocalLists", testBrokenLocalLists },
    { "remoteNamesAreChecked", testRemoteNamesAreChecked },
    { "remoteFoldersAndTimes", testRemoteFoldersAndTimes },
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
