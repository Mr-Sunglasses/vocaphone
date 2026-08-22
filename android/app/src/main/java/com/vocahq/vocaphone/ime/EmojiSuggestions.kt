package com.vocahq.vocaphone.ime

/**
 * Emoji offered for a word as it is typed: "lol" offers 😂.
 *
 * A curated table, not a lookup into [EmojiCatalog]. The catalog's keywords
 * exist for a deliberate search in the emoji panel. Matched against ordinary
 * prose they answer "the" with 🤣, "dog" with 💩, and "clock" with 🏫.
 *
 * Exact whole words first. A unique, almost-finished prefix (`pizz` → pizza)
 * and a unique one-letter insert or delete (`piza` → pizza) are the only
 * fuzzy paths, and only when they collapse to a single glyph. Substitution
 * is out: `read` is one edit from `dead`, and offering 💀 for "read" is
 * the strip crying wolf.
 */
internal object EmojiSuggestions {
    const val MINIMUM_LENGTH = 2

    /** Prefix and insert/delete matching start here. Three letters are too ambiguous. */
    const val FUZZY_MIN_LENGTH = 4

    /**
     * How much of the trigger may still be untyped for a prefix to count.
     * `pizz` (one short of pizza) is a finish; `read` (three short of reading)
     * is just the word "read".
     */
    const val PREFIX_SLACK = 2

    fun glyph(word: String): String? = glyphs(word).firstOrNull()

    fun glyphs(word: String): List<String> {
        val key = word.lowercase()
        if (key.length < MINIMUM_LENGTH) return emptyList()
        val primary = resolvePrimary(key) ?: return emptyList()
        return (listOf(primary) + EXTRAS[primary].orEmpty()).distinct()
    }

    private fun resolvePrimary(key: String): String? {
        TRIGGERS[key]?.let { return it }
        if (key.length < FUZZY_MIN_LENGTH) return null

        val prefixGlyphs = LinkedHashSet<String>()
        for ((trigger, glyph) in TRIGGERS) {
            if (
                trigger.length > key.length &&
                trigger.startsWith(key) &&
                key.length >= trigger.length - PREFIX_SLACK
            ) {
                prefixGlyphs.add(glyph)
                if (prefixGlyphs.size > 1) return null
            }
        }
        if (prefixGlyphs.size == 1) return prefixGlyphs.first()
        if (prefixGlyphs.isNotEmpty()) return null

        val fuzzyGlyphs = LinkedHashSet<String>()
        val scratch = SuggestionEngine.EditDistanceScratch(key.length + 1)
        for ((trigger, glyph) in TRIGGERS) {
            if (kotlin.math.abs(trigger.length - key.length) != 1) continue
            // A leading extra letter is how "they" becomes "hey". Trailing or
            // mid-word inserts are typos of the trigger itself (`piza` / `pizza`).
            if (isLeadingExtraLetter(key, trigger)) continue
            if (SuggestionEngine.editDistance(key, trigger, max = 1, scratch = scratch) != 1) continue
            fuzzyGlyphs.add(glyph)
            if (fuzzyGlyphs.size > 1) return null
        }
        return fuzzyGlyphs.singleOrNull()
    }

    private fun isLeadingExtraLetter(left: String, right: String): Boolean {
        val (shorter, longer) = if (left.length < right.length) left to right else right to left
        return longer.length == shorter.length + 1 && longer.endsWith(shorter)
    }

    internal val TRIGGERS: Map<String, String> = mapOf(
        "lol" to "😂", "lmao" to "🤣", "rofl" to "🤣", "haha" to "😂", "hehe" to "😄",
        "funny" to "😂", "omg" to "😱", "wow" to "😮", "yay" to "🎉", "oops" to "🙈",
        "ugh" to "😩", "meh" to "😐", "cool" to "😎", "nice" to "👍", "awesome" to "🤩",
        "amazing" to "🤩", "perfect" to "👌", "done" to "✅", "agree" to "👍",
        "congrats" to "🎉", "congratulations" to "🎉", "welcome" to "🤗",

        "love" to "❤️", "loved" to "❤️", "heart" to "❤️", "happy" to "😊", "sad" to "😢",
        "cry" to "😭", "crying" to "😭", "angry" to "😠", "mad" to "😠", "tired" to "😴",
        "sleepy" to "😴", "sleep" to "😴", "sick" to "🤒", "scared" to "😱",
        "confused" to "😕", "bored" to "🥱", "excited" to "🤩", "shy" to "😊",
        "hungry" to "😋", "thirsty" to "🥤", "stressed" to "😰", "relieved" to "😌",

        "hi" to "👋", "hello" to "👋", "hey" to "👋", "bye" to "👋", "goodbye" to "👋",
        "thanks" to "🙏", "thankyou" to "🙏", "please" to "🙏", "sorry" to "😔",
        "hug" to "🤗", "hugs" to "🤗", "kiss" to "😘", "wink" to "😉",

        "ok" to "👌", "okay" to "👌", "clap" to "👏", "applause" to "👏", "bravo" to "👏",
        "wave" to "👋", "pray" to "🙏", "prayers" to "🙏", "muscle" to "💪",
        "strong" to "💪", "facepalm" to "🤦", "shrug" to "🤷", "thinking" to "🤔",
        "eyes" to "👀", "brain" to "🧠",

        "fire" to "🔥", "lit" to "🔥", "skull" to "💀", "ghost" to "👻", "alien" to "👽",
        "robot" to "🤖", "poop" to "💩", "party" to "🎉", "birthday" to "🎂",
        "cake" to "🎂", "gift" to "🎁", "present" to "🎁", "balloon" to "🎈",
        "fireworks" to "🎆", "crown" to "👑", "diamond" to "💎", "trophy" to "🏆",
        "winner" to "🏆", "medal" to "🥇", "idea" to "💡", "bug" to "🐛",
        "warning" to "⚠️", "rocket" to "🚀",

        "pizza" to "🍕", "burger" to "🍔", "fries" to "🍟", "coffee" to "☕",
        "tea" to "🍵", "beer" to "🍺", "wine" to "🍷", "water" to "💧",
        "breakfast" to "🥞", "lunch" to "🍽️", "dinner" to "🍽️", "snack" to "🍿",
        "chocolate" to "🍫", "cookie" to "🍪", "icecream" to "🍦", "apple" to "🍎",
        "banana" to "🍌", "biryani" to "🍛", "chai" to "🍵",

        "dog" to "🐶", "puppy" to "🐶", "cat" to "🐱", "kitten" to "🐱", "bird" to "🐦",
        "fish" to "🐟", "tree" to "🌳", "flower" to "🌸", "rose" to "🌹",
        "sun" to "☀️", "sunny" to "☀️", "moon" to "🌙", "star" to "⭐",
        "rain" to "🌧️", "rainy" to "🌧️", "snow" to "❄️", "storm" to "⛈️",
        "rainbow" to "🌈", "beach" to "🏖️",

        "home" to "🏠", "house" to "🏠", "office" to "🏢", "school" to "🏫",
        "hospital" to "🏥", "bank" to "🏦", "gym" to "🏋️", "workout" to "🏋️",
        "running" to "🏃", "walk" to "🚶", "travel" to "✈️", "vacation" to "✈️",
        "holiday" to "✈️", "flight" to "✈️", "plane" to "✈️", "airport" to "✈️",
        "car" to "🚗", "train" to "🚆", "bike" to "🚲", "shopping" to "🛒",
        "money" to "💰", "cash" to "💰", "salary" to "💰",

        "music" to "🎵", "song" to "🎵", "book" to "📚", "reading" to "📚",
        "phone" to "📱", "laptop" to "💻", "computer" to "💻", "email" to "📧",
        "mail" to "📧", "calendar" to "📅", "meeting" to "🗓️", "deadline" to "⏰",
        "clock" to "⏰", "alarm" to "⏰", "camera" to "📷", "photo" to "📷",
        "movie" to "🎬", "game" to "🎮", "gaming" to "🎮", "art" to "🎨",
        "football" to "⚽", "cricket" to "🏏", "basketball" to "🏀",

        "christmas" to "🎄", "halloween" to "🎃", "diwali" to "🪔",

        // Extra doors into the same glyphs. Gemoji / chat short names, not
        // catalog keywords: each one should still mean that emoji.
        "laugh" to "😂", "laughing" to "😂", "joy" to "😂",
        "grin" to "😄", "grinning" to "😄",
        "smile" to "😊", "smiling" to "😊", "blush" to "😊",
        "unhappy" to "😢", "upset" to "😢", "tear" to "😢",
        "sob" to "😭", "tears" to "😭",
        "annoyed" to "😠", "pissed" to "😠",
        "sleeping" to "😴", "zzz" to "😴", "exhausted" to "😴", "nap" to "😴",
        "yawn" to "🥱", "yawning" to "🥱",
        "ill" to "🤒", "unwell" to "🤒",
        "scream" to "😱", "shocked" to "😱",
        "nervous" to "😰", "worried" to "😰",
        "weary" to "😩",
        "whew" to "😌",
        "starstruck" to "🤩",
        "ily" to "❤️",
        "xoxo" to "😘",
        "thx" to "🙏", "ty" to "🙏", "thank" to "🙏", "pls" to "🙏",
        "tada" to "🎉", "hooray" to "🎉",
        "smh" to "🤦",
        "idk" to "🤷", "dunno" to "🤷",
        "think" to "🤔",
        "flex" to "💪",
        "thumbsup" to "👍",
        "howdy" to "👋", "cya" to "👋",
        "flame" to "🔥", "burn" to "🔥",
        "dead" to "💀",
        "poo" to "💩", "crap" to "💩",
        "spooky" to "👻",
        "bday" to "🎂",
        "bulb" to "💡",
        "launch" to "🚀",
        "hamburger" to "🍔",
        "latte" to "☕", "espresso" to "☕", "cafe" to "☕",
        "doggo" to "🐶", "doggy" to "🐶", "pup" to "🐶",
        "kitty" to "🐱", "meow" to "🐱",
        "goodnight" to "🌙", "nite" to "🌙",
        "airplane" to "✈️",
        "taxi" to "🚗", "cab" to "🚗",
        "bicycle" to "🚲",
        "pic" to "📷",
        "film" to "🎬",
        "mobile" to "📱",
        "tune" to "🎵",
        "books" to "📚",
        "soccer" to "⚽",
    )

    // Related chips, keyed by the primary glyph so every alias shares them.
    private val EXTRAS: Map<String, List<String>> = mapOf(
        "😢" to listOf("😭", "😞"),
        "😊" to listOf("😄", "😁"),
        "😭" to listOf("😢"),
        "❤️" to listOf("💕", "😍"),
        "😠" to listOf("😡"),
        "😂" to listOf("🤣"),
        "💀" to listOf("☠️"),
    )
}

/** Replace the trigger while the cursor is still on it; insert once anything follows. */
internal object EmojiCommit {
    fun shouldReplaceTrigger(composing: String, before: CharSequence): Boolean {
        if (composing.isNotEmpty()) return EmojiSuggestions.glyph(composing) != null
        if (before.isEmpty() || !isWordChar(before.last())) return false
        return EmojiSuggestions.glyph(SuggestionEngine.lastWord(before).orEmpty()) != null
    }

    fun insertText(before: CharSequence, emoji: String): String {
        val prefix = if (before.isEmpty() || before.last().isWhitespace()) "" else " "
        return prefix + emoji
    }

    private fun isWordChar(character: Char): Boolean =
        character.isLetterOrDigit() || character == '\''
}
