package com.vocahq.vocaphone.ime

import com.vocahq.vocaphone.core.Snippet
import java.math.BigDecimal
import java.math.MathContext
import java.math.RoundingMode
import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.util.Locale

/**
 * Chips that lead the strip because of what is right before the cursor: a
 * snippet trigger just typed, or a sum ending in `=`. Pure and cheap: a few
 * string comparisons per snippet, no word list.
 */
internal object TypingChips {
    fun extras(before: String, composing: String, snippets: List<Snippet>): List<SuggestionItem> {
        val text = SuggestionEngine.beforeComposing(before, composing) + composing
        return buildList {
            TypedSnippets.match(text, snippets)?.let { (trigger, snippet) ->
                add(SuggestionItem(snippet.expansion, kind = SuggestionKind.SNIPPET, replaces = trigger))
            }
            if (composing.isEmpty()) {
                QuickMath.resultFor(text)?.let { add(SuggestionItem(it, kind = SuggestionKind.RESULT)) }
            }
        }
    }
}

/**
 * The user's snippets (the ones dictation expands), offered while typing: when
 * the text right before the cursor is a trigger, its expansion is a chip, and
 * tapping it replaces the trigger. Nothing is expanded without the tap.
 */
internal object TypedSnippets {
    /** The trigger as typed and its snippet, or null. The longest trigger wins. */
    fun match(text: String, snippets: List<Snippet>): Pair<String, Snippet>? {
        if (text.isEmpty() || text.last().isWhitespace()) return null
        var best: Pair<String, Snippet>? = null
        for (snippet in snippets) {
            val trigger = snippet.trigger.trim()
            if (trigger.isEmpty() || snippet.expansion.isBlank() || trigger.length > text.length) continue
            if (!text.endsWith(trigger, ignoreCase = true)) continue
            val start = text.length - trigger.length
            // A whole trigger, not the end of a longer word: "brb" in "brb", not in "xbrb".
            if (start > 0 && isWordChar(text[start - 1]) && isWordChar(trigger.first())) continue
            if (best == null || trigger.length > best.first.length) best = text.substring(start) to snippet
        }
        return best
    }

    private fun isWordChar(character: Char): Boolean = character.isLetterOrDigit() || character == '_'
}

/**
 * The answer to a sum typed before the cursor and ended with `=`: `12*4=`,
 * `1,200/3=`, `(2+3)x4=`. Integers and decimals, `+ - * x × / ÷`, brackets;
 * nothing else — no units, no currency, no functions. The result is plain,
 * without a trailing `.0`, grouped with commas only when the sum was.
 */
internal object QuickMath {
    private const val MAX_LENGTH = 64
    private const val SCALE = 10
    private const val EXPRESSION_CHARS = "0123456789.,+-*/x×÷() "

    fun resultFor(before: String): String? {
        if (!before.endsWith("=")) return null
        val body = before.dropLast(1)
        var start = body.length
        while (start > 0 && body[start - 1] in EXPRESSION_CHARS && body.length - start < MAX_LENGTH) start--
        // The sum starts at a number, a bracket or a minus: "x 2x3" is "box 2x3" cut short.
        while (start < body.length && !(body[start].isDigit() || body[start] == '(' || body[start] == '-')) start++
        if (start >= body.length) return null
        // A sum on its own: not "v1.2", "$5" or "5km" cut short.
        if (start > 0 && !(body[start - 1].isWhitespace() || body[start - 1] in "([{")) return null
        val expression = body.substring(start).trim()
        return evaluate(expression)?.let { format(it, grouped = ',' in expression) }
    }

    /** The value of [expression], or null when it is not a sum this understands. */
    fun evaluate(expression: String): BigDecimal? {
        if (expression.isEmpty() || expression.length > MAX_LENGTH) return null
        val parser = Parser(expression)
        return runCatching { parser.parse() }.getOrNull()?.takeIf { parser.sawOperator }
    }

    fun format(value: BigDecimal, grouped: Boolean): String {
        val rounded = value.setScale(SCALE, RoundingMode.HALF_UP).stripTrailingZeros()
        val plain = if (rounded.signum() == 0) BigDecimal.ZERO else rounded
        if (!grouped) return plain.toPlainString()
        val pattern = DecimalFormat("#,##0.##########", DecimalFormatSymbols(Locale.US))
        return pattern.format(plain)
    }

    private class Parser(private val text: String) {
        private var index = 0
        var sawOperator = false
            private set

        fun parse(): BigDecimal {
            val value = expression()
            skipSpaces()
            require(index == text.length)
            return value
        }

        private fun expression(): BigDecimal {
            var value = term()
            while (true) {
                skipSpaces()
                val operator = peek() ?: return value
                if (operator != '+' && operator != '-') return value
                index++
                sawOperator = true
                val right = term()
                value = if (operator == '+') value.add(right) else value.subtract(right)
            }
        }

        private fun term(): BigDecimal {
            var value = factor()
            while (true) {
                skipSpaces()
                val operator = peek() ?: return value
                if (operator !in "*/x×÷") return value
                index++
                sawOperator = true
                val right = factor()
                value = if (operator == '/' || operator == '÷') {
                    require(right.signum() != 0)
                    value.divide(right, MathContext.DECIMAL128)
                } else {
                    value.multiply(right)
                }
            }
        }

        private fun factor(): BigDecimal {
            skipSpaces()
            return when (peek()) {
                '-' -> {
                    index++
                    factor().negate()
                }
                '(' -> {
                    index++
                    val value = expression()
                    skipSpaces()
                    require(peek() == ')')
                    index++
                    value
                }
                else -> number()
            }
        }

        /** Digits, commas only as thousands separators ("1,200"), and one decimal point. */
        private fun number(): BigDecimal {
            val start = index
            var groupDigits = 0
            var grouped = false
            while (index < text.length && (text[index].isDigit() || text[index] == ',')) {
                if (text[index] == ',') {
                    require(if (grouped) groupDigits == 3 else groupDigits in 1..3)
                    grouped = true
                    groupDigits = 0
                } else {
                    groupDigits++
                }
                index++
            }
            require(groupDigits > 0 && (!grouped || groupDigits == 3))
            if (index < text.length && text[index] == '.') {
                index++
                val fraction = index
                while (index < text.length && text[index].isDigit()) index++
                require(index > fraction)
            }
            if (index < text.length) require(text[index] !in "0123456789.,")
            return BigDecimal(text.substring(start, index).replace(",", ""))
        }

        private fun peek(): Char? = text.getOrNull(index)

        private fun skipSpaces() {
            while (index < text.length && text[index] == ' ') index++
        }
    }
}
