#include "input.h"

#include <freerdp/input.h>
#include <freerdp/scancode.h>

/* The largest rotation one pointer event carries: the field is 9 bits wide, signed */
#define WHEEL_STEP_MAX 255

void vrcInputQueueInit(VRCInputQueue* queue)
{
    queue->mutex = (pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;
    queue->open = false;
    queue->count = 0;
}

void vrcInputQueueDestroy(VRCInputQueue* queue)
{
    pthread_mutex_destroy(&queue->mutex);
}

void vrcInputQueueOpen(VRCInputQueue* queue)
{
    pthread_mutex_lock(&queue->mutex);
    queue->open = true;
    pthread_mutex_unlock(&queue->mutex);
}

void vrcInputQueueClose(VRCInputQueue* queue)
{
    pthread_mutex_lock(&queue->mutex);
    queue->open = false;
    queue->count = 0;
    pthread_mutex_unlock(&queue->mutex);
}

VRCResult vrcInputQueuePush(VRCInputQueue* queue, const VRCInputEvent* event)
{
    VRCResult result = VRCResultOK;

    pthread_mutex_lock(&queue->mutex);
    VRCInputEvent* last = queue->count > 0 ? &queue->events[queue->count - 1] : NULL;
    if (!queue->open)
        result = VRCResultInvalidState;
    else if (event->kind == VRCInputKindMove && last && last->kind == VRCInputKindMove)
        *last = *event;
    else if (queue->count == VRC_INPUT_QUEUE_CAPACITY)
        result = VRCResultFailure;
    else
        queue->events[queue->count++] = *event;
    pthread_mutex_unlock(&queue->mutex);
    return result;
}

size_t vrcInputQueueTake(VRCInputQueue* queue, VRCInputEvent* events, size_t capacity)
{
    pthread_mutex_lock(&queue->mutex);
    const size_t taken = queue->count < capacity ? queue->count : capacity;
    for (size_t i = 0; i < taken; i++)
        events[i] = queue->events[i];
    /* A caller with less room than the queue gets the oldest events; the rest move to the front */
    for (size_t i = taken; i < queue->count; i++)
        queue->events[i - taken] = queue->events[i];
    queue->count -= taken;
    pthread_mutex_unlock(&queue->mutex);
    return taken;
}

bool vrcButtonFlags(VRCMouseButton button, bool pressed, uint16_t* flags, bool* extended)
{
    switch (button)
    {
        case VRCMouseButtonLeft:
            *flags = PTR_FLAGS_BUTTON1;
            break;
        case VRCMouseButtonRight:
            *flags = PTR_FLAGS_BUTTON2;
            break;
        case VRCMouseButtonMiddle:
            *flags = PTR_FLAGS_BUTTON3;
            break;
        case VRCMouseButtonBack:
            *flags = PTR_XFLAGS_BUTTON1;
            break;
        case VRCMouseButtonForward:
            *flags = PTR_XFLAGS_BUTTON2;
            break;
        default:
            return false;
    }
    *extended = button == VRCMouseButtonBack || button == VRCMouseButtonForward;
    if (pressed)
        *flags |= *extended ? PTR_XFLAGS_DOWN : PTR_FLAGS_DOWN;
    return true;
}

/* A negative rotation is the 9-bit two's complement: the sign bit is PTR_FLAGS_WHEEL_NEGATIVE */
size_t vrcWheelFlags(VRCWheelAxis axis, int32_t delta, uint16_t* flags, size_t capacity)
{
    const uint16_t base = axis == VRCWheelAxisHorizontal ? PTR_FLAGS_HWHEEL : PTR_FLAGS_WHEEL;
    /* 64 bits: the magnitude of INT32_MIN does not fit in 32 */
    int64_t remaining = delta < 0 ? -(int64_t)delta : delta;
    size_t count = 0;

    while (remaining > 0 && count < capacity)
    {
        const uint16_t step = (uint16_t)(remaining < WHEEL_STEP_MAX ? remaining : WHEEL_STEP_MAX);
        flags[count++] = delta < 0 ? (uint16_t)(base | PTR_FLAGS_WHEEL_NEGATIVE | ((0x100u - step) & 0xFFu))
                                   : (uint16_t)(base | step);
        remaining -= step;
    }
    return count;
}

bool vrcKeyValid(uint16_t key)
{
    const uint16_t code = RDP_SCANCODE_CODE(key);
    return code != 0 && code <= 0x7F && (key & ~(uint16_t)(KBDEXT | 0xFF)) == 0;
}

void vrcKeyStateSet(VRCKeyState* state, uint16_t key, bool down)
{
    if (!vrcKeyValid(key))
        return;
    const uint8_t bit = (uint8_t)(1u << (key % 8));
    if (down)
        state->down[key / 8] |= bit;
    else
        state->down[key / 8] &= (uint8_t)~bit;
}

size_t vrcKeyStateTakeDown(VRCKeyState* state, uint16_t* keys, size_t capacity)
{
    size_t count = 0;
    for (uint16_t key = 0; key < VRC_KEY_COUNT && count < capacity; key++)
        if (state->down[key / 8] & (1u << (key % 8)))
        {
            keys[count++] = key;
            vrcKeyStateSet(state, key, false);
        }
    return count;
}
