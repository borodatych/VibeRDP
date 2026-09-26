/*
 * The VibeSeam channel: the dynamic virtual channel the helper on Windows opens, protocol/seam-protocol.md
 *
 * The core carries whole bodies both ways and leaves the MessagePack inside them to the app:
 * it gathers the frames the channel hands out in chunks and puts the length in front of what the app sends
 *
 * The channel opens, delivers and closes on the channel thread of the engine; the app sends from its own threads,
 * so the channel pointer is under a mutex, while the frame being gathered belongs to the channel thread alone
 */

#ifndef VRC_SEAM_H
#define VRC_SEAM_H

#include "VibeRDPCore/VibeRDPCore.h"

#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <freerdp/dvc.h>
#include <freerdp/settings.h>

/* The name the helper opens and the client listens for */
#define VRC_SEAM_CHANNEL_NAME "VibeSeam"
/* The length in front of every body: u32, little-endian */
#define VRC_SEAM_LENGTH_SIZE 4

typedef struct VRCSeam {
    pthread_mutex_t mutex;
    /* Set while the channel is open; the engine frees it after closing */
    IWTSVirtualChannel* channel;

    /* The frame being gathered: its length field first, then as much of the body as has come */
    uint8_t* pending;
    size_t pendingLength;
    size_t pendingCapacity;
    /* A protocol error happened on this channel: the rest of it is dropped until it closes */
    bool broken;

    const VRCCallbacks* callbacks;
    void* const* userData;
} VRCSeam;

void vrcSeamInit(VRCSeam* seam, const VRCCallbacks* callbacks, void* const* userData);
void vrcSeamDestroy(VRCSeam* seam);

/*
 * The helper opened the channel, or it closed; the app hears of both
 * Several may open at once: a session that attaches brings every open the helper tried while it was away
 * The newest is the channel; one that is not closes or speaks without the app hearing of it
 */
void vrcSeamOpened(VRCSeam* seam, IWTSVirtualChannel* channel);
void vrcSeamClosed(VRCSeam* seam, IWTSVirtualChannel* channel);

/*
 * A chunk of the stream: every body it completes goes to the app, in order
 * A length above VRC_SEAM_MAX_BODY is a protocol error: the app hears the channel closed, the rest is dropped
 */
void vrcSeamReceived(VRCSeam* seam, IWTSVirtualChannel* channel, const uint8_t* chunk, size_t length);

/* Sends one body with its length in front; InvalidState while the channel is not open */
VRCResult vrcSeamSend(VRCSeam* seam, const uint8_t* body, size_t length);

/*
 * Makes the channel part of the connection: the engine loads the dynamic channels by name through a provider,
 * and the core puts its own in front of the one FreeRDP registers, which serves every other name
 */
BOOL vrcSeamApply(rdpSettings* settings);

/* The seam of the session whose engine context this is: session.c knows the layout of the session */
VRCSeam* vrcSessionSeam(rdpContext* context);

#endif
