package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Test

class SnippetExpanderTest {

    @Test
    fun `no snippets leaves text unchanged`() {
        assertEquals(
            "call me later",
            SnippetExpander.expand("call me later", emptyList()),
        )
    }

    @Test
    fun `blank triggers are ignored`() {
        val snippets = listOf(Snippet("1", "   ", "nope"))
        assertEquals("hello world", SnippetExpander.expand("hello world", snippets))
    }

    /** A blank expansion must leave the trigger alone, not delete it. */
    @Test
    fun `blank expansions are ignored`() {
        val snippets = listOf(Snippet("1", "brb", "   "))
        assertEquals("brb in five", SnippetExpander.expand("brb in five", snippets))
    }

    @Test
    fun `matching is case insensitive`() {
        val snippets = listOf(Snippet("1", "brb", "be right back"))
        assertEquals(
            "be right back, getting coffee",
            SnippetExpander.expand("BRB, getting coffee", snippets),
        )
    }

    @Test
    fun `word triggers only match on word boundaries`() {
        val snippets = listOf(Snippet("1", "addr", "123 Main St"))
        assertEquals(
            "send to 123 Main St please",
            SnippetExpander.expand("send to addr please", snippets),
        )
        // "address" contains "addr" but is not a boundary match.
        assertEquals(
            "my address is unlisted",
            SnippetExpander.expand("my address is unlisted", snippets),
        )
    }

    @Test
    fun `punctuation only triggers match at string edges`() {
        val snippets = listOf(Snippet("1", "->", "results in"))
        assertEquals(
            "results in success",
            SnippetExpander.expand("-> success", snippets),
        )
        assertEquals(
            "a results in b",
            SnippetExpander.expand("a -> b", snippets),
        )
    }

    @Test
    fun `longer trigger wins over a shorter substring trigger`() {
        val snippets = listOf(
            Snippet("1", "email", "user@example.com"),
            Snippet("2", "my email", "kanishk@example.com"),
        )
        assertEquals(
            "send to kanishk@example.com now",
            SnippetExpander.expand("send to my email now", snippets),
        )
    }

    @Test
    fun `an expansion containing another trigger is not re-expanded`() {
        val snippets = listOf(
            Snippet("1", "sig", "Thanks, my email is contact"),
            Snippet("2", "contact", "hello@example.com"),
        )
        assertEquals(
            "Thanks, my email is contact",
            SnippetExpander.expand("sig", snippets),
        )
    }

    /**
     * The boundary class is spelled out instead of using `\b` so that this
     * passes for the same reason on the desktop JVM and on a phone: `\b` reads
     * ASCII-only `\w` here and Unicode `\w` in Android's ICU engine, so a
     * green test would say nothing about the device.
     */
    @Test
    fun `a non-ASCII trigger matches`() {
        val snippets = listOf(Snippet("1", "büro", "the office"))
        assertEquals(
            "meet me at the office later",
            SnippetExpander.expand("meet me at büro later", snippets),
        )
    }

    @Test
    fun `a non-ASCII trigger does not match inside a longer word`() {
        val snippets = listOf(Snippet("1", "büro", "the office"))
        assertEquals(
            "the bürogebäude is closed",
            SnippetExpander.expand("the bürogebäude is closed", snippets),
        )
    }

    @Test
    fun `a non-Latin script trigger matches`() {
        val snippets = listOf(Snippet("1", "पता", "221B Baker Street"))
        assertEquals(
            "भेजें 221B Baker Street पर",
            SnippetExpander.expand("भेजें पता पर", snippets),
        )
    }

    @Test
    fun `case folding applies to non-ASCII triggers`() {
        val snippets = listOf(Snippet("1", "über", "above"))
        assertEquals("above all", SnippetExpander.expand("ÜBER all", snippets))
    }

    @Test
    fun `trigger whitespace is ignored when matching`() {
        val snippets = listOf(Snippet("1", "  brb  ", "be right back"))
        assertEquals(
            "be right back everyone",
            SnippetExpander.expand("brb everyone", snippets),
        )
    }

    @Test
    fun `multiple matches are replaced without shifting earlier ranges`() {
        val snippets = listOf(
            Snippet("1", "brb", "be right back"),
            Snippet("2", "omw", "on my way"),
        )
        assertEquals(
            "on my way, be right back soon",
            SnippetExpander.expand("omw, brb soon", snippets),
        )
    }
}
