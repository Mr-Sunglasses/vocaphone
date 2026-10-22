package com.vocahq.vocaphone.grammar

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Android's regex engine rejects `(?U)` (UNICODE_CHARACTER_CLASS), which the
 * desktop JVM running this suite accepts, so a pattern using it passes every
 * unit test and throws on every phone. GrammarTaggerDeviceTest checks the real
 * engine; this keeps the flag out of the grammar package in CI.
 */
class GrammarRegexPortabilityTest {
    @Test
    fun noGrammarPatternUsesTheUnicodeCharacterClassFlag() {
        val sources = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "src/main/java/com/vocahq/vocaphone/grammar") }
            .first { it.isDirectory }
        val offenders = sources.walk().filter { it.extension == "kt" }.flatMap { file ->
            file.readLines().withIndex()
                .filter { (_, line) -> !line.trimStart().startsWith("*") && !line.trimStart().startsWith("//") }
                .filter { (_, line) -> "(?U)" in line || "UNICODE_CHARACTER_CLASS" in line }
                .map { (n, _) -> "${file.name}:${n + 1}" }
        }.toList()
        assertEquals(emptyList<String>(), offenders)
    }
}
