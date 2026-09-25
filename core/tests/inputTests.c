/*
 * Input tests: the queue of pointer events and their encoding for RDP, built from core/src/input.c directly
 * The framework exports only the VRC API, so the tests compile the module themselves
 * Usage: inputTests <test name>; CTest registers every test separately
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <freerdp/input.h>

#include "input.h"

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

static VRCInputEvent move(uint32_t x, uint32_t y)
{
    return (VRCInputEvent){ .kind = VRCInputKindMove, .x = x, .y = y };
}

static VRCInputEvent button(VRCMouseButton which, bool pressed)
{
    return (VRCInputEvent){ .kind = VRCInputKindButton, .x = 5, .y = 6, .button = which, .pressed = pressed };
}

static VRCResult push(VRCInputQueue* queue, VRCInputEvent event)
{
    return vrcInputQueuePush(queue, &event);
}

static bool testQueueKeepsOrder(void)
{
    VRCInputQueue queue;
    vrcInputQueueInit(&queue);
    vrcInputQueueOpen(&queue);
    const VRCInputEvent wheel = { .kind = VRCInputKindWheel, .axis = VRCWheelAxisHorizontal, .delta = -40 };
    CHECK(push(&queue, button(VRCMouseButtonLeft, true)) == VRCResultOK);
    CHECK(push(&queue, button(VRCMouseButtonLeft, false)) == VRCResultOK);
    CHECK(push(&queue, wheel) == VRCResultOK);

    VRCInputEvent taken[4];
    CHECK(vrcInputQueueTake(&queue, taken, 4) == 3);
    CHECK(taken[0].kind == VRCInputKindButton && taken[0].pressed);
    CHECK(taken[1].kind == VRCInputKindButton && !taken[1].pressed);
    CHECK(taken[2].kind == VRCInputKindWheel && taken[2].axis == VRCWheelAxisHorizontal && taken[2].delta == -40);
    CHECK(vrcInputQueueTake(&queue, taken, 4) == 0);
    vrcInputQueueDestroy(&queue);
    return true;
}

/* Only consecutive moves merge: a click between them keeps both, at the positions they had */
static bool testMovesMerge(void)
{
    VRCInputQueue queue;
    vrcInputQueueInit(&queue);
    vrcInputQueueOpen(&queue);
    CHECK(push(&queue, move(1, 1)) == VRCResultOK);
    CHECK(push(&queue, move(2, 2)) == VRCResultOK);
    CHECK(push(&queue, button(VRCMouseButtonRight, true)) == VRCResultOK);
    CHECK(push(&queue, move(3, 3)) == VRCResultOK);

    VRCInputEvent taken[4];
    CHECK(vrcInputQueueTake(&queue, taken, 4) == 3);
    CHECK(taken[0].kind == VRCInputKindMove && taken[0].x == 2 && taken[0].y == 2);
    CHECK(taken[1].kind == VRCInputKindButton && taken[1].button == VRCMouseButtonRight);
    CHECK(taken[2].kind == VRCInputKindMove && taken[2].x == 3 && taken[2].y == 3);
    vrcInputQueueDestroy(&queue);
    return true;
}

static bool testClosedQueueRefuses(void)
{
    VRCInputQueue queue;
    vrcInputQueueInit(&queue);
    CHECK(push(&queue, move(1, 1)) == VRCResultInvalidState);

    vrcInputQueueOpen(&queue);
    CHECK(push(&queue, move(1, 1)) == VRCResultOK);
    vrcInputQueueClose(&queue);
    VRCInputEvent taken[1];
    CHECK(vrcInputQueueTake(&queue, taken, 1) == 0);
    CHECK(push(&queue, move(1, 1)) == VRCResultInvalidState);
    vrcInputQueueDestroy(&queue);
    return true;
}

/* A full queue refuses even a move: merging applies only to a move right after a move */
static bool testFullQueueFails(void)
{
    VRCInputQueue queue;
    vrcInputQueueInit(&queue);
    vrcInputQueueOpen(&queue);
    for (unsigned i = 0; i < VRC_INPUT_QUEUE_CAPACITY; i++)
        CHECK(push(&queue, button(VRCMouseButtonLeft, i % 2 == 0)) == VRCResultOK);
    CHECK(push(&queue, button(VRCMouseButtonLeft, true)) == VRCResultFailure);
    CHECK(push(&queue, move(1, 1)) == VRCResultFailure);
    vrcInputQueueDestroy(&queue);
    return true;
}

static bool testTakeWithLessRoom(void)
{
    VRCInputQueue queue;
    vrcInputQueueInit(&queue);
    vrcInputQueueOpen(&queue);
    for (unsigned i = 0; i < 3; i++)
    {
        const VRCInputEvent wheel = { .kind = VRCInputKindWheel, .delta = (int32_t)i + 1 };
        CHECK(push(&queue, wheel) == VRCResultOK);
    }

    VRCInputEvent taken[2];
    CHECK(vrcInputQueueTake(&queue, taken, 2) == 2);
    CHECK(taken[0].delta == 1 && taken[1].delta == 2);
    CHECK(vrcInputQueueTake(&queue, taken, 2) == 1);
    CHECK(taken[0].delta == 3);
    vrcInputQueueDestroy(&queue);
    return true;
}

static bool testButtonFlags(void)
{
    uint16_t flags = 0;
    bool extended = true;

    CHECK(vrcButtonFlags(VRCMouseButtonLeft, true, &flags, &extended));
    CHECK(flags == (PTR_FLAGS_BUTTON1 | PTR_FLAGS_DOWN) && !extended);
    CHECK(vrcButtonFlags(VRCMouseButtonLeft, false, &flags, &extended));
    CHECK(flags == PTR_FLAGS_BUTTON1 && !extended);
    CHECK(vrcButtonFlags(VRCMouseButtonRight, true, &flags, &extended));
    CHECK(flags == (PTR_FLAGS_BUTTON2 | PTR_FLAGS_DOWN) && !extended);
    CHECK(vrcButtonFlags(VRCMouseButtonMiddle, false, &flags, &extended));
    CHECK(flags == PTR_FLAGS_BUTTON3 && !extended);

    /* The side buttons travel in the extended mouse event with flags of its own */
    CHECK(vrcButtonFlags(VRCMouseButtonBack, true, &flags, &extended));
    CHECK(flags == (PTR_XFLAGS_BUTTON1 | PTR_XFLAGS_DOWN) && extended);
    CHECK(vrcButtonFlags(VRCMouseButtonForward, false, &flags, &extended));
    CHECK(flags == PTR_XFLAGS_BUTTON2 && extended);

    CHECK(!vrcButtonFlags((VRCMouseButton)5, true, &flags, &extended));
    return true;
}

/* A negative step is the 9-bit two's complement: -120 is 0x188, the sign bit being PTR_FLAGS_WHEEL_NEGATIVE */
static bool testWheelSteps(void)
{
    uint16_t steps[VRC_WHEEL_MAX_STEPS];

    CHECK(vrcWheelFlags(VRCWheelAxisVertical, 120, steps, VRC_WHEEL_MAX_STEPS) == 1);
    CHECK(steps[0] == (PTR_FLAGS_WHEEL | 120));
    CHECK(vrcWheelFlags(VRCWheelAxisVertical, -120, steps, VRC_WHEEL_MAX_STEPS) == 1);
    CHECK(steps[0] == (PTR_FLAGS_WHEEL | 0x188));
    CHECK(vrcWheelFlags(VRCWheelAxisHorizontal, 1, steps, VRC_WHEEL_MAX_STEPS) == 1);
    CHECK(steps[0] == (PTR_FLAGS_HWHEEL | 1));

    CHECK(vrcWheelFlags(VRCWheelAxisVertical, 300, steps, VRC_WHEEL_MAX_STEPS) == 2);
    CHECK(steps[0] == (PTR_FLAGS_WHEEL | 255) && steps[1] == (PTR_FLAGS_WHEEL | 45));
    CHECK(vrcWheelFlags(VRCWheelAxisHorizontal, -300, steps, VRC_WHEEL_MAX_STEPS) == 2);
    CHECK(steps[0] == (PTR_FLAGS_HWHEEL | 0x101) && steps[1] == (PTR_FLAGS_HWHEEL | 0x1D3));

    CHECK(vrcWheelFlags(VRCWheelAxisVertical, 0, steps, VRC_WHEEL_MAX_STEPS) == 0);
    /* A rotation larger than the room is cut there, and the extreme value does not overflow */
    CHECK(vrcWheelFlags(VRCWheelAxisVertical, INT32_MIN, steps, 2) == 2);
    CHECK(steps[1] == (PTR_FLAGS_WHEEL | 0x101));
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "queueKeepsOrder", testQueueKeepsOrder },
    { "movesMerge", testMovesMerge },
    { "closedQueueRefuses", testClosedQueueRefuses },
    { "fullQueueFails", testFullQueueFails },
    { "takeWithLessRoom", testTakeWithLessRoom },
    { "buttonFlags", testButtonFlags },
    { "wheelSteps", testWheelSteps },
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
