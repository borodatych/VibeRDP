#include "decision.h"

enum {
    DecisionIdle,
    DecisionPending,
    DecisionAccepted,
    DecisionDeclined,
};

bool vrcDecisionInit(VRCDecision* decision)
{
    atomic_init(&decision->state, DecisionIdle);
    decision->answered = CreateEventA(NULL, TRUE, FALSE, NULL);
    return decision->answered != NULL;
}

void vrcDecisionDestroy(VRCDecision* decision)
{
    if (decision->answered)
        (void)CloseHandle(decision->answered);
    decision->answered = NULL;
}

void vrcDecisionOpen(VRCDecision* decision)
{
    (void)ResetEvent(decision->answered);
    atomic_store(&decision->state, DecisionPending);
}

VRCResult vrcDecisionAnswer(VRCDecision* decision, bool accept)
{
    int pending = DecisionPending;
    if (!atomic_compare_exchange_strong(&decision->state, &pending, accept ? DecisionAccepted : DecisionDeclined))
        return VRCResultInvalidState;
    (void)SetEvent(decision->answered);
    return VRCResultOK;
}

bool vrcDecisionWait(VRCDecision* decision, HANDLE abortEvent)
{
    HANDLE handles[] = { decision->answered, abortEvent };
    const DWORD status = WaitForMultipleObjects(ARRAYSIZE(handles), handles, FALSE, INFINITE);
    /* Back to idle before anything else: an answer racing with the abort now gets InvalidState */
    const int answer = atomic_exchange(&decision->state, DecisionIdle);
    return status == WAIT_OBJECT_0 && answer == DecisionAccepted;
}
