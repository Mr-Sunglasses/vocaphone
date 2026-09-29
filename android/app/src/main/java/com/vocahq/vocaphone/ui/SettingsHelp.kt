package com.vocahq.vocaphone.ui

/**
 * The full explanation behind a section's ⓘ.
 *
 * Settings detail lines had become the only home for every rule and
 * exception — Clean up speech carried a paragraph under its switch, and the
 * Dictation page was eleven sections deep. Each control now says what it does
 * in one line; the rest moved here, word for word, one tap away.
 */
data class LearnMore(val title: String, val paragraphs: List<String>)

internal object SettingsHelp {
    val output = LearnMore(
        title = "How your words are written",
        paragraphs = listOf(
            "Clean up speech changes your words, not only formatting. It drops " +
                "hesitation sounds and false starts, and fills in missing sentence " +
                "punctuation: \"so um we should we should ship it friday\" becomes " +
                "\"So we should ship it Friday.\" Only sounds with no meaning go — " +
                "\"um\", \"uh\", \"er\". Real words stay, including \"like\" and \"you " +
                "know\", and so do \"mhm\" and \"uh-huh\", which are answers.",
            "Write numbers as digits writes “six pm” as “6 pm” and " +
                "“twenty three” as “23”. A lone “one” stays " +
                "a word unless a unit follows it. English only. Ordinals and spoken " +
                "times stay as words.",
            "Spoken emoji: say the emoji and then the word “emoji”: " +
                "“crying emoji” becomes 😭. The whole name has to match — a " +
                "partial suffix is left alone. The same names the keyboard suggests " +
                "while you type work here. “Emoji” on its own is left alone, " +
                "so “send me the emoji” is still typed as you said it. The " +
                "emoji names are English, and work by that name in a transcript in any " +
                "language.",
            "Clean up speech and spoken emoji are not applied to the Raw writing " +
                "style. Write numbers as digits still applies to it when it is on.",
        ),
    )

    val recording = LearnMore(
        title = "About recording",
        paragraphs = listOf(
            "The dictation tone plays start and stop cues when dictation turns on and " +
                "off. Off plays nothing.",
            "Stop after a pause finishes a dictation by itself after three seconds of " +
                "quiet following at least a second of speech. Leave it off if you pause " +
                "to think while you talk.",
            "Keep model loaded sets how long the on-device model stays in RAM after " +
                "you stop dictating. Unloading saves battery; keeping it makes the next " +
                "dictation start faster.",
        ),
    )

    val kept = LearnMore(
        title = "What is kept",
        paragraphs = listOf(
            "Successful dictations delete their audio immediately. A failed one keeps " +
                "it only for the time you choose, so Retry still works.",
        ),
    )

    val keyboardLayout = LearnMore(
        title = "Keyboard layout",
        paragraphs = listOf(
            "Auto splits when the keyboard is at least 600 dp wide, like a tablet or " +
                "an unfolded foldable. A phone-sized portrait keyboard stays in one piece.",
            "Dynamic color follows the system wallpaper colors. Off keeps the Voca teal.",
        ),
    )

    val typing = LearnMore(
        title = "About typing",
        paragraphs = listOf(
            "Suggestions are local English word completions and next-word guesses. " +
                "They read a short window of text around the cursor, and are off in " +
                "password fields.",
            "Corrections offer nearby dictionary words in the toolbar. Tap a word, or " +
                "a swipe alternative, to replace it.",
            "Hold for digits and symbols shows a punctuation mark or digit on each " +
                "letter key. Hold the key to type it; slide for accents. It is off by " +
                "default so a hold on E still types è.",
            "Text emoticons add an ASCII category to the emoji panel, like :) and " +
                "¯\\_(ツ)_/¯.",
            "Swipe typing: glide across letter keys to enter a word. English only; " +
                "there is no language pack to download.",
        ),
    )

    val clipboard = LearnMore(
        title = "About the clipboard",
        paragraphs = listOf(
            "The clipboard chip shows a clipboard icon and a preview of the current " +
                "clip. Tap to paste; tap the × to dismiss it.",
            "Clipboard history saves recent text and images on this phone. Open them " +
                "from the keyboard menu, where you can paste or delete them. It is off " +
                "in password fields.",
        ),
    )

    val customWords = LearnMore(
        title = "Custom words",
        paragraphs = listOf(
            "Names, places and jargon a speech model is unlikely to know. One per " +
                "line, or separated by commas.",
            "Each word is spelled your way when the transcript comes close — " +
                "\"whisper kit\" becomes \"WhisperKit\". Whisper models are also " +
                "nudged toward them while decoding; a very long list starts to crowd " +
                "out the speech itself.",
        ),
    )
}
