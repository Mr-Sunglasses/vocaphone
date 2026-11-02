package com.vocahq.vocaphone.spell

import com.vocahq.vocaphone.writing.WritingCategory
import com.vocahq.vocaphone.writing.WritingCheck
import com.vocahq.vocaphone.writing.WritingFixtures
import org.junit.Assert.assertEquals
import org.junit.Test

class SpellCheckSpansTest {
    private val check = WritingCheck(WritingFixtures.rules, WritingFixtures.spelling, WritingFixtures.tagger)

    private fun spans(text: String, model: Map<String, String> = emptyMap()): List<String> {
        val report = check.check(
            text,
            WritingCheck.Model { model[it] ?: it },
            WritingCheck.Options(setOf(WritingCategory.CORRECTNESS)),
        )
        return SpellCheckSpans.of(text, report).filter { it.kind != SpellCheckSpans.Kind.FINE }.map {
            "${it.kind} ${text.substring(it.offset, it.offset + it.length)} → ${it.suggestions.single()}"
        }
    }

    @Test
    fun `a replaced word is its own span`() {
        assertEquals(listOf("GRAMMAR don't → doesn't"), spans("He don't know.", mapOf("He don't know." to "He doesn't know.")))
    }

    @Test
    fun `a misspelling is drawn as a typo`() {
        assertEquals(listOf("TYPO definately → definitely"), spans("I definately agree."))
    }

    @Test
    fun `an added word rides on the word before it`() {
        assertEquals(listOf("GRAMMAR I → I am"), spans("I going home.", mapOf("I going home." to "I am going home.")))
    }

    @Test
    fun `a removed word takes the word before it along`() {
        assertEquals(listOf("GRAMMAR the the → the"), spans("I saw the the cat."))
    }

    @Test
    fun `every other word is reported fine, so old underlines clear`() {
        val report = check.check("Fine words here.", null, WritingCheck.Options(setOf(WritingCategory.CORRECTNESS)))
        val all = SpellCheckSpans.of("Fine words here.", report)
        assertEquals(listOf("Fine", "words", "here"), all.map { "Fine words here.".substring(it.offset, it.offset + it.length) })
        assertEquals(setOf(SpellCheckSpans.Kind.FINE), all.map { it.kind }.toSet())
    }

    @Test
    fun `style suggestions are not underlined system-wide`() {
        val report = check.check("This is a free gift.")
        assertEquals(emptyList<SpellCheckSpans.Span>(), SpellCheckSpans.of("This is a free gift.", report).filter { it.kind != SpellCheckSpans.Kind.FINE })
    }
}
