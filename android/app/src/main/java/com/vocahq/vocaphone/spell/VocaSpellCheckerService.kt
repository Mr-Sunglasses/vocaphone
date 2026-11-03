package com.vocahq.vocaphone.spell

import android.service.textservice.SpellCheckerService
import android.view.textservice.SentenceSuggestionsInfo
import android.view.textservice.SuggestionsInfo
import android.view.textservice.TextInfo
import com.vocahq.vocaphone.VocaPhoneApplication
import com.vocahq.vocaphone.core.CustomVocabulary
import com.vocahq.vocaphone.core.DictatedTranscript
import com.vocahq.vocaphone.ime.PersonalDictionary
import com.vocahq.vocaphone.local.GrammarModelCatalog
import com.vocahq.vocaphone.writing.WritingCategory
import com.vocahq.vocaphone.writing.WritingCheck
import com.vocahq.vocaphone.writing.WritingLanguage
import kotlinx.coroutines.runBlocking

/**
 * VocaPhone as Android's spell checker: Writing check's correctness
 * suggestions underlined in any app's text field, with any keyboard, once the
 * user picks VocaPhone under the system's spell checker setting. The field
 * draws the underline and offers the fix on tap; nothing leaves the phone.
 *
 * It runs in the app's own process, so it shares the downloaded grammar model
 * with the keyboard and dictation. Only correctness is reported: a system-wide
 * underline is for mistakes, not for style. The framework asks a sentence at a
 * time, a few hundred milliseconds after the user stops typing, on its own
 * binder threads.
 *
 * The session's locale only says which checker the user picked, not what a
 * given message is written in, so each text the framework hands over is also
 * asked [WritingLanguage.applies] before the English rules see it.
 */
class VocaSpellCheckerService : SpellCheckerService() {
    private val container by lazy { VocaPhoneApplication.container(this) }

    private val checker get() = container.writingCheck

    private fun isEnglish(text: String): Boolean =
        WritingLanguage.typedEnglish(text, { it in container.englishWords }, checker?.spelling)

    override fun createSession(): Session = WritingSession()

    private inner class WritingSession : Session() {
        private var english = true

        override fun onCreate() {
            english = locale.isNullOrEmpty() || locale.startsWith("en")
        }

        override fun onGetSuggestions(textInfo: TextInfo, suggestionsLimit: Int): SuggestionsInfo {
            val spans = check(textInfo.text)
            val word = spans.firstOrNull { it.kind != SpellCheckSpans.Kind.FINE && it.offset == 0 && it.length == textInfo.text.length }
            return info(word, textInfo)
        }

        override fun onGetSentenceSuggestionsMultiple(
            textInfos: Array<out TextInfo>,
            suggestionsLimit: Int,
        ): Array<SentenceSuggestionsInfo> = textInfos.map { textInfo ->
            val spans = check(textInfo.text)
            SentenceSuggestionsInfo(
                spans.map { info(it, textInfo) }.toTypedArray(),
                spans.map { it.offset }.toIntArray(),
                spans.map { it.length }.toIntArray(),
            )
        }.toTypedArray()

        private fun check(text: String): List<SpellCheckSpans.Span> {
            val checker = checker
            if (!english || checker == null || text.isBlank()) return emptyList()
            // The language is asked of the whole text the framework sent, the
            // same text the rules check: the decision and the underlines are
            // about the same words.
            return SpellCheckSpans.checked(text, ::isEnglish) { report(checker, text) }
        }

        private fun report(checker: WritingCheck, text: String): WritingCheck.Report {
            val settings = runBlocking { container.settings.current() }
            val keep = DictatedTranscript.grammarKeeps(
                PersonalDictionary.terms(settings.personalDictionary) + CustomVocabulary.terms(settings.customVocabulary),
                settings.snippets,
            )
            val model = if (GrammarModelCatalog.available && container.grammarModel.isReady()) {
                WritingCheck.Model { sentence -> container.grammar.correctTyped(sentence, keep) }
            } else {
                null
            }
            val options = WritingCheck.Options(setOf(WritingCategory.CORRECTNESS), keep, typed = true)
            return ModelWait.check(
                check = { checker.check(text, model, options) },
                loading = { container.grammar.isLoading },
                loaded = { container.grammar.isLoaded },
            )
        }

        private fun info(span: SpellCheckSpans.Span?, textInfo: TextInfo): SuggestionsInfo {
            val attributes = when (span?.kind) {
                null, SpellCheckSpans.Kind.FINE -> SuggestionsInfo.RESULT_ATTR_IN_THE_DICTIONARY
                SpellCheckSpans.Kind.TYPO -> SuggestionsInfo.RESULT_ATTR_LOOKS_LIKE_TYPO or
                    SuggestionsInfo.RESULT_ATTR_HAS_RECOMMENDED_SUGGESTIONS
                SpellCheckSpans.Kind.GRAMMAR -> SuggestionsInfo.RESULT_ATTR_LOOKS_LIKE_GRAMMAR_ERROR or
                    SuggestionsInfo.RESULT_ATTR_HAS_RECOMMENDED_SUGGESTIONS
            }
            return SuggestionsInfo(attributes, span?.suggestions.orEmpty().toTypedArray(), textInfo.cookie, textInfo.sequence)
        }
    }
}
