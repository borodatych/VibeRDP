/*
 * A yes-or-no question the session thread asks the app and waits for: a server certificate, a gateway consent
 * The app answers from any thread, once; the wait ends as well when the session is asked to end
 */

#ifndef VRC_DECISION_H
#define VRC_DECISION_H

#include "VibeRDPCore/VibeRDPCore.h"

#include <stdatomic.h>
#include <stdbool.h>

#include <winpr/synch.h>

typedef struct VRCDecision {
    /* Only a pending question takes an answer, and only one */
    atomic_int state;
    HANDLE answered;
} VRCDecision;

/* False when the event cannot be made; Destroy is safe either way */
bool vrcDecisionInit(VRCDecision* decision);
void vrcDecisionDestroy(VRCDecision* decision);

/* Opens the question before it goes to the app, so an answer from within the callback already counts */
void vrcDecisionOpen(VRCDecision* decision);

/* InvalidState unless a question is open and still unanswered */
VRCResult vrcDecisionAnswer(VRCDecision* decision, bool accept);

/*
 * Waits for the answer or for the abort event and closes the question: a late answer then gets InvalidState
 * True only for an accept that came first
 */
bool vrcDecisionWait(VRCDecision* decision, HANDLE abortEvent);

#endif
