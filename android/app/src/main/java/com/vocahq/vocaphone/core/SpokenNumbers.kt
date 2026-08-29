package com.vocahq.vocaphone.core

import java.util.Locale

/**
 * Rewrites dictated English number words as digits: "six pm at the office"
 * becomes "6 pm at the office".
 *
 * This is deliberately conservative. Adjacent number words convert only when
 * the complete run is one valid number; a lone "one" needs a following unit;
 * and ordinals and spoken times stay exactly as the user said them. The word
 * lists are English-only, so text in other languages passes through unchanged.
 */
object SpokenNumbers {
    const val MAXIMUM = 999_999_999_999L

    private val quantifyingUnits = setOf(
        "am", "pm", "o'clock", "oclock",
        "hour", "hours", "hr", "hrs",
        "minute", "minutes", "min", "mins",
        "second", "seconds", "sec", "secs",
        "percent",
        "dollar", "dollars", "rupee", "rupees", "euro", "euros",
        "pound", "pounds", "cent", "cents",
        "kg", "kilo", "kilos", "kilogram", "kilograms",
        "gram", "grams", "km", "kilometre", "kilometres", "kilometer", "kilometers",
        "mile", "miles", "metre", "metres", "meter", "meters",
        "litre", "litres", "liter", "liters", "ml",
        "degree", "degrees", "star", "stars",
        "kb", "mb", "gb", "tb", "mph", "kmph",
    )

    private val ordinalWords = setOf(
        "first", "third", "fourth", "fifth", "sixth", "seventh", "eighth",
        "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth",
        "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth",
        "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth",
        "seventieth", "eightieth", "ninetieth", "hundredth", "thousandth", "millionth",
    )

    private val wordPattern = Regex("[A-Za-z]+(?:['’][A-Za-z]+)*")

    /** Converts only number phrases that can be parsed without guessing. */
    fun digitsIn(text: String): String {
        if (text.isEmpty()) return text
        val words = wordPattern.findAll(text).toList()
        if (words.isEmpty()) return text

        val result = StringBuilder()
        var copied = 0
        var index = 0
        while (index < words.size) {
            val first = wordFor(words[index].value)
            if (first?.opensANumber != true) {
                index += 1
                continue
            }

            val tokens = mutableListOf(first)
            var last = index
            while (
                last + 1 < words.size &&
                isJoiner(last, words, text)
            ) {
                val next = wordFor(words[last + 1].value) ?: break
                if (!next.mayExtend(tokens)) break
                tokens += next
                last += 1
            }
            while (tokens.lastOrNull()?.isConnector == true) {
                tokens.removeAt(tokens.lastIndex)
                last -= 1
            }

            val phrase = tokens.takeIf { it.isNotEmpty() }?.let(::parse)
            if (phrase == null || !isWorthConverting(tokens, last, words, text)) {
                // Keep an invalid run whole rather than converting pieces of it.
                index = last + 1
                continue
            }

            result.append(text, copied, words[index].range.first)
            result.append(phrase.formatted)
            copied = words[last].range.last + 1
            index = last + 1
        }
        result.append(text, copied, text.length)
        return result.toString()
    }

    private fun isWorthConverting(
        tokens: List<Token>,
        last: Int,
        words: List<MatchResult>,
        text: String,
    ): Boolean {
        val following = words.getOrNull(last + 1)?.let { next ->
            next.value.lowercase(Locale.ROOT) to text.substring(words[last].range.last + 1, next.range.first)
        }
        if (following != null && following.second in setOf(" ", "-", "‑") &&
            following.first in ordinalWords
        ) return false

        if (tokens != listOf(UnitValue(1))) return true
        return following?.let { (word, gap) -> gap == " " && word in quantifyingUnits } == true
    }

    private fun isJoiner(index: Int, words: List<MatchResult>, text: String): Boolean {
        val gap = text.substring(words[index].range.last + 1, words[index + 1].range.first)
        return gap == " " || gap == "-" || gap == "‑"
    }

    private sealed interface Token {
        val opensANumber: Boolean
        val isConnector: Boolean get() = false
        fun mayExtend(tokens: List<Token>): Boolean = when (this) {
            And -> tokens.lastOrNull() is Hundred || tokens.lastOrNull() is Scale
            Point -> tokens.lastOrNull()?.isConnector == false
            else -> true
        }
    }

    private data class UnitValue(val value: Int) : Token { override val opensANumber = true }
    private data class Teen(val value: Int) : Token { override val opensANumber = true }
    private data class Tens(val value: Int) : Token { override val opensANumber = true }
    private data object Hundred : Token { override val opensANumber = false }
    private data class Scale(val value: Long) : Token { override val opensANumber = false }
    private data object And : Token {
        override val opensANumber = false
        override val isConnector = true
    }
    private data object Point : Token {
        override val opensANumber = false
        override val isConnector = true
    }

    private data class Phrase(val value: Long, val decimals: String) {
        val formatted: String get() = if (decimals.isEmpty()) "$value" else "$value.$decimals"
    }

    private fun wordFor(text: String): Token? = when (text.lowercase(Locale.ROOT)) {
        "zero" -> UnitValue(0)
        "one" -> UnitValue(1)
        "two" -> UnitValue(2)
        "three" -> UnitValue(3)
        "four" -> UnitValue(4)
        "five" -> UnitValue(5)
        "six" -> UnitValue(6)
        "seven" -> UnitValue(7)
        "eight" -> UnitValue(8)
        "nine" -> UnitValue(9)
        "ten" -> Teen(10)
        "eleven" -> Teen(11)
        "twelve" -> Teen(12)
        "thirteen" -> Teen(13)
        "fourteen" -> Teen(14)
        "fifteen" -> Teen(15)
        "sixteen" -> Teen(16)
        "seventeen" -> Teen(17)
        "eighteen" -> Teen(18)
        "nineteen" -> Teen(19)
        "twenty" -> Tens(20)
        "thirty" -> Tens(30)
        "forty", "fourty" -> Tens(40)
        "fifty" -> Tens(50)
        "sixty" -> Tens(60)
        "seventy" -> Tens(70)
        "eighty" -> Tens(80)
        "ninety" -> Tens(90)
        "hundred" -> Hundred
        "thousand" -> Scale(1_000)
        "million" -> Scale(1_000_000)
        "billion" -> Scale(1_000_000_000)
        "and" -> And
        "point" -> Point
        else -> null
    }

    private fun parse(tokens: List<Token>): Phrase? {
        var total = 0L
        var group = 0L
        val decimals = StringBuilder()
        var isDecimal = false
        var smallestScale = Long.MAX_VALUE
        var previous: Token? = null

        for (token in tokens) {
            if (!mayFollow(previous, token, isDecimal)) return null
            when (token) {
                is UnitValue -> if (isDecimal) decimals.append(token.value) else group += token.value
                is Teen -> group += token.value
                is Tens -> group += token.value
                Hundred -> group *= 100
                is Scale -> {
                    if (group <= 0 || token.value >= smallestScale) return null
                    smallestScale = token.value
                    total += group * token.value
                    group = 0
                }
                And -> Unit
                Point -> isDecimal = true
            }
            previous = token
        }

        if (isDecimal && decimals.isEmpty()) return null
        val value = total + group
        if (value > MAXIMUM) return null
        return Phrase(value, decimals.toString())
    }

    private fun mayFollow(previous: Token?, token: Token, isDecimal: Boolean): Boolean {
        if (isDecimal) return token is UnitValue
        return when (previous) {
            null -> token.opensANumber
            is UnitValue -> when (token) {
                Hundred, is Scale -> previous.value > 0
                Point -> true
                else -> false
            }
            is Teen -> token == Hundred || token is Scale || token == Point
            is Tens -> when (token) {
                is UnitValue -> token.value > 0
                is Scale, Point -> true
                else -> false
            }
            Hundred -> when (token) {
                is UnitValue -> token.value > 0
                is Teen, is Tens, is Scale, And, Point -> true
                else -> false
            }
            is Scale -> when (token) {
                is UnitValue -> token.value > 0
                is Teen, is Tens, is Scale, And, Point -> true
                else -> false
            }
            And -> when (token) {
                is UnitValue -> token.value > 0
                is Teen, is Tens -> true
                else -> false
            }
            Point -> token is UnitValue
        }
    }
}
