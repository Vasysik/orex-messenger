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
}
