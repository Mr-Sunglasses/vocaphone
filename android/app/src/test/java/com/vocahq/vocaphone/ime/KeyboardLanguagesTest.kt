package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.settings.VocaPhoneSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardLanguagesTest {
    /** Same alphabets iOS's KeyAlternativesTests checks. */
    private val alphabets = mapOf(
        "en" to "abcdefghijklmnopqrstuvwxyz",
        "es" to "abcdefghijklmnopqrstuvwxyzáéíóúüñ",
        "pt" to "abcdefghijklmnopqrstuvwxyzáâãàçéêíóôõú",
        "fr" to "abcdefghijklmnopqrstuvwxyzàâçéèêëîïôùûü",
        "de" to "abcdefghijklmnopqrstuvwxyzäöüß",
        "ru" to "абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
        "uk" to "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя",
    )

    @Test
    fun sameSevenLayoutsAsIos() {
        assertEquals(listOf("en", "es", "pt", "fr", "de", "ru", "uk"), KeyboardLanguages.catalogue.map { it.id })
    }

    @Test
    fun everyLetterOfEachLanguageIsOnAKeyOrBehindOne() {
        KeyboardLanguages.catalogue.forEach { layout ->
            val rows = KeyboardLayouts.rows(KeyboardLayer.LETTERS, KeyboardEditorConfig.empty(), layout = layout)
            val keys = rows.flatMap { it.keys }.filter { it.type == KeyboardKeyType.CHARACTER }
            val reachable = keys.flatMap { listOf(it.output) + KeyAccents.forKey(it, ShiftState.OFF, layout = layout) }.toSet()
            alphabets.getValue(layout.id).forEach { letter ->
                assertTrue("${layout.id} cannot type $letter", letter.toString() in reachable)
            }
        }
    }

    @Test
    fun arrangementsAreTheNativeOnes() {
        fun top(id: String) = KeyboardLanguages.layout(id)!!.rows.first()
        assertEquals("azertyuiop", top("fr"))
        assertEquals("qwertzuiop", top("de"))
        assertEquals("йцукенгшщзх", top("ru"))
        assertEquals("yxcvbnm", KeyboardLanguages.layout("de")!!.rows[2])
    }

    @Test
    fun languageAccentsComeFirst() {
        val french = KeyboardLanguages.layout("fr")!!
        val e = KeyboardKey("character-e", "e")
        assertEquals("é", KeyAccents.forKey(e, ShiftState.OFF, layout = french).first())
        val german = KeyboardLanguages.layout("de")!!
        assertEquals("ä", KeyAccents.forKey(KeyboardKey("character-a", "a"), ShiftState.OFF, layout = german).first())
        // ß has no single-letter capital, so a shifted hold leaves it out.
        assertFalse("SS" in KeyAccents.forKey(KeyboardKey("character-s", "s"), ShiftState.ONCE, layout = german))
    }

    @Test
    fun holdForSymbolsFollowsKeyPosition() {
        val french = KeyboardLanguages.layout("fr")!!
        val a = KeyboardKey("character-a", "a")
        assertEquals("1", KeyAccents.hint(a, longPressSymbols = true, layout = french))
        val q = KeyboardKey("character-q", "q")
        assertEquals("@", KeyAccents.hint(q, longPressSymbols = true, layout = french))
        assertEquals("1", KeyAccents.hint(q, longPressSymbols = true))
    }

    @Test
    fun aFreshInstallFollowsThePhonesLanguages() {
        assertEquals(listOf("en"), KeyboardLanguages.forPreferredLanguages(listOf("ja-JP")).map { it.id })
        assertEquals(listOf("en", "ru"), KeyboardLanguages.forPreferredLanguages(listOf("ru-RU", "en-GB")).map { it.id })
        assertEquals(listOf("en", "ru"), KeyboardLanguages.enabled(emptyList(), listOf("ru-RU", "en-US")).map { it.id })
        assertEquals(listOf("de"), KeyboardLanguages.enabled(listOf("de"), listOf("ru-RU")).map { it.id })
    }

    @Test
    fun anUpgradeOnANonEnglishPhoneKeepsEnglishFirst() {
        val derived = KeyboardLanguages.enabled(emptyList(), listOf("de-DE"))
        assertEquals(listOf("en", "de"), derived.map { it.id })
        // The stored active layout is empty on upgrade, so English is typed on.
        assertTrue(KeyboardLanguages.active("", derived).isEnglish)
        assertTrue(KeyboardLanguages.isEnglishLayout(VocaPhoneSettings(), listOf("de-DE")))
        // And the language key is there to reach German.
        assertEquals("de", KeyboardLanguages.next(derived.first(), derived)!!.id)
    }

    @Test
    fun nextWrapsAndIsNullWithOneLayout() {
        val layouts = KeyboardLanguages.enabled(listOf("en", "fr", "ru"), emptyList())
        val en = layouts[0]
        assertEquals("fr", KeyboardLanguages.next(en, layouts)!!.id)
        assertEquals("ru", KeyboardLanguages.next(en, layouts, forward = false)!!.id)
        assertEquals("en", KeyboardLanguages.next(layouts[2], layouts)!!.id)
        assertNull(KeyboardLanguages.next(en, listOf(en)))
    }

    @Test
    fun theLastLayoutCannotBeTurnedOff() {
        val only = KeyboardLanguages.enabled(listOf("es"), emptyList())
        assertEquals(listOf("es"), KeyboardLanguages.toggled(only, "es", on = false))
        assertEquals(listOf("en", "es"), KeyboardLanguages.toggled(only, "en", on = true))
    }

    @Test
    fun theEnglishFlagFollowsTheActiveLayout() {
        val settings = VocaPhoneSettings(keyboardLayouts = listOf("en", "es"), activeKeyboardLayout = "es")
        assertFalse(KeyboardLanguages.isEnglishLayout(settings, emptyList()))
        assertTrue(KeyboardLanguages.isEnglishLayout(settings.copy(activeKeyboardLayout = "en"), emptyList()))
        // A stored layout that was since turned off falls back to the first one on.
        assertTrue(KeyboardLanguages.isEnglishLayout(settings.copy(activeKeyboardLayout = "ru"), emptyList()))
    }

    @Test
    fun theLanguageKeyAndSpaceLabelAppearOnlyWithSeveralLayouts() {
        val editor = KeyboardEditorConfig.empty()
        val single = KeyboardLayouts.rows(KeyboardLayer.LETTERS, editor).last().keys
        assertFalse(single.any { it.type == KeyboardKeyType.LANGUAGE })
        assertNull(single.first { it.type == KeyboardKeyType.SPACE }.caption)
        val russian = KeyboardLanguages.layout("ru")!!
        val several = KeyboardLayouts.rows(KeyboardLayer.LETTERS, editor, layout = russian, languageKey = true).last().keys
        assertTrue(several.any { it.type == KeyboardKeyType.LANGUAGE })
        assertEquals("Русский", several.first { it.type == KeyboardKeyType.SPACE }.caption)
        // The bottom row keeps its total width.
        assertEquals(single.sumOf { it.weight.toDouble() }, several.sumOf { it.weight.toDouble() }, 0.01)
    }

    @Test
    fun lettersKeepOneWidthAcrossRows() {
        assertEquals(1.35f, KeyboardLayouts.sideKeyWeight(10, 7), 0.001f)
        assertEquals(1.85f, KeyboardLayouts.sideKeyWeight(10, 6), 0.001f)
        assertEquals(1f, KeyboardLayouts.sideKeyWeight(11, 9), 0.001f)
        val azerty = KeyboardLayouts.rows(KeyboardLayer.LETTERS, KeyboardEditorConfig.empty(), layout = KeyboardLanguages.layout("fr")!!)
        assertEquals(0f, azerty[1].leadingSpace, 0.001f)
        val qwerty = KeyboardLayouts.rows(KeyboardLayer.LETTERS, KeyboardEditorConfig.empty())
        assertEquals(0.5f, qwerty[1].leadingSpace, 0.001f)
    }

    @Test
    fun aSidewaysSwipeOnSpaceChangesLayoutOnce() {
        val g = spacebar(layoutSwipePx = 40f)
        assertEquals(0, g.move(120f, 50f, 50L).layout)
        assertEquals(1, g.move(150f, 52f, 80L).layout)
        assertEquals(0, g.move(220f, 52f, 120L).layout)
        assertFalse(g.armElapsed())
        // No space after a layout swipe.
        assertFalse(g.release())
    }

    @Test
    fun aLeftSwipeGoesBack() {
        val g = spacebar(layoutSwipePx = 40f)
        assertEquals(-1, g.move(50f, 50f, 60L).layout)
    }

    @Test
    fun aRollUpTowardTheLettersIsNotALayoutSwipe() {
        val g = spacebar(layoutSwipePx = 40f)
        assertEquals(0, g.move(150f, -10f, 60L).layout)
        assertTrue(g.release())
    }

    @Test
    fun aCursorDragAfterTheHoldNeverChangesLayout() {
        val g = spacebar(layoutSwipePx = 40f)
        assertTrue(g.armElapsed())
        val step = g.move(300f, 50f, 600L)
        assertEquals(0, step.layout)
        assertTrue(step.characters > 0)
    }

    @Test
    fun withOneLayoutASlideIsStillASpace() {
        val g = spacebar(layoutSwipePx = 0f)
        assertEquals(0, g.move(300f, 50f, 60L).layout)
        assertTrue(g.release())
    }

    @Test
    fun swipeDistanceIsAQuarterOfTheBarClamped() {
        assertEquals(28f, SpacebarGesture.layoutSwipePx(40f, 1f), 0.001f)
        assertEquals(40f, SpacebarGesture.layoutSwipePx(160f, 1f), 0.001f)
        assertEquals(88f, SpacebarGesture.layoutSwipePx(1_000f, 2f), 0.001f)
    }

    private fun spacebar(layoutSwipePx: Float) = SpacebarGesture(
        stepPx = 40f,
        lineStepPx = 60f,
        slopPx = 16f,
        pxPerDp = 1f,
        downX = 100f,
        downY = 50f,
        downTimeMs = 0L,
        layoutSwipePx = layoutSwipePx,
    )
}
