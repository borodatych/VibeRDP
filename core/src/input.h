/*
 * Input of a session, the mouse and the keyboard: the app queues it from any thread, and the session thread sends it
 * A slow link never blocks the caller, and nothing is sent while the session is set up or torn down
 */

#ifndef VRC_INPUT_H
#define VRC_INPUT_H

#include "VibeRDPCore/VibeRDPCore.h"

#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Moves merge, so only clicks, wheel steps and keys fill the queue: a full one means the session stopped sending */
#define VRC_INPUT_QUEUE_CAPACITY 256u

/* The most wheel steps one rotation may need: RDP carries at most 255 units in one event */
#define VRC_WHEEL_MAX_STEPS 32u

/* Every key VRCSessionSendKey accepts: seven bits of scan code and the extended bit */
#define VRC_KEY_COUNT 0x200u

typedef enum VRCInputKind {
    VRCInputKindMove,
    VRCInputKindButton,
    VRCInputKindWheel,
    VRCInputKindKey,
    /* The desktop got the keyboard: the server learns the lock keys */
    VRCInputKindFocusIn,
    /* The desktop lost the keyboard: the keys the server holds down are released */
    VRCInputKindReleaseKeys,
    /* The server sends the whole desktop again */
    VRCInputKindRefresh,
    /* The desktop follows the window: x and y carry the width and the height, scale its scale in percent */
    VRCInputKindResize,
} VRCInputKind;

typedef struct VRCInputEvent {
    VRCInputKind kind;
    uint32_t x;
    uint32_t y;
    VRCMouseButton button;
    bool pressed;
    VRCWheelAxis axis;
    int32_t delta;
    uint16_t key;
    bool repeat;
    bool capsLock;
    bool numLock;
    uint32_t scale;
} VRCInputEvent;

/* The keys the server holds down, as the session thread sent them */
typedef struct VRCKeyState {
    uint8_t down[VRC_KEY_COUNT / 8];
} VRCKeyState;

typedef struct VRCInputQueue {
    pthread_mutex_t mutex;
    /* Closed until the connection is up and again once it ends: pushes then get InvalidState */
    bool open;
    size_t count;
    VRCInputEvent events[VRC_INPUT_QUEUE_CAPACITY];
} VRCInputQueue;

/* An empty, closed queue; the static mutex cannot fail */
void vrcInputQueueInit(VRCInputQueue* queue);
void vrcInputQueueDestroy(VRCInputQueue* queue);

void vrcInputQueueOpen(VRCInputQueue* queue);

/* Refuses further events and drops the pending ones */
void vrcInputQueueClose(VRCInputQueue* queue);

/*
 * Adds an event after the pending ones; a move right after a move replaces it
 * InvalidState while the queue is closed, Failure when it is full
 */
VRCResult vrcInputQueuePush(VRCInputQueue* queue, const VRCInputEvent* event);

/* Moves the pending events into events, oldest first, and returns their count */
size_t vrcInputQueueTake(VRCInputQueue* queue, VRCInputEvent* events, size_t capacity);

/*
 * The pointer flags of a press or release; extended is set for the buttons that need the extended mouse event
 * False for a value outside VRCMouseButton
 */
bool vrcButtonFlags(VRCMouseButton button, bool pressed, uint16_t* flags, bool* extended);

/*
 * Splits a rotation into the steps of RDP pointer events: a 9-bit signed value each, at most 255 units
 * Returns the number of steps written to flags; a zero delta has none
 */
size_t vrcWheelFlags(VRCWheelAxis axis, int32_t delta, uint16_t* flags, size_t capacity);

/* A scan code of set 1 with the extended bit: not zero, at most 0x7F, and no other bits */
bool vrcKeyValid(uint16_t key);

/* Marks a key held down or released; an invalid key changes nothing */
void vrcKeyStateSet(VRCKeyState* state, uint16_t key, bool down);

/*
 * Moves the keys held down into keys, in the order of their codes, and returns their count
 * The keys moved are no longer held; those beyond the capacity stay
 */
size_t vrcKeyStateTakeDown(VRCKeyState* state, uint16_t* keys, size_t capacity);

#endif
