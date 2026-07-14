package ru.orex.messenger

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OrexCallAttemptTest {
    @Test
    fun sameCallAttemptRequiresTheExactRoomAndAttemptIdentity() {
        assertTrue(sameCallAttempt("!room:orex", null, "!room:orex", null))
        assertTrue(sameCallAttempt("!room:orex", " event-a ", "!room:orex", "event-a"))

        assertFalse(sameCallAttempt("!room:orex", "event-a", "!room:orex", null))
        assertFalse(sameCallAttempt("!room:orex", null, "!room:orex", "event-a"))
        assertFalse(sameCallAttempt("!room:orex", "event-a", "!room:orex", "event-b"))
        assertFalse(sameCallAttempt("!room:orex", "event-a", "!other:orex", "event-a"))
    }

    @Test
    fun canPromoteRingAttemptOnlyEnrichesLegacyIdentity() {
        assertTrue(canPromoteRingAttempt(null, "event-a"))
        assertTrue(canPromoteRingAttempt("   ", " event-a "))

        assertFalse(canPromoteRingAttempt(null, null))
        assertFalse(canPromoteRingAttempt("event-a", null))
        assertFalse(canPromoteRingAttempt("event-a", "event-a"))
        assertFalse(canPromoteRingAttempt("event-a", "event-b"))
    }

    @Test
    fun exactCancellationClosesFallbackAfterPresentationStateTtlExpires() {
        // Notification/activity timeout can be longer than the persisted live
        // presentation state. The exact tombstoned event still owns that shell.
        assertTrue(
            exactCancellationMatchesFallback(
                liveCallId = null,
                liveRingEventId = null,
                liveIsRinging = false,
                requestedCallId = "!room:orex",
                requestedRingEventId = "event-a",
            ),
        )
    }

    @Test
    fun cancellationNeverFallsBackAcrossAttemptIdentity() {
        assertFalse(
            exactCancellationMatchesFallback(
                liveCallId = null,
                liveRingEventId = null,
                liveIsRinging = false,
                requestedCallId = "!room:orex",
                requestedRingEventId = null,
            ),
        )
        assertFalse(
            exactCancellationMatchesFallback(
                liveCallId = "!room:orex",
                liveRingEventId = "event-b",
                liveIsRinging = true,
                requestedCallId = "!room:orex",
                requestedRingEventId = "event-a",
            ),
        )
        assertFalse(
            exactCancellationMatchesFallback(
                liveCallId = "!room:orex",
                liveRingEventId = "event-a",
                liveIsRinging = false,
                requestedCallId = "!room:orex",
                requestedRingEventId = "event-a",
            ),
        )
    }

    @Test
    fun exactRecoveryDescriptorCanClearBesideNewerPresentation() {
        assertTrue(
            shouldApplyForegroundStop(
                descriptorMatched = true,
                presentationMatched = false,
            ),
        )
    }

    @Test
    fun foregroundStopWithoutAnyOwnedLifecycleIsANoop() {
        assertFalse(
            shouldApplyForegroundStop(
                descriptorMatched = false,
                presentationMatched = false,
            ),
        )
        assertTrue(
            shouldApplyForegroundStop(
                descriptorMatched = false,
                presentationMatched = true,
            ),
        )
    }

    @Test
    fun freshExactRingReplacesUnownedAnsweredState() {
        assertTrue(
            shouldReplaceUnownedNonRingingAttempt(
                currentCallId = "!room:orex",
                currentRingEventId = "event-old",
                currentIsRinging = false,
                requestedCallId = "!room:orex",
                requestedRingEventId = "event-new",
                hasLiveOwner = false,
            ),
        )
    }

    @Test
    fun freshRingNeverStealsAProcessOwnedCall() {
        assertFalse(
            shouldReplaceUnownedNonRingingAttempt(
                currentCallId = "!room:orex",
                currentRingEventId = "event-old",
                currentIsRinging = false,
                requestedCallId = "!room:orex",
                requestedRingEventId = "event-new",
                hasLiveOwner = true,
            ),
        )
        assertFalse(
            shouldReplaceUnownedNonRingingAttempt(
                currentCallId = "!room:orex",
                currentRingEventId = "event-old",
                currentIsRinging = true,
                requestedCallId = "!room:orex",
                requestedRingEventId = "event-new",
                hasLiveOwner = false,
            ),
        )
    }

    @Test
    fun tokenlessCandidateCannotClearPersistedState() {
        assertFalse(
            shouldReplaceUnownedNonRingingAttempt(
                currentCallId = "!room:orex",
                currentRingEventId = "event-old",
                currentIsRinging = false,
                requestedCallId = "!room:orex",
                requestedRingEventId = null,
                hasLiveOwner = false,
            ),
        )
    }


    @Test
    fun freshExactRingReplacesUnownedStateFromAnotherRoomOrLegacyAttempt() {
        assertTrue(
            shouldReplaceUnownedNonRingingAttempt(
                currentCallId = "!old:orex",
                currentRingEventId = "event-old",
                currentIsRinging = false,
                requestedCallId = "!new:orex",
                requestedRingEventId = "event-new",
                hasLiveOwner = false,
            ),
        )
        assertTrue(
            shouldReplaceUnownedNonRingingAttempt(
                currentCallId = "!room:orex",
                currentRingEventId = null,
                currentIsRinging = false,
                requestedCallId = "!room:orex",
                requestedRingEventId = "event-new",
                hasLiveOwner = false,
            ),
        )
    }

    @Test
    fun callHandoffAcceptsOnlyExactOrLegacyPromotableIdentity() {
        assertTrue(
            sameOrPromotableCallAttempt(
                "!room:orex",
                "event-a",
                "!room:orex",
                "event-a",
            ),
        )
        assertTrue(
            sameOrPromotableCallAttempt(
                "!room:orex",
                null,
                "!room:orex",
                "event-a",
            ),
        )
        assertFalse(
            sameOrPromotableCallAttempt(
                "!room:orex",
                "event-old",
                "!room:orex",
                "event-new",
            ),
        )
        assertFalse(
            sameOrPromotableCallAttempt(
                "!other:orex",
                null,
                "!room:orex",
                "event-a",
            ),
        )
    }

    @Test
    fun staleForegroundDescriptorCanBeReplacedButLiveCallCannotBeStolen() {
        assertTrue(
            shouldReplaceForegroundDescriptor(
                currentCallId = "!room:orex",
                currentRingEventId = "event-old",
                requestedCallId = "!room:orex",
                requestedRingEventId = "event-new",
                hasLiveOwner = false,
            ),
        )
        assertTrue(
            shouldReplaceForegroundDescriptor(
                currentCallId = "!old:orex",
                currentRingEventId = "event-old",
                requestedCallId = "!new:orex",
                requestedRingEventId = "event-new",
                hasLiveOwner = false,
            ),
        )
        assertFalse(
            shouldReplaceForegroundDescriptor(
                currentCallId = "!room:orex",
                currentRingEventId = "event-old",
                requestedCallId = "!room:orex",
                requestedRingEventId = "event-new",
                hasLiveOwner = true,
            ),
        )
        assertFalse(
            shouldReplaceForegroundDescriptor(
                currentCallId = "!old:orex",
                currentRingEventId = "event-old",
                requestedCallId = "!new:orex",
                requestedRingEventId = "event-new",
                hasLiveOwner = true,
            ),
        )
    }

    @Test
    fun unansweredIncomingBootstrapExpiresButActiveCallDoesNot() {
        assertTrue(
            shouldExpireAnsweringCall(
                incoming = true,
                answered = false,
                startedAt = 1_000L,
                now = 71_000L,
                timeoutMs = 70_000L,
            ),
        )
        assertFalse(
            shouldExpireAnsweringCall(
                incoming = true,
                answered = true,
                startedAt = 1_000L,
                now = 100_000L,
                timeoutMs = 70_000L,
            ),
        )
        assertFalse(
            shouldExpireAnsweringCall(
                incoming = false,
                answered = false,
                startedAt = 1_000L,
                now = 100_000L,
                timeoutMs = 70_000L,
            ),
        )
    }

}
