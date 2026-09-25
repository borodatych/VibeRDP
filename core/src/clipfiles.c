/*
 * Files of the clipboard: FileGroupDescriptorW both ways, and the files of the Mac read by range
 * Names go through CoreFoundation: UTF-8 of the Mac against UTF-16 of Windows, in the composed form Windows expects
 */

#include "clipfiles.h"

#include <fcntl.h>
#include <fts.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>

/* The fields of FILEDESCRIPTORW this module uses, by their offsets */
#define DESCRIPTOR_FLAGS 0u
#define DESCRIPTOR_ATTRIBUTES 36u
#define DESCRIPTOR_WRITE_TIME 56u
#define DESCRIPTOR_SIZE_HIGH 64u
#define DESCRIPTOR_SIZE_LOW 68u
#define DESCRIPTOR_NAME 72u
/* cFileName holds 260 UTF-16 units with the zero at its end */
#define NAME_UNITS 260u

/* FD_FLAGS of the shell: which fields a descriptor fills, and the progress window Explorer shows */
#define FD_ATTRIBUTES_FLAG 0x00000004u
#define FD_WRITESTIME_FLAG 0x00000020u
#define FD_FILESIZE_FLAG 0x00000040u
#define FD_PROGRESSUI_FLAG 0x00004000u

#define FILE_ATTRIBUTE_DIRECTORY_FLAG 0x00000010u
#define FILE_ATTRIBUTE_NORMAL_FLAG 0x00000080u

/* FILETIME counts 100 ns from 1601, the Mac seconds from 1970 */
#define FILETIME_UNITS_PER_SECOND 10000000ull
#define NANOSECONDS_PER_FILETIME_UNIT 100ull
#define SECONDS_FROM_1601_TO_1970 11644473600ull

/* The first capacity of a list, doubled as it grows */
#define FIRST_CAPACITY 16u

/* Finder writes it into every folder it shows; Windows has no use for it */
static const char finderInfoName[] = ".DS_Store";

static uint32_t readLE32(const uint8_t* bytes)
{
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static uint64_t readLE64(const uint8_t* bytes)
{
    return (uint64_t)readLE32(bytes) | ((uint64_t)readLE32(bytes + 4) << 32);
}

static void writeLE32(uint8_t* bytes, uint32_t value)
{
    for (int i = 0; i < 4; i++)
        bytes[i] = (uint8_t)(value >> (8 * i));
}

static void writeLE64(uint8_t* bytes, uint64_t value)
{
    writeLE32(bytes, (uint32_t)value);
    writeLE32(bytes + 4, (uint32_t)(value >> 32));
}

/* Room for one more item of size bytes in an array that doubles */
static bool grow(void** items, size_t count, size_t* capacity, size_t size)
{
    if (count < *capacity)
        return true;
    const size_t larger = *capacity ? 2 * *capacity : FIRST_CAPACITY;
    void* grown = realloc(*items, larger * size);
    if (!grown)
        return false;
    *items = grown;
    *capacity = larger;
    return true;
}

/* ---------- Mac to Windows ---------- */

static bool addLocal(VRCLocalFiles* files, size_t* capacity, const FTSENT* entry, size_t nameStart, bool directory)
{
    if (!grow((void**)&files->items, files->count, capacity, sizeof(*files->items)))
        return false;
    char* path = strdup(entry->fts_path);
    if (!path)
        return false;
    files->items[files->count++] = (VRCLocalFile){
        .path = path,
        .nameStart = nameStart,
        .directory = directory,
        .size = directory ? 0 : (uint64_t)entry->fts_statp->st_size,
        .modified = entry->fts_statp->st_mtimespec,
    };
    return true;
}

/* One copied item and everything inside it; the names count from the folder that holds the item */
static bool addTree(VRCLocalFiles* files, size_t* capacity, char* path)
{
    char* const roots[] = { path, NULL };
    FTS* walk = fts_open(roots, FTS_PHYSICAL | FTS_COMFOLLOW | FTS_NOCHDIR, NULL);
    if (!walk)
        return false;
    const size_t nameStart = (size_t)(strrchr(path, '/') - path) + 1;

    bool ok = true;
    FTSENT* entry;
    while (ok && (entry = fts_read(walk)) != NULL)
    {
        switch (entry->fts_info)
        {
            case FTS_D:
                ok = addLocal(files, capacity, entry, nameStart, true);
                break;
            case FTS_F:
                if (strcmp(entry->fts_name, finderInfoName) != 0)
                    ok = addLocal(files, capacity, entry, nameStart, false);
                break;
            case FTS_DNR:
            case FTS_ERR:
            case FTS_NS:
                ok = false;
                break;
            default:
                /* Folders on the way back, links inside folders, sockets and the like */
                break;
        }
    }
    fts_close(walk);
    return ok;
}

/* A name of the list in UTF-16 for Windows: composed, with backslashes; false when it is longer than Windows takes */
static bool writeName(uint8_t* out, const char* name)
{
    CFStringRef string = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
    if (!string)
        return false;
    CFMutableStringRef composed = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, string);
    CFRelease(string);
    if (!composed)
        return false;
    CFStringNormalize(composed, kCFStringNormalizationFormC);
    const CFIndex length = CFStringGetLength(composed);
    const bool fits = length > 0 && (size_t)length < NAME_UNITS;
    if (fits)
    {
        UniChar units[NAME_UNITS];
        CFStringGetCharacters(composed, CFRangeMake(0, length), units);
        for (CFIndex i = 0; i < length; i++)
        {
            const UniChar unit = units[i] == '/' ? '\\' : units[i];
            out[2 * i] = (uint8_t)unit;
            out[2 * i + 1] = (uint8_t)(unit >> 8);
        }
    }
    CFRelease(composed);
    return fits;
}

static bool buildDescriptor(VRCLocalFiles* files)
{
    if (files->count > (UINT32_MAX - 4) / VRC_FILE_DESCRIPTOR_SIZE)
        return false;
    files->descriptorLength = 4 + files->count * VRC_FILE_DESCRIPTOR_SIZE;
    files->descriptor = calloc(1, files->descriptorLength);
    if (!files->descriptor)
        return false;
    writeLE32(files->descriptor, (uint32_t)files->count);

    for (size_t i = 0; i < files->count; i++)
    {
        const VRCLocalFile* item = &files->items[i];
        uint8_t* out = files->descriptor + 4 + i * VRC_FILE_DESCRIPTOR_SIZE;
        writeLE32(out + DESCRIPTOR_FLAGS,
                  FD_ATTRIBUTES_FLAG | FD_FILESIZE_FLAG | FD_WRITESTIME_FLAG | FD_PROGRESSUI_FLAG);
        writeLE32(out + DESCRIPTOR_ATTRIBUTES,
                  item->directory ? FILE_ATTRIBUTE_DIRECTORY_FLAG : FILE_ATTRIBUTE_NORMAL_FLAG);
        /* Times before 1970 are rare enough on the Mac to go as its start */
        const uint64_t seconds = item->modified.tv_sec > 0 ? (uint64_t)item->modified.tv_sec : 0;
        writeLE64(out + DESCRIPTOR_WRITE_TIME, (seconds + SECONDS_FROM_1601_TO_1970) * FILETIME_UNITS_PER_SECOND +
                                                   (uint64_t)item->modified.tv_nsec / NANOSECONDS_PER_FILETIME_UNIT);
        writeLE32(out + DESCRIPTOR_SIZE_HIGH, (uint32_t)(item->size >> 32));
        writeLE32(out + DESCRIPTOR_SIZE_LOW, (uint32_t)item->size);
        if (!writeName(out + DESCRIPTOR_NAME, item->path + item->nameStart))
            return false;
    }
    return true;
}

VRCLocalFiles* vrcLocalFilesCreate(const char* paths, size_t length)
{
    if (!paths || length == 0 || paths[length - 1] != '\0')
        return NULL;
    VRCLocalFiles* files = calloc(1, sizeof(*files));
    if (!files)
        return NULL;
    size_t capacity = 0;

    bool ok = true;
    for (size_t offset = 0; ok && offset < length;)
    {
        char* path = strdup(paths + offset);
        offset += strlen(paths + offset) + 1;
        ok = path != NULL && path[0] == '/';
        /* A trailing slash would leave the item without a name of its own */
        size_t pathLength = ok ? strlen(path) : 0;
        while (pathLength > 1 && path[pathLength - 1] == '/')
            path[--pathLength] = '\0';
        ok = ok && pathLength > 1 && addTree(files, &capacity, path);
        free(path);
    }
    if (!ok || !buildDescriptor(files))
    {
        vrcLocalFilesFree(files);
        return NULL;
    }
    return files;
}

void vrcLocalFilesFree(VRCLocalFiles* files)
{
    if (!files)
        return;
    for (size_t i = 0; i < files->count; i++)
        free(files->items[i].path);
    free(files->items);
    free(files->descriptor);
    free(files);
}

bool vrcLocalFilesRead(const VRCLocalFiles* files, uint32_t index, uint64_t position, uint32_t length, uint8_t* out,
                       uint32_t* read)
{
    if (!files || index >= files->count || files->items[index].directory || position > INT64_MAX)
        return false;
    const int file = open(files->items[index].path, O_RDONLY | O_CLOEXEC);
    if (file < 0)
        return false;

    uint32_t done = 0;
    bool ok = true;
    while (done < length)
    {
        const ssize_t got = pread(file, out + done, length - done, (off_t)(position + done));
        if (got < 0)
        {
            ok = false;
            break;
        }
        if (got == 0)
            break;
        done += (uint32_t)got;
    }
    close(file);
    *read = done;
    return ok;
}

/* ---------- Windows to Mac ---------- */

/* A name of the server as a relative path of the Mac; NULL when it is broken or would leave its folder */
static char* readName(const uint8_t* in)
{
    UniChar units[NAME_UNITS];
    CFIndex length = 0;
    for (; length < (CFIndex)NAME_UNITS; length++)
    {
        units[length] = (UniChar)(in[2 * length] | (in[2 * length + 1] << 8));
        if (units[length] == 0)
            break;
    }
    if (length == 0 || length == (CFIndex)NAME_UNITS)
        return NULL;
    for (CFIndex i = 0; i < length; i++)
        if (units[i] == '\\')
            units[i] = '/';

    CFStringRef string = CFStringCreateWithCharacters(kCFAllocatorDefault, units, length);
    if (!string)
        return NULL;
    const CFIndex size = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    char* name = malloc((size_t)size);
    const bool converted = name && CFStringGetCString(string, name, size, kCFStringEncodingUTF8);
    CFRelease(string);
    if (!converted)
    {
        free(name);
        return NULL;
    }

    /* Every part must be a name: none empty, none "." or "..", so the path stays inside the folder */
    for (const char* part = name; *part;)
    {
        const char* end = strchr(part, '/');
        const size_t partLength = end ? (size_t)(end - part) : strlen(part);
        if (partLength == 0 || (partLength == 1 && part[0] == '.') ||
            (partLength == 2 && part[0] == '.' && part[1] == '.') || (end && end[1] == '\0'))
        {
            free(name);
            return NULL;
        }
        part += partLength + (end ? 1 : 0);
    }
    return name;
}

VRCRemoteFiles* vrcRemoteFilesParse(const uint8_t* descriptor, size_t length)
{
    if (!descriptor || length < 4)
        return NULL;
    const uint32_t count = readLE32(descriptor);
    if (count > (length - 4) / VRC_FILE_DESCRIPTOR_SIZE)
        return NULL;
    VRCRemoteFiles* files = calloc(1, sizeof(*files));
    if (!files)
        return NULL;
    files->items = calloc(count ? count : 1, sizeof(*files->items));
    if (!files->items)
    {
        free(files);
        return NULL;
    }

    for (uint32_t i = 0; i < count; i++)
    {
        const uint8_t* in = descriptor + 4 + (size_t)i * VRC_FILE_DESCRIPTOR_SIZE;
        VRCRemoteFile* item = &files->items[i];
        item->name = readName(in + DESCRIPTOR_NAME);
        if (!item->name)
        {
            vrcRemoteFilesFree(files);
            return NULL;
        }
        files->count++;
        const uint32_t flags = readLE32(in + DESCRIPTOR_FLAGS);
        item->directory = (flags & FD_ATTRIBUTES_FLAG) &&
                          (readLE32(in + DESCRIPTOR_ATTRIBUTES) & FILE_ATTRIBUTE_DIRECTORY_FLAG);
        item->hasSize = !item->directory && (flags & FD_FILESIZE_FLAG);
        item->size = ((uint64_t)readLE32(in + DESCRIPTOR_SIZE_HIGH) << 32) | readLE32(in + DESCRIPTOR_SIZE_LOW);
        const uint64_t written = readLE64(in + DESCRIPTOR_WRITE_TIME);
        const uint64_t epoch = SECONDS_FROM_1601_TO_1970 * FILETIME_UNITS_PER_SECOND;
        item->hasModified = (flags & FD_WRITESTIME_FLAG) && written >= epoch;
        if (item->hasModified)
        {
            item->modified.tv_sec = (time_t)((written - epoch) / FILETIME_UNITS_PER_SECOND);
            const uint64_t units = (written - epoch) % FILETIME_UNITS_PER_SECOND;
            item->modified.tv_nsec = (long)(units * NANOSECONDS_PER_FILETIME_UNIT);
        }
    }
    return files;
}

void vrcRemoteFilesFree(VRCRemoteFiles* files)
{
    if (!files)
        return;
    for (size_t i = 0; i < files->count; i++)
        free(files->items[i].name);
    free(files->items);
    free(files);
}

bool vrcRemoteFilesTopLevel(const VRCRemoteFiles* files, char** out, size_t* outLength)
{
    /* The first part of every name, once: a list may name a file inside a folder it does not list */
    size_t total = 0;
    for (size_t i = 0; i < files->count; i++)
        total += strlen(files->items[i].name) + 1;
    char* names = malloc(total ? total : 1);
    if (!names)
        return false;

    size_t length = 0;
    for (size_t i = 0; i < files->count; i++)
    {
        const char* name = files->items[i].name;
        const char* slash = strchr(name, '/');
        const size_t partLength = slash ? (size_t)(slash - name) : strlen(name);
        bool seen = false;
        for (size_t at = 0; at < length && !seen; at += strlen(names + at) + 1)
            seen = strlen(names + at) == partLength && memcmp(names + at, name, partLength) == 0;
        if (!seen)
        {
            memcpy(names + length, name, partLength);
            names[length + partLength] = '\0';
            length += partLength + 1;
        }
    }
    *out = names;
    *outLength = length;
    return true;
}
