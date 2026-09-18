package com.thrw.adapter.android.config

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Mirrors `adapter-mac`'s `RelayCredentialsTests.swift` case-for-case -
 * the same "empty means anonymous, half-set means anonymous" rule has to
 * hold on both platforms, or one adapter silently half-authenticates
 * where the other doesn't.
 */
class RelayCredentialsTest {
    @Test
    fun `a complete credential is used`() {
        assertEquals(
            RelayCredentials("admin", "hunter2"),
            RelayCredentials.make("admin", "hunter2"),
        )
    }

    /**
     * The committed adapter.properties ships both keys empty, so this is
     * the default state of any build without an untracked overlay -
     * meaning "connect anonymously", not "misconfigured".
     */
    @Test
    fun `both blank means anonymous`() {
        assertNull(RelayCredentials.make("", ""))
    }

    /**
     * Half-set is a misconfiguration that would otherwise produce a
     * confusing broker-side rejection, so it's treated as no credentials
     * rather than sent half-complete.
     */
    @Test
    fun `a username with no password is treated as no credentials`() {
        assertNull(RelayCredentials.make("admin", ""))
    }

    @Test
    fun `a password with no username is treated as no credentials`() {
        assertNull(RelayCredentials.make("", "hunter2"))
    }

    /** A properties file trivially picks up trailing whitespace. */
    @Test
    fun `surrounding whitespace is trimmed`() {
        assertEquals(
            RelayCredentials("admin", "hunter2"),
            RelayCredentials.make("  admin\n", "\thunter2 "),
        )
    }

    @Test
    fun `whitespace-only values count as blank`() {
        assertNull(RelayCredentials.make("   ", "   "))
    }

    /**
     * Passwords are arbitrary text and the generator escapes them into a
     * Kotlin string literal; nothing downstream should mangle them.
     */
    @Test
    fun `a password containing quotes and backslashes survives intact`() {
        val awkward = """p"a\ss"""
        assertEquals(awkward, RelayCredentials.make("admin", awkward)?.password)
    }
}
