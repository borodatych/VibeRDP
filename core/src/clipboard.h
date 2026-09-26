/*
 * The clipboard channel of a session: CLIPRDR of the engine on one side, the app on the other
 * The app speaks VRCClipboardFormat, the channel speaks the formats of Windows; this module maps and converts
 *
 * The channel calls in on the session thread, the app calls in from any thread
 * One question at a time goes each way, since the answers of the protocol carry no request number:
 * the server asks for data of the Mac and waits for vrcClipboardProvide,
 * and a copy from the server waits for its answer, the end of the session or the timeout
 *
 * Files go by ranges, and their answers carry the number of the request:
 * the server reads the files of the Mac through the channel thread, which answers without the app,
 * and a copy of the files of the server asks for one range at a time
 */

#ifndef VRC_CLIPBOARD_H
#define VRC_CLIPBOARD_H

#include "VibeRDPCore/VibeRDPCore.h"
#include "clipfiles.h"

#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <freerdp/client/cliprdr.h>
#include <winpr/synch.h>

/* One slot for every VRCClipboardFormat, indexed by its value */
#define VRC_CLIPBOARD_FORMAT_SLOTS 6

/* No entry of the table of Windows formats in clipboard.c */
#define NO_ENTRY (-1)

typedef struct VRCClipboard {
    /* Guards everything below except copyLock, and is held while a message goes out on the channel */
    pthread_mutex_t mutex;
    /* Set while the channel is up; the engine frees it after the channel goes down */
    CliprdrClientContext* channel;
    /* The server sent Monitor Ready and got the capabilities: format lists may go */
    bool ready;
    /* The formats the clipboard of the Mac offers, one bit for each value of VRCClipboardFormat */
    uint32_t offered;
    /* The offers of the Mac so far, numbered in the log */
    uint64_t offers;
    /* The format id of the server for each format it offers, 0 for none */
    uint32_t remoteFormatIds[VRC_CLIPBOARD_FORMAT_SLOTS];
    /* The entry of the table of Windows formats each of those ids stands for */
    int32_t remoteEntries[VRC_CLIPBOARD_FORMAT_SLOTS];
    /* The entry of the format the server asked for and waits for, NO_ENTRY when it waits for nothing */
    int32_t serverAsks;
    /*
     * The files of the last list the server got, NULL before any
     * The list stays after the Mac clipboard changes: a paste on the server may still be reading it
     */
    VRCLocalFiles* localFiles;
    /* Counts the lists of the server: data fetched for one of them is no good for the next */
    uint64_t remoteGeneration;
    /* FileGroupDescriptorW of the server, kept for the copy of its files; NULL when the list changed since */
    uint8_t* remoteDescriptor;
    size_t remoteDescriptorLength;

    /* One copy from the server at a time */
    pthread_mutex_t copyLock;
    HANDLE copyAnswered;
    /* The entry of the format of the copy that waits, NO_ENTRY when none does */
    int32_t copyEntry;
    /* Answers still due to copies that timed out: each request gets one answer, and they come in order */
    uint32_t lateAnswers;
    bool copySucceeded;
    uint8_t* copyData;
    size_t copyLength;

    /* One range of a file of the server at a time, under copyLock */
    HANDLE rangeAnswered;
    /* The number of the request that waits, 0 when none does; numbers go up from 1 */
    uint32_t rangeStream;
    uint32_t lastStream;
    bool rangeSucceeded;
    uint8_t* rangeData;
    size_t rangeLength;

    /* The callbacks of the session and the value they take, read when a callback goes out */
    const VRCCallbacks* callbacks;
    void* const* userData;
} VRCClipboard;

/* False when the events cannot be made; Destroy is safe either way */
bool vrcClipboardInit(VRCClipboard* clipboard, const VRCCallbacks* callbacks, void* const* userData);
void vrcClipboardDestroy(VRCClipboard* clipboard);

/* The channel came up or went down; going down ends a copy that waits, as a failure */
void vrcClipboardAttach(VRCClipboard* clipboard, CliprdrClientContext* channel);
void vrcClipboardDetach(VRCClipboard* clipboard, CliprdrClientContext* channel);

/* See VRCSessionOfferClipboard, VRCSessionProvideClipboardData and VRCSessionCopyRemoteClipboard */
VRCResult vrcClipboardOffer(VRCClipboard* clipboard, const VRCClipboardFormat* formats, size_t count);
VRCResult vrcClipboardProvide(VRCClipboard* clipboard, VRCClipboardFormat format, const void* data, size_t length);
VRCResult vrcClipboardCopyRemote(VRCClipboard* clipboard, VRCClipboardFormat format, uint32_t timeoutMs,
                                 HANDLE abortEvent, void** data, size_t* length);

/* See VRCSessionCopyRemoteFiles */
VRCResult vrcClipboardCopyRemoteFiles(VRCClipboard* clipboard, const char* directory, uint32_t timeoutMs,
                                      HANDLE abortEvent, VRCFileProgress progress, void* context);

#endif
