package com.vocahq.vocaphone.grammar

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * `assets/grammar/typed_fixtures.json`, which `TypedGrammarTests.swift` reads
 * too, so the two keyboards decide the same things about the same text.
 */
class TypedGrammarTest {
    private val document = JSONObject(File(GrammarFixtures.root, "typed_fixtures.json").readText())

    private fun cases(name: String) = document.getJSONArray(name).let { array ->
        List(array.length()) { array.getJSONObject(it) }
    }

    private fun JSONObject.stringOrNull(key: String): String? = if (isNull(key)) null else getString(key)

    @Test
    fun `region matches the shared cases`() {
        cases("region").forEach { case ->
            assertEquals(
                case.getString("name"),
                case.stringOrNull("region"),
                TypedGrammar.region(case.getString("before"), case.getBoolean("startKnown")),
            )
        }
    }

    @Test
    fun `fix matches the shared cases`() {
        cases("fix").forEach { case ->
            val name = case.getString("name")
            val fix = TypedGrammar.fix(case.getString("checked"), case.getString("corrected"))
            if (case.isNull("fix")) {
                assertNull(name, fix)
                return@forEach
            }
            val expected = case.getJSONObject("fix")
            assertNotNull(name, fix)
            assertEquals(name, expected.getString("corrected"), fix!!.corrected)
            assertEquals(name, expected.getInt("start"), fix.start)
            assertEquals(name, expected.getString("original"), fix.original)
            assertEquals(name, expected.getString("replacement"), fix.replacement)
            assertEquals(name, expected.getString("label"), fix.label)
        }
    }

    @Test
    fun `edit matches the shared cases`() {
        cases("edit").forEach { case ->
            val name = case.getString("name")
            val fix = TypedGrammar.fix(case.getString("checked"), case.getString("corrected"))
            assertNotNull(name, fix)
            val edit = TypedGrammar.edit(fix!!, case.getString("before"))
            if (case.isNull("edit")) {
                assertNull(name, edit)
                return@forEach
            }
            val expected = case.getJSONObject("edit")
            assertEquals(name, TypedGrammar.Edit(expected.getInt("deleteBefore"), expected.getString("insert")), edit)
        }
    }

    @Test
    fun `stillDescribes matches the shared cases`() {
        cases("stillDescribes").forEach { case ->
            val fix = TypedGrammar.fix(case.getString("checked"), case.getString("corrected"))!!
            assertEquals(case.getString("name"), case.getBoolean("expected"), TypedGrammar.stillDescribes(fix, case.getString("window")))
        }
    }

    /** Applying an edit to the text it was made for gives the corrected text. */
    @Test
    fun `every edit produces the corrected text`() {
        cases("edit").filter { !it.isNull("edit") }.forEach { case ->
            val before = case.getString("before")
            val fix = TypedGrammar.fix(case.getString("checked"), case.getString("corrected"))!!
            val edit = TypedGrammar.edit(fix, before)!!
            val after = before.dropLast(edit.deleteBefore) + edit.insert
            val trailing = before.substring(before.trimEnd().length)
            assertEquals(case.getString("name"), before.trimEnd().dropLast(fix.checked.length) + fix.corrected + trailing, after)
        }
    }

    @Test
    fun `a sentence longer than the limit is not checked`() {
        val long = "word ".repeat(TypedGrammar.MAX_REGION / 5 + 1).trim() + ". "
        assertNull(TypedGrammar.region(long, startKnown = true))
    }

    @Test
    fun `a long earlier sentence leaves the last one alone to check`() {
        val long = "word ".repeat(TypedGrammar.MAX_REGION / 5).trim() + "."
        assertEquals("They was late.", TypedGrammar.region("$long They was late. ", startKnown = true))
    }
}
