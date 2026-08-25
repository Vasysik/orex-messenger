package ru.orex.messenger

/**
 * A plain push Reject is a terminal background action, not navigation.
 * System-managed calls keep using the Core-Telecom action supplied by Telecom.
 */
internal fun shouldUseHeadlessPushReject(
    action: String,
    systemManaged: Boolean,
): Boolean = action == "reject" && !systemManaged
