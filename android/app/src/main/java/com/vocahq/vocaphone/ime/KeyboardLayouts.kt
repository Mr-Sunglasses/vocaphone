package com.vocahq.vocaphone.ime

internal object KeyboardLayouts {
    /**
     * [layout] picks the letter rows. [languageKey] is on when more than one
     * layout is turned on: a language key joins the bottom row and the space
     * bar says which layout is up, as on iOS and Gboard.
     */
    fun rows(
        layer: KeyboardLayer,
        editor: KeyboardEditorConfig,
        numberRow: Boolean = false,
        layout: TypingLayout = KeyboardLanguages.ENGLISH,
        languageKey: Boolean = false,
    ): List<KeyboardRow> = when (layer) {
        KeyboardLayer.LETTERS -> letterRows(editor, numberRow, layout, languageKey)
        KeyboardLayer.NUMBERS -> numberRows(editor, extraRow = true)
        KeyboardLayer.SYMBOLS -> symbolRows(editor, extraRow = true)
        KeyboardLayer.EMOJI -> listOf(emojiBottomRow(editor))
        KeyboardLayer.PHONE -> padRows(PadKind.PHONE, editor)
        KeyboardLayer.NUMPAD -> padRows(editor.padKind, editor)
    }

    /**
     * Gboard's pads: three digit columns and a fourth for the keys a number
     * field needs, four rows like the letters so the keyboard does not
     * resize between a name field and a phone field. The bottom-left key
     * opens the full symbols page, whose `123` key comes back here.
     *
     * - Phone: `-`, space, delete; `*#`, 0, `+`, return. Letters under 2-9
     *   as on a dial pad.
     * - Number: `-`, `,`, delete; `?123`, 0, `.`, return.
     * - Date/time: `/`, `:`, delete; `?123`, 0, `-`, return.
     */
    fun padRows(kind: PadKind, editor: KeyboardEditorConfig): List<KeyboardRow> {
        val side: List<KeyboardKey> = when (kind) {
            PadKind.PHONE -> listOf(padKey("-"), special("space", "space", KeyboardKeyType.SPACE, 1f))
            PadKind.NUMBER -> listOf(padKey("-"), padKey(","))
            PadKind.DATETIME -> listOf(padKey("/"), padKey(":"))
        }
        val bottom = when (kind) {
            PadKind.PHONE -> listOf(
                layer("pad-symbols", "*#", KeyboardLayer.NUMBERS, 1f),
                padKey("0"),
                padKey("+"),
            )
            PadKind.NUMBER -> listOf(
                layer("pad-symbols", "?123", KeyboardLayer.NUMBERS, 1f),
                padKey("0"),
                padKey(".", popup = listOf(",")),
            )
            PadKind.DATETIME -> listOf(
                layer("pad-symbols", "?123", KeyboardLayer.NUMBERS, 1f),
                padKey("0"),
                padKey("-"),
            )
        }
        val letters = if (kind == PadKind.PHONE) DIAL_LETTERS else emptyMap()
        fun digits(text: String) = text.map { padKey(it.toString(), caption = letters[it]) }
        return listOf(
            KeyboardRow(keys = digits("123") + side[0]),
            KeyboardRow(keys = digits("456") + side[1]),
            KeyboardRow(keys = digits("789") + special("delete", "Delete", KeyboardKeyType.DELETE, 1f)),
            KeyboardRow(keys = bottom + special("return", editor.returnKey.name, KeyboardKeyType.RETURN, 1f)),
        )
    }

    private val DIAL_LETTERS = mapOf(
        '2' to "ABC", '3' to "DEF", '4' to "GHI", '5' to "JKL",
        '6' to "MNO", '7' to "PQRS", '8' to "TUV", '9' to "WXYZ",
    )

    private fun padKey(output: String, caption: String? = null, popup: List<String> = emptyList()) = KeyboardKey(
        id = "pad-$output",
        label = output,
        output = output,
        popup = popup,
        caption = caption,
    )

    fun letterRowCount(numberRow: Boolean) = if (numberRow) 5 else 4

    private fun letterRows(
        editor: KeyboardEditorConfig,
        numberRow: Boolean,
        layout: TypingLayout,
        languageKey: Boolean,
    ): List<KeyboardRow> = buildList {
        val (top, home, bottom) = layout.rows
        val columns = top.length
        if (numberRow) add(characters("1234567890"))
        add(characters(top))
        // A shorter home row is centred under the top one (QWERTY's half-key
        // indent); a full-width one (AZERTY, Spanish, ЙЦУКЕН) is not.
        add(characters(home, inset = ((columns - home.length) / 2f).coerceAtLeast(0f)))
        add(
            KeyboardRow(
                keys = listOf(
                    special("shift", "Shift", KeyboardKeyType.SHIFT, sideKeyWeight(columns, bottom.length)),
                    *bottom.map { character(it.toString()) }.toTypedArray(),
                    special("delete", "Delete", KeyboardKeyType.DELETE, sideKeyWeight(columns, bottom.length)),
                ),
            ),
        )
        add(
            utilityRow(
                editor,
                "?123",
                KeyboardLayer.NUMBERS,
                languageKey = languageKey,
                spaceCaption = layout.displayName.takeIf { languageKey },
            ),
        )
    }

    /**
     * Shift and delete share what the bottom row's letters leave of the top
     * row's width, so letters stay one width across rows: 1.35 on QWERTY (as
     * before), wider beside AZERTY's six, never under one key.
     */
    fun sideKeyWeight(columns: Int, bottomLetters: Int): Float =
        ((columns - bottomLetters) / 2f - 0.15f).coerceAtLeast(1f)

    private fun numberRows(editor: KeyboardEditorConfig, extraRow: Boolean) = buildList {
        add(characters("1234567890"))
        add(characters(listOf("@", "#", "$", "%", "&", "-", "+", "(", ")", "/")))
        if (extraRow) {
            add(characters(listOf("€", "£", "¥", "•", "_", "\\", "|", "~", "<", ">")))
        }
        add(
            KeyboardRow(
                keys = listOf(
                    layer("symbols", "#+=", KeyboardLayer.SYMBOLS, 1.35f),
                    *listOf("*", "\"", "'", ":", ";", "!", "?")
                        .map { character(it) }
                        .toTypedArray(),
                    special("delete", "Delete", KeyboardKeyType.DELETE, 1.35f),
                ),
            ),
        )
        // Opened from a dial or number pad, the way back is to the pad.
        if (editor.startsOnPad) {
            add(utilityRow(editor, "123", editor.initialLayer))
        } else {
            add(utilityRow(editor, "ABC", KeyboardLayer.LETTERS))
        }
    }

    private fun symbolRows(editor: KeyboardEditorConfig, extraRow: Boolean) = buildList {
        add(characters(listOf("[", "]", "{", "}", "#", "%", "^", "*", "+", "=")))
        add(characters(listOf("_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•")))
        if (extraRow) {
            add(characters(listOf("©", "®", "™", "°", "¿", "¡", "√", "π", "∆", "¶")))
        }
        add(
            KeyboardRow(
                keys = listOf(
                    layer("numbers", "123", KeyboardLayer.NUMBERS, 1.35f),
                    *listOf("`", "\"", "'", ":", ";", "!", "?")
                        .map { character(it) }
                        .toTypedArray(),
                    special("delete", "Delete", KeyboardKeyType.DELETE, 1.35f),
                ),
            ),
        )
        add(utilityRow(editor, "ABC", KeyboardLayer.LETTERS))
    }

    private fun emojiBottomRow(editor: KeyboardEditorConfig) = KeyboardRow(
        keys = listOf(
            layer("emoji-letters", "ABC", KeyboardLayer.LETTERS, 1.4f),
            special("space", "space", KeyboardKeyType.SPACE, 4.0f),
            special("delete", "Delete", KeyboardKeyType.DELETE, 1.4f),
            special("return", editor.returnKey.name, KeyboardKeyType.RETURN, 1.4f),
        ),
    )

    private fun utilityRow(
        editor: KeyboardEditorConfig,
        layerLabel: String,
        targetLayer: KeyboardLayer,
        languageKey: Boolean = false,
        spaceCaption: String? = null,
    ) = KeyboardRow(
        keys = listOfNotNull(
            layer("layer-$layerLabel", layerLabel, targetLayer, 1.25f),
            layer("emoji", "☺", KeyboardLayer.EMOJI, 0.7f),
            character(editor.leadingPunctuation, 0.85f),
            // The language key takes its width from the space bar, so the
            // keys either side of it stay where thumbs expect them.
            if (languageKey) special("language", "Language", KeyboardKeyType.LANGUAGE, 0.85f) else null,
            special("space", "space", KeyboardKeyType.SPACE, if (languageKey) 3.25f else 4.1f)
                .copy(caption = spaceCaption),
            character(".", 0.85f),
            special("return", editor.returnKey.name, KeyboardKeyType.RETURN, 1.95f),
        ),
    )

    private fun characters(text: String, inset: Float = 0f) =
        characters(text.map(Char::toString), inset)

    private fun characters(values: List<String>, inset: Float = 0f) = KeyboardRow(
        keys = values.map(::character),
        leadingSpace = inset,
        trailingSpace = inset,
    )

    private fun character(output: String, weight: Float = 1f) = KeyboardKey(
        id = "character-$output",
        label = output,
        output = output,
        weight = weight,
    )

    private fun special(
        id: String,
        label: String,
        type: KeyboardKeyType,
        weight: Float,
    ) = KeyboardKey(id = id, label = label, type = type, weight = weight)

    private fun layer(
        id: String,
        label: String,
        target: KeyboardLayer,
        weight: Float,
    ) = KeyboardKey(
        id = id,
        label = label,
        type = KeyboardKeyType.LAYER_SWITCH,
        targetLayer = target,
        weight = weight,
    )
}
