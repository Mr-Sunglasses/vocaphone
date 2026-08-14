package com.vocahq.vocaphone.ime

internal object KeyboardLayouts {
    fun rows(
        layer: KeyboardLayer,
        editor: KeyboardEditorConfig,
        numberRow: Boolean = false,
    ): List<KeyboardRow> = when (layer) {
        KeyboardLayer.LETTERS -> letterRows(editor, numberRow)
        KeyboardLayer.NUMBERS -> numberRows(editor, extraRow = true)
        KeyboardLayer.SYMBOLS -> symbolRows(editor, extraRow = true)
        KeyboardLayer.EMOJI -> listOf(emojiBottomRow(editor))
    }

    fun letterRowCount(numberRow: Boolean) = if (numberRow) 5 else 4

    private fun letterRows(editor: KeyboardEditorConfig, numberRow: Boolean): List<KeyboardRow> = buildList {
        if (numberRow) add(characters("1234567890"))
        add(characters("qwertyuiop"))
        add(characters("asdfghjkl", inset = 0.5f))
        add(
            KeyboardRow(
                keys = listOf(
                    special("shift", "Shift", KeyboardKeyType.SHIFT, 1.35f),
                    *"zxcvbnm".map { character(it.toString()) }.toTypedArray(),
                    special("delete", "Delete", KeyboardKeyType.DELETE, 1.35f),
                ),
            ),
        )
        add(utilityRow(editor, "?123", KeyboardLayer.NUMBERS))
    }

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
        add(utilityRow(editor, "ABC", KeyboardLayer.LETTERS))
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
    ) = KeyboardRow(
        keys = listOf(
            layer("layer-$layerLabel", layerLabel, targetLayer, 1.25f),
            layer("emoji", "☺", KeyboardLayer.EMOJI, 0.7f),
            character(editor.leadingPunctuation, 0.85f),
            special("space", "space", KeyboardKeyType.SPACE, 4.1f),
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
