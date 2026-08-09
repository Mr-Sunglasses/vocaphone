package com.vocahq.vocaphone.ime

internal object KeyboardLayouts {
    fun rows(layer: KeyboardLayer, editor: KeyboardEditorConfig): List<KeyboardRow> = when (layer) {
        KeyboardLayer.LETTERS -> letterRows(editor)
        KeyboardLayer.NUMBERS -> numberRows(editor)
        KeyboardLayer.SYMBOLS -> symbolRows(editor)
        KeyboardLayer.EMOJI -> emojiRows(editor)
    }

    private fun letterRows(editor: KeyboardEditorConfig) = listOf(
        characters("qwertyuiop"),
        characters("asdfghjkl", inset = 0.5f),
        KeyboardRow(
            keys = listOf(
                special("shift", "Shift", KeyboardKeyType.SHIFT, 1.35f),
                *"zxcvbnm".map { character(it.toString()) }.toTypedArray(),
                special("delete", "Delete", KeyboardKeyType.DELETE, 1.35f),
            ),
        ),
        utilityRow(editor, "?123", KeyboardLayer.NUMBERS),
    )

    private fun numberRows(editor: KeyboardEditorConfig) = listOf(
        characters("1234567890"),
        characters(listOf("@", "#", "$", "%", "&", "-", "+", "(", ")", "/")),
        KeyboardRow(
            keys = listOf(
                layer("symbols", "#+=", KeyboardLayer.SYMBOLS, 1.35f),
                *listOf("*", "\"", "'", ":", ";", "!", "?")
                    .map { character(it) }
                    .toTypedArray(),
                special("delete", "Delete", KeyboardKeyType.DELETE, 1.35f),
            ),
        ),
        utilityRow(editor, "ABC", KeyboardLayer.LETTERS),
    )

    private fun symbolRows(editor: KeyboardEditorConfig) = listOf(
        characters(listOf("[", "]", "{", "}", "#", "%", "^", "*", "+", "=")),
        characters(listOf("_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•")),
        KeyboardRow(
            keys = listOf(
                layer("numbers", "123", KeyboardLayer.NUMBERS, 1.35f),
                *listOf("`", "\"", "'", ":", ";", "!", "?")
                    .map { character(it) }
                    .toTypedArray(),
                special("delete", "Delete", KeyboardKeyType.DELETE, 1.35f),
            ),
        ),
        utilityRow(editor, "ABC", KeyboardLayer.LETTERS),
    )

    private fun emojiRows(editor: KeyboardEditorConfig) = listOf(
        characters(listOf("😀", "😂", "🥰", "😍", "😊", "😉", "🥹", "😎", "🤔", "🫡")),
        characters(listOf("👍", "👎", "👏", "🙌", "🙏", "💪", "🤝", "❤️", "🔥", "✨")),
        characters(listOf("🎉", "✅", "💯", "🚀", "👀", "💡", "📌", "📱", "🎤", "🌍")),
        KeyboardRow(
            keys = listOf(
                layer("emoji-letters", "ABC", KeyboardLayer.LETTERS, 1.35f),
                special("keyboard-switch", "Switch keyboard", KeyboardKeyType.KEYBOARD_SWITCH, 1.05f),
                special("space", "space", KeyboardKeyType.SPACE, 3.85f),
                special("delete", "Delete", KeyboardKeyType.DELETE, 1.35f),
                special("return", editor.returnKey.name, KeyboardKeyType.RETURN, 1.55f),
            ),
        ),
    )

    private fun utilityRow(
        editor: KeyboardEditorConfig,
        layerLabel: String,
        targetLayer: KeyboardLayer,
    ) = KeyboardRow(
        keys = listOf(
            layer("layer-$layerLabel", layerLabel, targetLayer, 1.2f),
            layer("emoji", "☺", KeyboardLayer.EMOJI, 0.9f),
            character(editor.leadingPunctuation, 0.8f),
            special("keyboard-switch", "Switch keyboard", KeyboardKeyType.KEYBOARD_SWITCH, 0.95f),
            special("space", "space", KeyboardKeyType.SPACE, 3.25f),
            character(".", 0.8f),
            special("return", editor.returnKey.name, KeyboardKeyType.RETURN, 1.45f),
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
