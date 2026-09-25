/*
 * Decision tests: the yes-or-no question the session thread waits on, built from core/src/decision.c directly
 * Usage: decisionTests <test name>; CTest registers every test separately
 */

#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "decision.h"

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

/* Nothing is asked yet: an answer finds no question */
static bool testAnswerNeedsAQuestion(void)
{
    VRCDecision decision;
    CHECK(vrcDecisionInit(&decision));
    CHECK(vrcDecisionAnswer(&decision, true) == VRCResultInvalidState);
    vrcDecisionDestroy(&decision);
    return true;
}

/* An answer given before the wait, as from within the callback, counts, and only the first one */
static bool testAnswerBeforeTheWait(void)
{
    VRCDecision decision;
    CHECK(vrcDecisionInit(&decision));
    HANDLE never = CreateEventA(NULL, TRUE, FALSE, NULL);
    CHECK(never != NULL);

    vrcDecisionOpen(&decision);
    CHECK(vrcDecisionAnswer(&decision, true) == VRCResultOK);
    CHECK(vrcDecisionAnswer(&decision, false) == VRCResultInvalidState);
    CHECK(vrcDecisionWait(&decision, never));
    CHECK(vrcDecisionAnswer(&decision, true) == VRCResultInvalidState);

    vrcDecisionOpen(&decision);
    CHECK(vrcDecisionAnswer(&decision, false) == VRCResultOK);
    CHECK(!vrcDecisionWait(&decision, never));

    (void)CloseHandle(never);
    vrcDecisionDestroy(&decision);
    return true;
}

typedef struct Answerer {
    VRCDecision* decision;
    bool accept;
} Answerer;

static void* answerLater(void* arg)
{
    const Answerer* answerer = arg;
    (void)Sleep(50);
    (void)vrcDecisionAnswer(answerer->decision, answerer->accept);
    return NULL;
}

/* The waiting thread wakes for an answer from another thread */
static bool testAnswerFromAnotherThread(void)
{
    VRCDecision decision;
    CHECK(vrcDecisionInit(&decision));
    HANDLE never = CreateEventA(NULL, TRUE, FALSE, NULL);
    CHECK(never != NULL);

    vrcDecisionOpen(&decision);
    Answerer answerer = { .decision = &decision, .accept = true };
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, answerLater, &answerer) == 0);
    CHECK(vrcDecisionWait(&decision, never));
    pthread_join(thread, NULL);

    (void)CloseHandle(never);
    vrcDecisionDestroy(&decision);
    return true;
}

/* The abort ends the wait without an answer, and a late answer finds the question closed */
static bool testAbortEndsTheWait(void)
{
    VRCDecision decision;
    CHECK(vrcDecisionInit(&decision));
    HANDLE aborted = CreateEventA(NULL, TRUE, TRUE, NULL);
    CHECK(aborted != NULL);

    vrcDecisionOpen(&decision);
    CHECK(!vrcDecisionWait(&decision, aborted));
    CHECK(vrcDecisionAnswer(&decision, true) == VRCResultInvalidState);

    (void)CloseHandle(aborted);
    vrcDecisionDestroy(&decision);
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "answerNeedsAQuestion", testAnswerNeedsAQuestion },
    { "answerBeforeTheWait", testAnswerBeforeTheWait },
    { "answerFromAnotherThread", testAnswerFromAnotherThread },
    { "abortEndsTheWait", testAbortEndsTheWait },
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
