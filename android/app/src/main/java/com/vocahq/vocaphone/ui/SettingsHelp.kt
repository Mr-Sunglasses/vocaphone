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
            "Fix grammar (English) corrects common grammar and spelling slips after " +
                "Clean up speech: \"he don't know\" becomes \"he doesn't know\", " +
                "\"their going\" becomes \"they're going\". It runs on this phone with a " +
                "28 MB model you download once, and your words are never sent anywhere. " +
                "It leaves names, numbers, links and your own words alone, works only on " +
                "English transcribed on this phone, and can occasionally change a " +
                "sentence that was already right. Off by default.",
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
            "Clean up speech, Fix grammar and spoken emoji are not applied to the Raw writing " +
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
            "Maximum recording length stops a dictation by itself and transcribes it " +
                "once it has run that long. With a gateway, the gateway's own limit " +
                "applies too, whichever is shorter.",
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

    val writing = LearnMore(
        title = "About Writing check",
        paragraphs = listOf(
            "Writing check is a grammar and style checker that runs on this phone. When " +
                "you pause, the keyboard reads the text around the cursor and puts a count at " +
                "the start of the toolbar: tap a suggestion to apply it, or tap the count to " +
                "see each one with its reason, and Accept, Ignore or Add to dictionary.",
            "Suggestions come in four colours: red for correctness (spelling, grammar, " +
                "punctuation), blue for clarity (wordy phrases, passive voice), green for " +
                "engagement (weak intensifiers, repeated words) and purple for delivery " +
                "(hedging). Correctness is always on; the others have their own switches.",
            "It works without a download. The optional 28 MB grammar model, shared with " +
                "Fix grammar for dictation, catches more slips like \"he don't know\". " +
                "\"Only sure fixes\" makes it offer fewer, safer changes.",
            "Nothing you type is sent anywhere, there is no account, and nothing changes " +
                "until you tap, unless you turn on \"Fix obvious typos as I type\", which " +
                "corrects known misspellings and offers Undo. It is off in passwords, " +
                "addresses and links, leaves your own words, names and links alone, and " +
                "checks English only.",
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
