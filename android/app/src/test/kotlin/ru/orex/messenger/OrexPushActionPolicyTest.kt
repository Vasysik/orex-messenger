package ru.orex.messenger

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OrexPushActionPolicyTest {
    @Test
    fun coldPushRejectUsesHeadlessPathInsteadOfActivity() {
        assertTrue(shouldUseHeadlessPushReject("reject", systemManaged = false))
        assertFalse(shouldUseHeadlessPushReject("answer", systemManaged = false))
        assertFalse(shouldUseHeadlessPushReject("reject", systemManaged = true))
    }
}
