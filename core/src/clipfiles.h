/*
 * Files of the clipboard: the list Windows sees as FileGroupDescriptorW, and the files behind it
 *
 * Mac to Windows: the paths the app gives become a list of files and folders with names relative to the copied items,
 * and the server reads the files by their place in that list
 * Windows to Mac: the list of the server is checked, since its names become paths on the Mac
 */

#ifndef VRC_CLIPFILES_H
#define VRC_CLIPFILES_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

/* The size of one FILEDESCRIPTORW in the list: the list is a count of 4 bytes, then the descriptors */
#define VRC_FILE_DESCRIPTOR_SIZE 592u

/* Files and folders of the Mac as the server sees them */
typedef struct VRCLocalFile {
    /* The path on the Mac */
    char* path;
    /* Where the name Windows sees starts in the path: after the folder that holds the copied item */
    size_t nameStart;
    bool directory;
    uint64_t size;
    struct timespec modified;
} VRCLocalFile;

typedef struct VRCLocalFiles {
    VRCLocalFile* items;
    size_t count;
    /* FileGroupDescriptorW of the items, in their order */
    uint8_t* descriptor;
    size_t descriptorLength;
} VRCLocalFiles;

/*
 * The list for absolute paths, each ending with a zero byte: a folder brings everything inside it
 * Symbolic links inside folders and .DS_Store are left out, and names go to Windows in the composed form of Unicode
 * NULL when a path cannot be read, a name is longer than Windows takes, or the memory runs out
 */
VRCLocalFiles* vrcLocalFilesCreate(const char* paths, size_t length);
void vrcLocalFilesFree(VRCLocalFiles* files);

/*
 * Reads up to length bytes of a file of the list from position into out; *read is 0 at the end of the file
 * False for a folder, an index outside the list or a failed read
 */
bool vrcLocalFilesRead(const VRCLocalFiles* files, uint32_t index, uint64_t position, uint32_t length, uint8_t* out,
                       uint32_t* read);

/* Files and folders of the server, from its FileGroupDescriptorW */
typedef struct VRCRemoteFile {
    /* Relative, its parts joined by '/' and none of them empty, "." or ".." */
    char* name;
    bool directory;
    bool hasSize;
    uint64_t size;
    bool hasModified;
    struct timespec modified;
} VRCRemoteFile;

typedef struct VRCRemoteFiles {
    VRCRemoteFile* items;
    size_t count;
} VRCRemoteFiles;

/* NULL when the list is broken or a name would leave the folder the files go to */
VRCRemoteFiles* vrcRemoteFilesParse(const uint8_t* descriptor, size_t length);
void vrcRemoteFilesFree(VRCRemoteFiles* files);

/* The names at the top of the list, each ending with a zero byte; *out is allocated with malloc */
bool vrcRemoteFilesTopLevel(const VRCRemoteFiles* files, char** out, size_t* outLength);

#endif
