package com.vocahq.vocaphone.ime

import android.os.SystemClock
import android.view.HapticFeedbackConstants
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.core.ModelLanguageSupport
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.core.WritingStyle
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import com.vocahq.vocaphone.ui.theme.VocaPhoneTheme
import kotlin.math.PI
import kotlin.math.sin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.abs
import java.util.Locale

private enum class PreferencePanel {
    LANGUAGE,
    STYLE,
}

@Composable
internal fun VocaPhoneKeyboard(
    dictationState: DictationState,
    editor: KeyboardEditorConfig,
    settings: VocaPhoneSettings,
    isPreferenceWritePending: Boolean,
    clipboard: ClipboardChip?,
    textBeforeCursor: String,
    suggestions: SuggestionDictionary?,
    emojiCatalog: List<EmojiEntry>,
    onCommand: (KeyboardCommand) -> Unit,
    onMicTap: () -> Unit,
    onOpenApp: () -> Unit,
    onLanguageSelected: (TranscriptionLanguage) -> Unit,
    onStyleSelected: (WritingStyle) -> Unit,
    onSuggestionPicked: (String) -> Unit,
    onPasteClipboard: () -> Unit,
    onEmojiUsed: (String) -> Unit,
) {
    var keyboardState by remember(editor.sessionId) {
        mutableStateOf(
            KeyboardState(
                layer = editor.initialLayer,
                shift = editor.initialShift,
            ),
        )
    }
    var preferencePanel by remember(editor.sessionId) { mutableStateOf<PreferencePanel?>(null) }
    var emojiCategory by remember(editor.sessionId) { mutableStateOf(EmojiCategory.SMILEYS) }

    LaunchedEffect(dictationState.phase, editor.dictationAllowed) {
        if (dictationState.phase != DictationPhase.IDLE || !editor.dictationAllowed) {
            preferencePanel = null
        }
    }

    val composeWords = settings.suggestionsEnabled && !editor.sensitive
    val keyHeight = settings.keyboardHeight.keyHeightDp.dp
    val letterRows = KeyboardLayouts.letterRowCount(settings.numberRowEnabled)
    val keyAreaHeight = keyHeight * letterRows + RowGap * (letterRows - 1)
    val suggestionItems = remember(
        composeWords,
        keyboardState.composing,
        textBeforeCursor,
        suggestions,
    ) {
        if (!composeWords || suggestions == null) {
            emptyList()
        } else if (keyboardState.composing.isNotEmpty()) {
            suggestions.complete(keyboardState.composing)
        } else {
            suggestions.next(SuggestionEngine.lastWord(textBeforeCursor).orEmpty())
        }
    }
    val clipboardChip = clipboard.takeIf { settings.clipboardChipEnabled && !editor.sensitive }
    val startedTyping = KeyboardChrome.startedTyping(keyboardState.composing, textBeforeCursor)
    val stripClipboard = KeyboardChrome.clipboardForStrip(clipboardChip)
    val stripSuggestions = KeyboardChrome.suggestionsForStrip(suggestionItems, startedTyping)

    fun handleKey(key: KeyboardKey) {
        val reduction = KeyboardReducer.press(
            state = keyboardState,
            key = key,
            nowMillis = SystemClock.uptimeMillis(),
            composeWords = composeWords,
        )
        keyboardState = reduction.state
        reduction.command?.let(onCommand)
    }

    VocaPhoneTheme {
        Surface(
            color = MaterialTheme.colorScheme.surfaceContainerLowest,
            contentColor = MaterialTheme.colorScheme.onSurface,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 4.dp, bottom = 6.dp),
            ) {
                DictationBar(
                    state = dictationState,
                    editor = editor,
                    settings = settings,
                    barHeight = settings.keyboardHeight.dictationBarDp.dp,
                    isPreferenceWritePending = isPreferenceWritePending,
                    clipboard = stripClipboard.takeIf {
                        preferencePanel == null && keyboardState.layer != KeyboardLayer.EMOJI
                    },
                    suggestions = stripSuggestions.takeIf {
                        preferencePanel == null && keyboardState.layer != KeyboardLayer.EMOJI
                    }.orEmpty(),
                    emojiCategory = emojiCategory.takeIf {
                        preferencePanel == null && keyboardState.layer == KeyboardLayer.EMOJI
                    },
                    hasEmojiRecents = settings.emojiRecents.isNotEmpty(),
                    onEmojiCategory = { emojiCategory = it },
                    onMicTap = onMicTap,
                    onOpenApp = onOpenApp,
                    onPaste = onPasteClipboard,
                    onSuggestion = { word ->
                        keyboardState = keyboardState.copy(
                            composing = "",
                            lastWasSpace = true,
                            capitalizeAfterSpace = false,
                        )
                        onSuggestionPicked(word)
                    },
                    activePreferencePanel = preferencePanel,
                    onLanguageChipTapped = {
                        preferencePanel = if (preferencePanel == PreferencePanel.LANGUAGE) {
                            null
                        } else {
                            PreferencePanel.LANGUAGE
                        }
                    },
                    onStyleChipTapped = {
                        preferencePanel = if (preferencePanel == PreferencePanel.STYLE) {
                            null
                        } else {
                            PreferencePanel.STYLE
                        }
                    },
                )
                Spacer(Modifier.height(4.dp))
                when (preferencePanel) {
                    PreferencePanel.LANGUAGE -> LanguagePreferencePanel(
                        settings = settings,
                        height = keyAreaHeight,
                        enabled = !isPreferenceWritePending,
                        onSelected = { language ->
                            preferencePanel = null
                            onLanguageSelected(language)
                        },
                        onClose = { preferencePanel = null },
                    )
                    PreferencePanel.STYLE -> StylePreferencePanel(
                        selected = settings.style,
                        height = keyAreaHeight,
                        enabled = !isPreferenceWritePending,
                        onSelected = { style ->
                            preferencePanel = null
                            onStyleSelected(style)
                        },
                        onClose = { preferencePanel = null },
                    )
                    null -> if (keyboardState.layer == KeyboardLayer.EMOJI) {
                        EmojiLayer(
                            height = keyAreaHeight,
                            keyHeight = keyHeight,
                            editor = editor,
                            state = keyboardState,
                            catalog = emojiCatalog,
                            recents = settings.emojiRecents,
                            category = emojiCategory,
                            onEmoji = { glyph ->
                                handleKey(
                                    KeyboardKey(
                                        id = "emoji-$glyph",
                                        label = glyph,
                                        output = glyph,
                                    ),
                                )
                                onEmojiUsed(glyph)
                            },
                            onKey = ::handleKey,
                            onCursorMove = { positions ->
                                keyboardState = keyboardState.copy(composing = "", lastWasSpace = false)
                                onCommand(KeyboardCommand.MoveCursor(positions))
                            },
                        )
                    } else {
                        val rows = KeyboardLayouts.rows(
                            keyboardState.layer,
                            editor,
                            numberRow = settings.numberRowEnabled,
                        )
                        val fittedKeyHeight = if (rows.size <= 1) {
                            keyHeight
                        } else {
                            ((keyAreaHeight - RowGap * (rows.size - 1)) / rows.size)
                                .coerceAtLeast(36.dp)
                        }
                        KeyboardRows(
                            rows = rows,
                            state = keyboardState,
                            editor = editor,
                            keyHeight = fittedKeyHeight,
                            onKey = ::handleKey,
                            onCursorMove = { positions ->
                                keyboardState = keyboardState.copy(composing = "", lastWasSpace = false)
                                onCommand(KeyboardCommand.MoveCursor(positions))
                            },
                        )
                    }
                }
            }
        }
    }
}

private val RowGap = 5.dp

@Composable
private fun DictationBar(
    state: DictationState,
    editor: KeyboardEditorConfig,
    settings: VocaPhoneSettings,
    barHeight: Dp,
    isPreferenceWritePending: Boolean,
    clipboard: ClipboardChip?,
    suggestions: List<String>,
    emojiCategory: EmojiCategory?,
    hasEmojiRecents: Boolean,
    onEmojiCategory: (EmojiCategory) -> Unit,
    onMicTap: () -> Unit,
    onOpenApp: () -> Unit,
    onPaste: () -> Unit,
    onSuggestion: (String) -> Unit,
    activePreferencePanel: PreferencePanel?,
    onLanguageChipTapped: () -> Unit,
    onStyleChipTapped: () -> Unit,
) {
    val view = LocalView.current
    val idle = state.phase == DictationPhase.IDLE
    val status = when {
        editor.sensitive -> "Private field"
        !editor.dictationAllowed -> "Typing only"
        idle -> "VocaPhone"
        state.phase == DictationPhase.LISTENING -> "Listening · ${formatDuration(state.recordedMillis)}"
        else -> state.statusText
    }
    val detail = when {
        editor.sensitive -> "Dictation is off here"
        !editor.dictationAllowed -> "Dictation is available in text fields"
        idle -> ""
        state.phase == DictationPhase.LISTENING && state.partialTranscript.isNotBlank() ->
            state.partialTranscript.replace('\n', ' ').take(64)
        state.phase == DictationPhase.LISTENING -> state.inputRouteLabel ?: "Tap the mic again to finish"
        state.phase.isBusy -> "You can keep typing while VocaPhone works"
        state.phase == DictationPhase.PERMISSION_REPAIR -> "Open VocaPhone to finish setup"
        state.phase == DictationPhase.FAILED -> "Tap the mic to try again"
        else -> "Ready"
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(barHeight)
            .padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Surface(
            modifier = Modifier
                .size(36.dp)
                .semantics {
                    role = Role.Button
                    contentDescription = "Open VocaPhone"
                },
            shape = CircleShape,
            color = MaterialTheme.colorScheme.primary,
            onClick = {
                view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                onOpenApp()
            },
        ) {
            Box(contentAlignment = Alignment.Center) {
                Image(
                    painter = painterResource(R.drawable.ic_launcher_foreground),
                    contentDescription = null,
                    modifier = Modifier.size(28.dp),
                )
            }
        }

        Row(
            modifier = Modifier
                .weight(1f)
                .semantics { liveRegion = LiveRegionMode.Polite },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            when {
                state.isRecording -> {
                    Spacer(Modifier.weight(1f))
                    Waveform(level = state.level)
                    Column(
                        horizontalAlignment = Alignment.End,
                        verticalArrangement = Arrangement.Center,
                    ) {
                        Text(
                            text = status,
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            textAlign = TextAlign.End,
                        )
                        if (detail.isNotEmpty()) {
                            Text(
                                text = detail,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                style = MaterialTheme.typography.labelSmall,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                textAlign = TextAlign.End,
                            )
                        }
                    }
                }
                !idle || !editor.dictationAllowed -> {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.Center) {
                        Text(
                            text = status,
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        if (detail.isNotEmpty()) {
                            Text(
                                text = detail,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                style = MaterialTheme.typography.labelSmall,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
                emojiCategory != null -> EmojiCategoryRow(
                    selected = emojiCategory,
                    hasRecents = hasEmojiRecents,
                    onSelect = onEmojiCategory,
                    modifier = Modifier.weight(1f),
                )
                clipboard != null -> ClipboardChipButton(
                    preview = clipboard.preview,
                    onClick = onPaste,
                    modifier = Modifier.weight(1f),
                )
                suggestions.isNotEmpty() -> suggestions.take(3).forEach { word ->
                    SuggestionChip(
                        label = word,
                        onClick = { onSuggestion(word) },
                        modifier = Modifier.weight(1f),
                    )
                }
                else -> Spacer(Modifier.weight(1f))
            }
        }

        if (idle && editor.dictationAllowed && emojiCategory == null) {
            ToolbarIconButton(
                contentDescription = "Transcription language, ${settings.effectiveLanguage.displayName}",
                active = activePreferencePanel == PreferencePanel.LANGUAGE,
                enabled = !isPreferenceWritePending,
                onClick = onLanguageChipTapped,
            ) {
                KeyboardIcon(
                    glyph = Glyph.GLOBE,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(18.dp),
                )
            }
            ToolbarIconButton(
                contentDescription = "Writing style, ${settings.style.displayName}",
                active = activePreferencePanel == PreferencePanel.STYLE,
                enabled = !isPreferenceWritePending,
                onClick = onStyleChipTapped,
            ) {
                Text(
                    text = "Aa",
                    color = MaterialTheme.colorScheme.primary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
        }

        MicButton(
            state = state,
            enabled = editor.dictationAllowed && !isPreferenceWritePending,
            onClick = onMicTap,
        )
    }
}

@Composable
private fun ToolbarIconButton(
    contentDescription: String,
    onClick: () -> Unit,
    active: Boolean = false,
    enabled: Boolean = true,
    content: @Composable () -> Unit,
) {
    Surface(
        modifier = Modifier
            .size(36.dp)
            .semantics {
                role = Role.Button
                this.contentDescription = contentDescription
                if (!enabled) disabled()
            },
        shape = CircleShape,
        color = if (active) {
            MaterialTheme.colorScheme.primaryContainer
        } else {
            MaterialTheme.colorScheme.surfaceContainerHigh
        },
        enabled = enabled,
        onClick = onClick,
    ) {
        Box(contentAlignment = Alignment.Center) { content() }
    }
}

@Composable
private fun SelectedMark() {
    Text(
        text = "✓",
        color = MaterialTheme.colorScheme.primary,
        fontWeight = FontWeight.Bold,
    )
}

@Composable
private fun LanguagePreferencePanel(
    settings: VocaPhoneSettings,
    height: Dp,
    enabled: Boolean,
    onSelected: (TranscriptionLanguage) -> Unit,
    onClose: () -> Unit,
) {
    val languages = remember(settings.activeModelLanguages, settings.activeModelDetectsLanguage) {
        TranscriptionLanguage.entries.sortedWith(
            compareBy<TranscriptionLanguage>(
                { language ->
                    when {
                        language == TranscriptionLanguage.AUTOMATIC -> 0
                        ModelLanguageSupport.isSelectable(
                            language,
                            settings.activeModelLanguages,
                            settings.activeModelDetectsLanguage,
                        ) -> 1
                        else -> 2
                    }
                },
                TranscriptionLanguage::displayName,
            ),
        )
    }
    val restriction = ModelLanguageSupport.restriction(
        settings.activeModelLanguages,
        settings.activeModelDetectsLanguage,
        onDevice = settings.localTranscriptionEnabled,
    )

    PreferencePanelShell(
        title = "Transcription language",
        subtitle = restriction ?: "Choose the language used for voice dictation",
        height = height,
        onClose = onClose,
    ) {
        LazyColumn(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            contentPadding = PaddingValues(bottom = 2.dp),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            items(languages, key = TranscriptionLanguage::wireValue) { language ->
                val selectable = ModelLanguageSupport.isSelectable(
                    language,
                    settings.activeModelLanguages,
                    settings.activeModelDetectsLanguage,
                )
                LanguageOptionRow(
                    language = language,
                    selected = language == settings.effectiveLanguage,
                    enabled = enabled && selectable,
                    onClick = { onSelected(language) },
                )
            }
        }
    }
}

@Composable
private fun LanguageOptionRow(
    language: TranscriptionLanguage,
    selected: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .height(40.dp)
            .semantics { this.selected = selected },
        shape = RoundedCornerShape(8.dp),
        color = if (selected) {
            MaterialTheme.colorScheme.primaryContainer
        } else {
            MaterialTheme.colorScheme.surfaceContainerHigh
        },
        contentColor = if (selected) {
            MaterialTheme.colorScheme.onPrimaryContainer
        } else {
            MaterialTheme.colorScheme.onSurface
        },
        enabled = enabled,
        onClick = onClick,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = language.displayName,
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
            )
            when {
                selected -> SelectedMark()
                !enabled -> Text(
                    text = "Unavailable",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 10.sp,
                )
            }
        }
    }
}

@Composable
private fun StylePreferencePanel(
    selected: WritingStyle,
    height: Dp,
    enabled: Boolean,
    onSelected: (WritingStyle) -> Unit,
    onClose: () -> Unit,
) {
    PreferencePanelShell(
        title = "Writing style",
        subtitle = "Controls punctuation and capitalization only",
        height = height,
        onClose = onClose,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            WritingStyle.entries.chunked(2).forEach { styles ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    styles.forEach { style ->
                        StyleOptionCard(
                            style = style,
                            selected = style == selected,
                            enabled = enabled,
                            onClick = { onSelected(style) },
                        )
                    }
                    if (styles.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun RowScope.StyleOptionCard(
    style: WritingStyle,
    selected: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .weight(1f)
            .fillMaxHeight()
            .semantics { this.selected = selected },
        shape = RoundedCornerShape(8.dp),
        color = if (selected) {
            MaterialTheme.colorScheme.primaryContainer
        } else {
            MaterialTheme.colorScheme.surfaceContainerHigh
        },
        contentColor = if (selected) {
            MaterialTheme.colorScheme.onPrimaryContainer
        } else {
            MaterialTheme.colorScheme.onSurface
        },
        enabled = enabled,
        onClick = onClick,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    text = style.displayName,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = style.keyboardDetail,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 9.sp,
                    lineHeight = 10.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (selected) {
                Spacer(Modifier.width(4.dp))
                SelectedMark()
            }
        }
    }
}

@Composable
private fun PreferencePanelShell(
    title: String,
    subtitle: String,
    height: Dp,
    onClose: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .height(height)
            .padding(horizontal = 4.dp),
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
    ) {
        Column(Modifier.padding(4.dp)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(42.dp)
                    .padding(start = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        text = title,
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                    )
                    Text(
                        text = subtitle,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 9.sp,
                        lineHeight = 10.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Surface(
                    modifier = Modifier
                        .size(32.dp)
                        .semantics { contentDescription = "Close selector" },
                    shape = CircleShape,
                    color = MaterialTheme.colorScheme.surfaceContainerHigh,
                    onClick = onClose,
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Text(
                            text = "×",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            fontSize = 20.sp,
                        )
                    }
                }
            }
            content()
        }
    }
}

private val WritingStyle.keyboardDetail: String
    get() = when (this) {
        WritingStyle.RAW -> "Unchanged model output"
        WritingStyle.CLEAN -> "Tidy spacing + final period"
        WritingStyle.FORMAL -> "Capitalization + final period"
        WritingStyle.CASUAL -> "Natural, no final period"
        WritingStyle.VERY_CASUAL -> "Lowercase + commas"
        WritingStyle.EXCITED -> "Statements end with !"
    }

@Composable
private fun MicButton(
    state: DictationState,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val view = LocalView.current
    val processing = state.phase in setOf(
        DictationPhase.FINALIZING,
        DictationPhase.UPLOADING,
        DictationPhase.TRANSCRIBING,
        DictationPhase.INSERTING,
    )
    val recording = state.phase == DictationPhase.LISTENING
    val description = when {
        !enabled -> "Dictation unavailable"
        recording -> "Finish dictation"
        processing -> "Cancel dictation"
        state.phase == DictationPhase.PERMISSION_REPAIR -> "Open VocaPhone"
        else -> "Start dictation"
    }
    val container = when {
        !enabled -> MaterialTheme.colorScheme.surfaceContainerHigh
        recording -> MaterialTheme.colorScheme.error
        processing -> MaterialTheme.colorScheme.surfaceContainerHighest
        else -> MaterialTheme.colorScheme.primary
    }
    val content = when {
        !enabled -> MaterialTheme.colorScheme.outline
        recording -> MaterialTheme.colorScheme.onError
        processing -> MaterialTheme.colorScheme.onSurface
        else -> MaterialTheme.colorScheme.onPrimary
    }

    Surface(
        modifier = Modifier
            .size(40.dp)
            .semantics {
                role = Role.Button
                contentDescription = description
                if (!enabled) disabled()
            },
        shape = CircleShape,
        color = container,
        enabled = enabled,
        onClick = {
            view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
            onClick()
        },
    ) {
        Box(contentAlignment = Alignment.Center) {
            when {
                processing -> CircularProgressIndicator(
                    modifier = Modifier.size(20.dp),
                    color = content,
                    strokeWidth = 2.dp,
                )
                recording -> KeyboardIcon(Glyph.STOP, content)
                else -> KeyboardIcon(Glyph.MIC, content)
            }
        }
    }
}

@Composable
private fun Waveform(level: Float) {
    val color = MaterialTheme.colorScheme.primary
    val phase by rememberInfiniteTransition(label = "wave").animateFloat(
        initialValue = 0f,
        targetValue = (PI * 2).toFloat(),
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 650, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "phase",
    )
    val bars = 7
    Canvas(Modifier.size(width = 44.dp, height = 28.dp)) {
        val normalized = level.coerceIn(0.14f, 1f)
        val barWidth = 2.6.dp.toPx()
        val gap = (size.width - barWidth * bars) / (bars - 1)
        repeat(bars) { index ->
            val pulse = ((sin(phase + index * 0.75f) + 1f) / 2f)
            val height = size.height * (0.16f + 0.84f * normalized * (0.28f + 0.72f * pulse))
            val x = index * (barWidth + gap) + barWidth / 2
            drawLine(
                color = color,
                start = Offset(x, (size.height - height) / 2),
                end = Offset(x, (size.height + height) / 2),
                strokeWidth = barWidth,
                cap = StrokeCap.Round,
            )
        }
    }
}

@Composable
private fun ClipboardChipButton(
    preview: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier
            .height(32.dp)
            .semantics {
                role = Role.Button
                contentDescription = "Clipboard, $preview"
            },
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        onClick = onClick,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            KeyboardIcon(
                glyph = Glyph.CLIPBOARD,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(16.dp),
            )
            Text(
                text = preview,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun SuggestionChip(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier
            .height(32.dp)
            .semantics {
                role = Role.Button
                contentDescription = label
            },
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        onClick = onClick,
    ) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.padding(horizontal = 8.dp)) {
            Text(
                text = label,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun EmojiLayer(
    height: Dp,
    keyHeight: Dp,
    editor: KeyboardEditorConfig,
    state: KeyboardState,
    catalog: List<EmojiEntry>,
    recents: List<String>,
    category: EmojiCategory,
    onEmoji: (String) -> Unit,
    onKey: (KeyboardKey) -> Unit,
    onCursorMove: (Int) -> Unit,
) {
    val bottomRow = KeyboardLayouts.rows(KeyboardLayer.EMOJI, editor)
    val glyphs = if (category == EmojiCategory.RECENTS) {
        recents
    } else {
        EmojiCatalog.inCategory(catalog, category).map { it.glyph }
    }
    Column(Modifier.fillMaxWidth()) {
        EmojiGrid(
            glyphs = glyphs,
            modifier = Modifier
                .fillMaxWidth()
                .height((height - keyHeight - RowGap).coerceAtLeast(48.dp)),
            onEmoji = onEmoji,
        )
        KeyboardRows(
            rows = bottomRow,
            state = state,
            editor = editor,
            keyHeight = keyHeight,
            onKey = onKey,
            onCursorMove = onCursorMove,
        )
    }
}

@Composable
private fun EmojiCategoryRow(
    selected: EmojiCategory,
    hasRecents: Boolean,
    onSelect: (EmojiCategory) -> Unit,
    modifier: Modifier = Modifier,
) {
    val categories = buildList {
        if (hasRecents) add(EmojiCategory.RECENTS)
        addAll(EmojiCategory.browsable)
    }
    LazyRow(
        modifier = modifier
            .height(36.dp)
            .padding(horizontal = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        items(categories, key = { it.id }) { category ->
            Surface(
                shape = RoundedCornerShape(8.dp),
                color = if (category == selected) {
                    MaterialTheme.colorScheme.primaryContainer
                } else {
                    MaterialTheme.colorScheme.surfaceContainerHigh
                },
                onClick = { onSelect(category) },
            ) {
                Text(
                    text = category.icon,
                    modifier = Modifier
                        .padding(horizontal = 8.dp, vertical = 6.dp)
                        .semantics { contentDescription = category.label },
                    fontSize = 16.sp,
                )
            }
        }
    }
}

@Composable
private fun EmojiGrid(
    glyphs: List<String>,
    modifier: Modifier,
    onEmoji: (String) -> Unit,
) {
    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = 42.dp),
        modifier = modifier.padding(horizontal = 4.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        gridItems(glyphs, key = { it }) { glyph ->
            Box(
                modifier = Modifier
                    .height(42.dp)
                    .clickable { onEmoji(glyph) }
                    .semantics {
                        role = Role.Button
                        contentDescription = glyph
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(glyph, fontSize = 22.sp)
            }
        }
    }
}

@Composable
private fun KeyboardRows(
    rows: List<KeyboardRow>,
    state: KeyboardState,
    editor: KeyboardEditorConfig,
    keyHeight: Dp,
    onKey: (KeyboardKey) -> Unit,
    onCursorMove: (Int) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 4.dp),
        verticalArrangement = Arrangement.spacedBy(RowGap),
    ) {
        rows.forEach { row ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(keyHeight),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (row.leadingSpace > 0f) Spacer(Modifier.weight(row.leadingSpace))
                row.keys.forEach { key ->
                    KeyButton(
                        key = key,
                        state = state,
                        editor = editor,
                        keyHeight = keyHeight,
                        onPress = { onKey(key) },
                        onCommitText = { text ->
                            onKey(
                                KeyboardKey(
                                    id = "variant-$text",
                                    label = text,
                                    output = text,
                                ),
                            )
                        },
                        onCursorMove = onCursorMove,
                        modifier = Modifier.weight(key.weight),
                    )
                }
                if (row.trailingSpace > 0f) Spacer(Modifier.weight(row.trailingSpace))
            }
        }
    }
}

@Composable
private fun RowScope.KeyButton(
    key: KeyboardKey,
    state: KeyboardState,
    editor: KeyboardEditorConfig,
    keyHeight: Dp,
    onPress: () -> Unit,
    onCommitText: (String) -> Unit,
    onCursorMove: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val view = LocalView.current
    val previewOffset = with(LocalDensity.current) { -(keyHeight + 8.dp).roundToPx() }
    val currentOnPress = rememberUpdatedState(onPress)
    val currentOnCommitText = rememberUpdatedState(onCommitText)
    val currentOnCursorMove = rememberUpdatedState(onCursorMove)
    var pressed by remember(key.id) { mutableStateOf(false) }
    var accentIndex by remember(key.id) { mutableStateOf(-1) }
    val accents = remember(key.id, state.shift) { KeyAccents.forKey(key, state.shift) }
    val isReturnAction = key.type == KeyboardKeyType.RETURN && editor.returnKey != ReturnKeyKind.ENTER
    val activeShift = key.type == KeyboardKeyType.SHIFT && state.shift != ShiftState.OFF
    val background = when {
        isReturnAction -> MaterialTheme.colorScheme.primary
        activeShift -> MaterialTheme.colorScheme.primaryContainer
        key.type in setOf(KeyboardKeyType.CHARACTER, KeyboardKeyType.SPACE) ->
            MaterialTheme.colorScheme.surfaceContainerHighest
        else -> MaterialTheme.colorScheme.surfaceContainerHigh
    }
    val foreground = when {
        isReturnAction -> MaterialTheme.colorScheme.onPrimary
        activeShift -> MaterialTheme.colorScheme.onPrimaryContainer
        else -> MaterialTheme.colorScheme.onSurface
    }
    val previewLabel = if (
        key.type == KeyboardKeyType.CHARACTER &&
        state.layer == KeyboardLayer.LETTERS &&
        state.shift != ShiftState.OFF
    ) {
        key.label.uppercase(Locale.ROOT)
    } else {
        key.label
    }
    val gesture = when {
        key.type == KeyboardKeyType.SPACE -> Modifier.spacebarGesture(
            pointerKey = key.id,
            onTap = { currentOnPress.value() },
            onCursorMove = { currentOnCursorMove.value(it) },
            onPressedChange = { pressed = it },
            onHaptic = { view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP) },
        )
        key.type == KeyboardKeyType.CHARACTER && accents.isNotEmpty() -> Modifier.accentGesture(
            pointerKey = key.id,
            variantCount = accents.size,
            onTap = { currentOnPress.value() },
            onVariant = { index -> currentOnCommitText.value(accents[index]) },
            onPressedChange = { pressed = it },
            onAccentIndex = { accentIndex = it },
            onHaptic = { view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP) },
        )
        else -> Modifier.keyGesture(
            pointerKey = key.id,
            repeat = key.type == KeyboardKeyType.DELETE,
            onPress = { currentOnPress.value() },
            onPressedChange = { pressed = it },
            onHaptic = { view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP) },
        )
    }

    Box(
        modifier = modifier
            .height(keyHeight)
            .shadow(1.dp, RoundedCornerShape(7.dp))
            .clip(RoundedCornerShape(7.dp))
            .background(if (pressed) background.copy(alpha = 0.72f) else background)
            .semantics {
                role = Role.Button
                contentDescription = keyDescription(key, previewLabel, editor.returnKey, state.shift)
                onClick {
                    currentOnPress.value()
                    true
                }
            }
            .then(gesture),
        contentAlignment = Alignment.Center,
    ) {
        KeyContent(
            key = key,
            displayLabel = previewLabel,
            shift = state.shift,
            returnKey = editor.returnKey,
            tint = foreground,
        )

        if (pressed && key.type == KeyboardKeyType.CHARACTER) {
            Popup(
                alignment = Alignment.TopCenter,
                offset = IntOffset(0, previewOffset),
                properties = PopupProperties(focusable = false, clippingEnabled = false),
            ) {
                if (accentIndex >= 0 && accents.isNotEmpty()) {
                    Surface(
                        shape = RoundedCornerShape(9.dp),
                        color = MaterialTheme.colorScheme.surfaceContainerHighest,
                        shadowElevation = 5.dp,
                    ) {
                        Row(Modifier.padding(horizontal = 6.dp, vertical = 4.dp)) {
                            accents.forEachIndexed { index, glyph ->
                                Box(
                                    modifier = Modifier
                                        .padding(2.dp)
                                        .clip(RoundedCornerShape(6.dp))
                                        .background(
                                            if (index == accentIndex) {
                                                MaterialTheme.colorScheme.primaryContainer
                                            } else {
                                                Color.Transparent
                                            },
                                        )
                                        .padding(horizontal = 8.dp, vertical = 6.dp),
                                ) {
                                    Text(glyph, fontSize = 20.sp, color = foreground)
                                }
                            }
                        }
                    }
                } else {
                    Surface(
                        modifier = Modifier.size(width = 42.dp, height = 52.dp),
                        shape = RoundedCornerShape(9.dp),
                        color = MaterialTheme.colorScheme.surfaceContainerHighest,
                        shadowElevation = 5.dp,
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Text(previewLabel, fontSize = 27.sp, color = foreground)
                        }
                    }
                }
            }
        }
    }
}

private fun Modifier.keyGesture(
    pointerKey: String,
    repeat: Boolean,
    onPress: () -> Unit,
    onPressedChange: (Boolean) -> Unit,
    onHaptic: () -> Unit,
) = pointerInput(pointerKey, repeat) {
    coroutineScope {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            down.consume()
            onPressedChange(true)
            onHaptic()
            if (repeat) onPress()
            val repeatJob = if (repeat) {
                launch {
                    delay(380L)
                    while (isActive) {
                        onPress()
                        delay(55L)
                    }
                }
            } else {
                null
            }
            val up = waitForUpOrCancellation()
            repeatJob?.cancel()
            onPressedChange(false)
            if (!repeat && up != null) onPress()
        }
    }
}

private fun Modifier.spacebarGesture(
    pointerKey: String,
    onTap: () -> Unit,
    onCursorMove: (Int) -> Unit,
    onPressedChange: (Boolean) -> Unit,
    onHaptic: () -> Unit,
) = pointerInput(pointerKey) {
    val step = 18.dp.toPx()
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        down.consume()
        onPressedChange(true)
        onHaptic()
        var lastX = down.position.x
        var accumulated = 0f
        var dragged = false
        while (true) {
            val event = awaitPointerEvent()
            val change = event.changes.firstOrNull { it.id == down.id } ?: break
            if (!change.pressed) {
                change.consume()
                break
            }
            accumulated += change.position.x - lastX
            lastX = change.position.x
            if (abs(accumulated) >= step) {
                val positions = (accumulated / step).toInt()
                onCursorMove(positions)
                onHaptic()
                accumulated -= positions * step
                dragged = true
            }
            change.consume()
        }
        onPressedChange(false)
        if (!dragged) onTap()
    }
}

private fun Modifier.accentGesture(
    pointerKey: String,
    variantCount: Int,
    onTap: () -> Unit,
    onVariant: (Int) -> Unit,
    onPressedChange: (Boolean) -> Unit,
    onAccentIndex: (Int) -> Unit,
    onHaptic: () -> Unit,
) = pointerInput(pointerKey, variantCount) {
    val step = 28.dp.toPx()
    coroutineScope {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            down.consume()
            onPressedChange(true)
            onHaptic()
            var showing = false
            var index = 0
            val hold = launch {
                delay(380L)
                showing = true
                onAccentIndex(0)
                onHaptic()
            }
            while (true) {
                val event = awaitPointerEvent()
                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                if (!change.pressed) {
                    change.consume()
                    break
                }
                if (showing) {
                    val delta = change.position.x - down.position.x
                    val next = (delta / step).toInt().coerceIn(0, variantCount - 1)
                    if (next != index) {
                        index = next
                        onAccentIndex(index)
                        onHaptic()
                    }
                }
                change.consume()
            }
            hold.cancel()
            onPressedChange(false)
            if (showing) {
                onVariant(index)
            } else {
                onTap()
            }
            onAccentIndex(-1)
        }
    }
}

@Composable
private fun KeyContent(
    key: KeyboardKey,
    displayLabel: String,
    shift: ShiftState,
    returnKey: ReturnKeyKind,
    tint: Color,
) {
    when (key.type) {
        KeyboardKeyType.SHIFT -> KeyboardIcon(
            if (shift == ShiftState.LOCKED) Glyph.CAPS_LOCK else Glyph.SHIFT,
            tint,
        )
        KeyboardKeyType.DELETE -> KeyboardIcon(Glyph.DELETE, tint)
        KeyboardKeyType.RETURN -> when (returnKey) {
            ReturnKeyKind.ENTER -> KeyboardIcon(Glyph.ENTER, tint)
            ReturnKeyKind.SEARCH -> KeyboardIcon(Glyph.SEARCH, tint)
            ReturnKeyKind.NEXT -> KeyboardIcon(Glyph.NEXT, tint)
            ReturnKeyKind.PREVIOUS -> KeyboardIcon(Glyph.PREVIOUS, tint)
            ReturnKeyKind.DONE -> KeyboardIcon(Glyph.DONE, tint)
            ReturnKeyKind.GO -> KeyLabel("Go", tint, utility = true)
            ReturnKeyKind.SEND -> KeyLabel("Send", tint, utility = true)
        }
        KeyboardKeyType.SPACE -> KeyLabel("VocaPhone", tint.copy(alpha = 0.78f), utility = true)
        KeyboardKeyType.LAYER_SWITCH -> KeyLabel(displayLabel, tint, utility = true)
        KeyboardKeyType.CHARACTER -> KeyLabel(displayLabel, tint, utility = false)
    }
}

@Composable
private fun KeyLabel(text: String, color: Color, utility: Boolean) {
    Text(
        text = text,
        color = color,
        fontSize = if (utility) 13.sp else 22.sp,
        fontWeight = if (utility) FontWeight.Medium else FontWeight.Normal,
    )
}

private enum class Glyph {
    MIC,
    STOP,
    SHIFT,
    CAPS_LOCK,
    DELETE,
    GLOBE,
    ENTER,
    SEARCH,
    NEXT,
    PREVIOUS,
    DONE,
    CLIPBOARD,
}

@Composable
private fun KeyboardIcon(
    glyph: Glyph,
    tint: Color,
    modifier: Modifier = Modifier.size(23.dp),
) {
    Canvas(modifier) {
        val stroke = Stroke(
            width = 1.9.dp.toPx(),
            cap = StrokeCap.Round,
            join = StrokeJoin.Round,
        )
        val w = size.width
        val h = size.height
        when (glyph) {
            Glyph.MIC -> {
                drawRoundRect(
                    color = tint,
                    topLeft = Offset(w * 0.34f, h * 0.08f),
                    size = Size(w * 0.32f, h * 0.52f),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(w * 0.16f),
                    style = stroke,
                )
                drawArc(
                    color = tint,
                    startAngle = 0f,
                    sweepAngle = 180f,
                    useCenter = false,
                    topLeft = Offset(w * 0.2f, h * 0.3f),
                    size = Size(w * 0.6f, h * 0.45f),
                    style = stroke,
                )
                drawLine(tint, Offset(w * 0.5f, h * 0.75f), Offset(w * 0.5f, h * 0.91f), stroke.width)
                drawLine(tint, Offset(w * 0.34f, h * 0.91f), Offset(w * 0.66f, h * 0.91f), stroke.width)
            }
            Glyph.STOP -> drawRoundRect(
                color = tint,
                topLeft = Offset(w * 0.27f, h * 0.27f),
                size = Size(w * 0.46f, h * 0.46f),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(2.dp.toPx()),
            )
            Glyph.SHIFT, Glyph.CAPS_LOCK -> {
                val path = Path().apply {
                    moveTo(w * 0.16f, h * 0.48f)
                    lineTo(w * 0.5f, h * 0.13f)
                    lineTo(w * 0.84f, h * 0.48f)
                    lineTo(w * 0.65f, h * 0.48f)
                    lineTo(w * 0.65f, h * 0.83f)
                    lineTo(w * 0.35f, h * 0.83f)
                    lineTo(w * 0.35f, h * 0.48f)
                    close()
                }
                drawPath(path, tint, style = stroke)
                if (glyph == Glyph.CAPS_LOCK) {
                    drawLine(tint, Offset(w * 0.32f, h * 0.96f), Offset(w * 0.68f, h * 0.96f), stroke.width)
                }
            }
            Glyph.DELETE -> {
                val path = Path().apply {
                    moveTo(w * 0.08f, h * 0.5f)
                    lineTo(w * 0.3f, h * 0.22f)
                    lineTo(w * 0.9f, h * 0.22f)
                    lineTo(w * 0.9f, h * 0.78f)
                    lineTo(w * 0.3f, h * 0.78f)
                    close()
                }
                drawPath(path, tint, style = stroke)
                drawLine(tint, Offset(w * 0.48f, h * 0.38f), Offset(w * 0.72f, h * 0.62f), stroke.width)
                drawLine(tint, Offset(w * 0.72f, h * 0.38f), Offset(w * 0.48f, h * 0.62f), stroke.width)
            }
            Glyph.GLOBE -> {
                drawCircle(tint, radius = w * 0.4f, style = stroke)
                drawOval(tint, topLeft = Offset(w * 0.34f, h * 0.1f), size = Size(w * 0.32f, h * 0.8f), style = stroke)
                drawLine(tint, Offset(w * 0.12f, h * 0.5f), Offset(w * 0.88f, h * 0.5f), stroke.width)
            }
            Glyph.ENTER -> {
                drawLine(tint, Offset(w * 0.83f, h * 0.23f), Offset(w * 0.83f, h * 0.62f), stroke.width)
                drawLine(tint, Offset(w * 0.83f, h * 0.62f), Offset(w * 0.25f, h * 0.62f), stroke.width)
                drawLine(tint, Offset(w * 0.25f, h * 0.62f), Offset(w * 0.43f, h * 0.44f), stroke.width)
                drawLine(tint, Offset(w * 0.25f, h * 0.62f), Offset(w * 0.43f, h * 0.8f), stroke.width)
            }
            Glyph.SEARCH -> {
                drawCircle(tint, center = Offset(w * 0.44f, h * 0.42f), radius = w * 0.26f, style = stroke)
                drawLine(tint, Offset(w * 0.63f, h * 0.62f), Offset(w * 0.86f, h * 0.85f), stroke.width)
            }
            Glyph.NEXT, Glyph.PREVIOUS -> {
                val direction = if (glyph == Glyph.NEXT) 1f else -1f
                val start = if (direction > 0) w * 0.25f else w * 0.75f
                val end = if (direction > 0) w * 0.75f else w * 0.25f
                drawLine(tint, Offset(start, h * 0.5f), Offset(end, h * 0.5f), stroke.width)
                drawLine(tint, Offset(end, h * 0.5f), Offset(end - direction * w * 0.2f, h * 0.3f), stroke.width)
                drawLine(tint, Offset(end, h * 0.5f), Offset(end - direction * w * 0.2f, h * 0.7f), stroke.width)
            }
            Glyph.DONE -> {
                drawLine(tint, Offset(w * 0.15f, h * 0.52f), Offset(w * 0.42f, h * 0.78f), stroke.width)
                drawLine(tint, Offset(w * 0.42f, h * 0.78f), Offset(w * 0.86f, h * 0.26f), stroke.width)
            }
            Glyph.CLIPBOARD -> {
                drawRoundRect(
                    color = tint,
                    topLeft = Offset(w * 0.22f, h * 0.22f),
                    size = Size(w * 0.56f, h * 0.68f),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(2.dp.toPx()),
                    style = stroke,
                )
                drawRoundRect(
                    color = tint,
                    topLeft = Offset(w * 0.34f, h * 0.1f),
                    size = Size(w * 0.32f, h * 0.2f),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(1.5.dp.toPx()),
                    style = stroke,
                )
                drawLine(tint, Offset(w * 0.34f, h * 0.48f), Offset(w * 0.66f, h * 0.48f), stroke.width)
                drawLine(tint, Offset(w * 0.34f, h * 0.64f), Offset(w * 0.58f, h * 0.64f), stroke.width)
            }
        }
    }
}

private fun keyDescription(
    key: KeyboardKey,
    displayLabel: String,
    returnKey: ReturnKeyKind,
    shift: ShiftState,
): String = when (key.type) {
    KeyboardKeyType.CHARACTER -> displayLabel
    KeyboardKeyType.SHIFT -> when (shift) {
        ShiftState.OFF -> "Shift"
        ShiftState.ONCE -> "Shift on"
        ShiftState.LOCKED -> "Caps lock on"
    }
    KeyboardKeyType.DELETE -> "Delete"
    KeyboardKeyType.SPACE -> "Space. Swipe left or right to move the cursor."
    KeyboardKeyType.RETURN -> when (returnKey) {
        ReturnKeyKind.ENTER -> "Enter"
        ReturnKeyKind.GO -> "Go"
        ReturnKeyKind.NEXT -> "Next"
        ReturnKeyKind.SEARCH -> "Search"
        ReturnKeyKind.SEND -> "Send"
        ReturnKeyKind.DONE -> "Done"
        ReturnKeyKind.PREVIOUS -> "Previous"
    }
    KeyboardKeyType.LAYER_SWITCH -> when (key.targetLayer) {
        KeyboardLayer.EMOJI -> "Show emoji keyboard"
        KeyboardLayer.LETTERS -> "Show letters keyboard"
        KeyboardLayer.NUMBERS -> "Show numbers keyboard"
        KeyboardLayer.SYMBOLS -> "Show symbols keyboard"
        null -> "Switch keyboard layer"
    }
}

private fun formatDuration(millis: Long): String {
    val totalSeconds = (millis / 1_000).coerceAtLeast(0)
    val seconds = (totalSeconds % 60).toString().padStart(2, '0')
    return "${totalSeconds / 60}:$seconds"
}
