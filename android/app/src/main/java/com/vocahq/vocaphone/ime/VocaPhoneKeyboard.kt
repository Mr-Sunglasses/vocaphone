package com.vocahq.vocaphone.ime

import android.graphics.BitmapFactory
import android.os.SystemClock
import android.view.HapticFeedbackConstants
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
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
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.runtime.MutableState
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import com.vocahq.vocaphone.R
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
import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.core.ModelLanguageSupport
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.core.WritingStyle
import com.vocahq.vocaphone.settings.ClipboardHistory
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import java.io.File
import com.vocahq.vocaphone.ui.theme.VocaPhoneTheme
import kotlin.math.PI
import kotlin.math.sin
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.roundToInt
import java.util.Locale

private enum class PreferencePanel {
    MENU,
    LANGUAGE,
    STYLE,
    CLIPBOARD,
}

@Composable
internal fun VocaPhoneKeyboard(
    dictationState: DictationState,
    editor: KeyboardEditorConfig,
    settings: VocaPhoneSettings,
    isPreferenceWritePending: Boolean,
    clipboard: ClipboardChip?,
    editorText: EditorTextWindow,
    suggestions: SuggestionDictionary?,
    emojiCatalog: List<EmojiEntry>,
    onCommand: (KeyboardCommand) -> Unit,
    onMicTap: () -> Unit,
    onOpenApp: () -> Unit,
    onOpenSettings: (String) -> Unit,
    onLanguageSelected: (TranscriptionLanguage) -> Unit,
    onStyleSelected: (WritingStyle) -> Unit,
    onSuggestionPicked: (String, Boolean) -> Unit,
    onEmojiSuggestion: (String) -> Unit,
    onPasteClipboard: (String) -> Unit,
    onDismissClipboard: () -> Unit,
    onRemoveClipboardHistory: (String) -> Unit,
    onClearClipboardHistory: () -> Unit,
    onEmojiUsed: (String) -> Unit,
) {
    // One set of state holders for the life of the composition, reset when the
    // editor changes rather than rebuilt.
    //
    // These were all `remember(editor.sessionId)`, which built a *new*
    // MutableState for every editor. The callbacks further down are remembered
    // without keys so that forty keys can skip recomposition, and the Compose
    // compiler memoizes the `::handleKey` reference handed to
    // `rememberUpdatedState` along with them. So from the second editor onward
    // the key handlers read and wrote the state objects belonging to the
    // session they were built in, while the keyboard drew from the new ones.
    //
    // That is why this looked like "only the layer keys are broken". Tapping
    // `?123` did run the reducer and did set the layer — on an orphaned state
    // that nothing rendered, so no recomposition followed and the key looked
    // dead. Letters were unaffected because a character reaches the editor
    // through `onCommand`, which never goes near this state. Caps lock went the
    // same way as the layer, for the same reason.
    var keyboardState by remember {
        mutableStateOf(
            KeyboardState(
                layer = editor.initialLayer,
                shift = editor.initialShift,
            ),
        )
    }
    var preferencePanel by remember { mutableStateOf<PreferencePanel?>(null) }
    var emojiCategory by remember { mutableStateOf(EmojiCategory.SMILEYS) }
    var swipeChoices by remember { mutableStateOf<List<String>>(emptyList()) }
    var swipeWord by remember { mutableStateOf<String?>(null) }
    var suggestionStrip by remember { mutableStateOf(SuggestionStrip(emptyList())) }

    // The one place a new editor wipes the keyboard. Replacing the holders did
    // this implicitly and broke the handlers that had closed over them.
    LaunchedEffect(editor.sessionId) {
        keyboardState = KeyboardState(
            layer = editor.initialLayer,
            shift = editor.initialShift,
        )
        preferencePanel = null
        emojiCategory = EmojiCategory.SMILEYS
        swipeChoices = emptyList()
        swipeWord = null
        suggestionStrip = SuggestionStrip(emptyList())
    }

    LaunchedEffect(dictationState.phase, editor.dictationAllowed) {
        if (dictationState.phase != DictationPhase.IDLE || !editor.dictationAllowed) {
            preferencePanel = null
        }
    }
    LaunchedEffect(editor.shiftSync) {
        if (editor.shiftSync > 0) {
            keyboardState = keyboardState.copy(
                shift = KeyboardChrome.shiftAfterCursorSync(
                    current = keyboardState.shift,
                    atCursor = editor.initialShift,
                ),
            )
        }
    }
    LaunchedEffect(editor.cursorSync) {
        if (editor.cursorSync > 0) {
            // Both flags describe the character the cursor was sitting after,
            // and it is no longer sitting there. Left set, the next space
            // capitalizes because of a period somewhere else in the field.
            keyboardState = keyboardState.copy(
                composing = "",
                capitalizeAfterSpace = false,
                lastWasSpace = false,
            )
        }
    }
    LaunchedEffect(settings.asciiEmojiEnabled, emojiCategory) {
        if (!settings.asciiEmojiEnabled && emojiCategory == EmojiCategory.ASCII) {
            emojiCategory = EmojiCategory.SMILEYS
        }
    }

    val composeWords = settings.suggestionsEnabled && !editor.sensitive
    val keyHeight = settings.keyboardHeight.keyHeightDp.dp
    val letterRows = KeyboardLayouts.letterRowCount(settings.numberRowEnabled)
    val keyAreaHeight = keyHeight * letterRows + RowGap * (letterRows - 1)
    // Worked out off the composition thread, and off the frame the keystroke
    // that triggered it is drawn in.
    //
    // This was a `remember` block, so every keystroke ran a dictionary lookup
    // inside composition and the key could not paint until it returned. The
    // cost landed unevenly, which is what made it feel like a stutter rather
    // than a constant delay: a prefix that happens to be a word skips the
    // correction scan, and a prefix that does not — most of them, mid-word —
    // paid for it.
    //
    // LaunchedEffect gives the conflation for free. Its keys change on the next
    // keystroke, which cancels a scan still running for the previous one, so a
    // fast typist computes a strip for the word they stopped on rather than for
    // every letter on the way there.
    //
    // The trade is that the strip is one frame behind the key, so for that
    // frame it offers the previous keystroke's words. Tapping one in that
    // window would commit a suggestion for the word as it was a letter ago —
    // reachable in principle, sixteen milliseconds wide in practice, and the
    // same trade every keyboard that does this off the main thread makes.
    LaunchedEffect(
        composeWords,
        settings.correctionsEnabled,
        keyboardState.composing,
        editorText,
        suggestions,
    ) {
        suggestionStrip = if (!composeWords || suggestions == null) {
            SuggestionStrip(emptyList())
        } else {
            withContext(Dispatchers.Default) {
                suggestions.strip(
                    composing = keyboardState.composing,
                    before = editorText.before,
                    after = editorText.after,
                    correctionsEnabled = settings.correctionsEnabled,
                )
            }
        }
    }
    val clipboardChip = clipboard.takeIf { settings.clipboardChipEnabled && !editor.sensitive }
    val startedTyping = KeyboardChrome.startedTyping(keyboardState.composing, editorText.before)
    val stripClipboard = KeyboardChrome.clipboardForStrip(clipboardChip, startedTyping)
    val swipeArmed = KeyboardChrome.swipeWordArmed(swipeWord, editorText.before, editorText.after)
    val stripSuggestions = if (swipeArmed && swipeChoices.isNotEmpty()) {
        swipeChoices.map { SuggestionItem(it) }
    } else {
        KeyboardChrome.suggestionsForStrip(suggestionStrip.items, startedTyping)
    }
    val swipeReplacesWord = swipeArmed && swipeChoices.isNotEmpty()

    fun clearSwipe() {
        swipeChoices = emptyList()
        swipeWord = null
    }

    fun handleDelete(heldMs: Long) {
        val swipeUndo = heldMs == 0L && swipeArmed
        if (heldMs == 0L) {
            swipeChoices = emptyList()
            if (swipeUndo) swipeWord = null
        }
        val stage = DeleteHold.stage(heldMs)
        if (composeWords && keyboardState.composing.isNotEmpty()) {
            if (stage == DeleteHold.Stage.CHAR && !swipeUndo) {
                val reduction = KeyboardReducer.press(
                    state = keyboardState,
                    key = KeyboardKey("delete", "Delete", type = KeyboardKeyType.DELETE),
                    nowMillis = SystemClock.uptimeMillis(),
                    composeWords = true,
                )
                keyboardState = reduction.state
                reduction.command?.let(onCommand)
            } else {
                keyboardState = keyboardState.copy(
                    composing = "",
                    lastWasSpace = false,
                    capitalizeAfterSpace = false,
                )
                onCommand(KeyboardCommand.SetComposingText(""))
            }
            return
        }
        val command = DeleteHold.command(
            heldMs = heldMs,
            swipeUndo = swipeUndo,
            before = editorText.before,
            after = editorText.after,
        )
        keyboardState = keyboardState.copy(
            composing = "",
            lastWasSpace = false,
            capitalizeAfterSpace = false,
        )
        onCommand(command)
    }

    fun handleKey(key: KeyboardKey) {
        if (key.type == KeyboardKeyType.DELETE) {
            handleDelete(0L)
            return
        }
        if (
            key.type == KeyboardKeyType.CHARACTER ||
            key.type == KeyboardKeyType.SPACE ||
            key.type == KeyboardKeyType.RETURN
        ) {
            clearSwipe()
        }
        if (
            key.type == KeyboardKeyType.SHIFT &&
            editorText.selected.any { it.isLetter() }
        ) {
            keyboardState = keyboardState.copy(composing = "")
            onCommand(KeyboardCommand.CycleSelectionCase)
            return
        }
        val reduction = KeyboardReducer.press(
            state = keyboardState,
            key = key,
            nowMillis = SystemClock.uptimeMillis(),
            composeWords = composeWords,
        )
        keyboardState = reduction.state
        reduction.command?.let(onCommand)
    }

    fun applySwipe(matches: List<String>, similar: List<String>) {
        if (matches.isEmpty()) return
        if (keyboardState.composing.isNotEmpty()) {
            onCommand(KeyboardCommand.SetComposingText(""))
        }
        val capitalize = keyboardState.shift != ShiftState.OFF
        fun cased(word: String) = if (capitalize) word.replaceFirstChar { it.uppercase() } else word
        val chosen = cased(matches.first())
        swipeWord = chosen
        swipeChoices = KeyboardChrome.swipeAlternatives(
            committed = chosen,
            swipeMatches = matches.map(::cased),
            similar = similar.map(::cased),
        )
        keyboardState = keyboardState.copy(
            composing = "",
            lastWasSpace = true,
            capitalizeAfterSpace = false,
            shift = if (keyboardState.shift == ShiftState.LOCKED) ShiftState.LOCKED else ShiftState.OFF,
        )
        onSuggestionPicked(chosen, false)
    }

    // Finished gestures, handed over rather than resolved in place.
    //
    // Matching a swipe walks the whole word list twice, and it used to do that
    // on the thread delivering the pointer events. The keyboard stopped reading
    // the screen for as long as it took, so a second swipe started during that
    // window went nowhere at all: no letters, no feedback, the gesture simply
    // swallowed. That is the "hidden cooldown" it felt like from the outside.
    //
    // A channel with one consumer keeps that work off this thread while still
    // applying results in the order the gestures were made, so swiping two
    // words in quick succession still writes them down in that order.
    val swipePaths = remember { Channel<String>(Channel.UNLIMITED) }

    fun handleSwipe(path: String) {
        swipePaths.trySend(path)
    }

    // The consumer below outlives the composition that started it, so it has to
    // reach the current `applySwipe` rather than the one it closed over: that
    // one still holds the `onCommand` and `onSuggestionPicked` it was handed.
    val latestApplySwipe by rememberUpdatedState<(List<String>, List<String>) -> Unit>(::applySwipe)

    LaunchedEffect(suggestions) {
        val dictionary = suggestions ?: return@LaunchedEffect
        for (path in swipePaths) {
            val resolved = withContext(Dispatchers.Default) {
                val matches = dictionary.swipe(path)
                matches to if (matches.isEmpty()) {
                    emptyList()
                } else {
                    dictionary.similar(matches.first())
                }
            }
            latestApplySwipe(resolved.first, resolved.second)
        }
    }

    // Callbacks with an identity that survives recomposition.
    //
    // Compose can only skip a child whose inputs are unchanged, and a local
    // function reference is a fresh object every time this composable runs. So
    // every keystroke handed all forty keys a new `onKey`, and all forty
    // rebuilt their modifier chain, semantics and label for it — even though a
    // letter changes nothing a key draws. `remember` with no keys pins the
    // identity; `rememberUpdatedState` keeps the body current.
    val latestKey by rememberUpdatedState<(KeyboardKey) -> Unit>(::handleKey)
    val latestDelete by rememberUpdatedState<(Long) -> Unit>(::handleDelete)
    val latestSwipe by rememberUpdatedState<(String) -> Unit>(::handleSwipe)
    val latestCursorMove by rememberUpdatedState<(Int) -> Unit> { positions ->
        clearSwipe()
        keyboardState = keyboardState.copy(composing = "", lastWasSpace = false)
        onCommand(KeyboardCommand.MoveCursor(positions))
    }
    val latestEmojiUsed by rememberUpdatedState(onEmojiUsed)
    val onKeyStable = remember { { key: KeyboardKey -> latestKey(key) } }
    val onSwipeStable = remember { { path: String -> latestSwipe(path) } }
    val onCursorMoveStable = remember { { positions: Int -> latestCursorMove(positions) } }
    val onKeyHoldStable = remember {
        { key: KeyboardKey, heldMs: Long ->
            if (key.type == KeyboardKeyType.DELETE) latestDelete(heldMs)
        }
    }
    val onEmojiStable = remember {
        { glyph: String ->
            latestKey(KeyboardKey(id = "emoji-$glyph", label = glyph, output = glyph))
            latestEmojiUsed(glyph)
        }
    }

    VocaPhoneTheme {
        Surface(
            color = MaterialTheme.colorScheme.surfaceContainerLowest,
            contentColor = MaterialTheme.colorScheme.onSurface,
        ) {
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                val widthDp = maxWidth.value.roundToInt()
                val splitKeys = SplitKeyboardLayout.shouldSplit(settings.splitKeyboard, widthDp)
                val spacerFraction = SplitKeyboardLayout.spacerFraction(widthDp)
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
                    asciiEmojiEnabled = settings.asciiEmojiEnabled,
                    onEmojiCategory = { emojiCategory = it },
                    onMicTap = onMicTap,
                    onOpenApp = onOpenApp,
                    menuOpen = preferencePanel == PreferencePanel.MENU,
                    onMenuTap = {
                        preferencePanel = if (preferencePanel == PreferencePanel.MENU) {
                            null
                        } else {
                            PreferencePanel.MENU
                        }
                    },
                    onPaste = { onPasteClipboard(clipboardChip?.fullText.orEmpty()) },
                    onDismissClipboard = onDismissClipboard,
                    onSuggestion = { item ->
                        if (item.isEmoji) {
                            clearSwipe()
                            keyboardState = keyboardState.copy(
                                composing = "",
                                lastWasSpace = false,
                            )
                            onEmojiSuggestion(item.text)
                        } else {
                            val replace = KeyboardChrome.suggestionReplacesWord(
                                composing = keyboardState.composing,
                                swipeChoicesActive = swipeReplacesWord,
                                stripReplacesWord = suggestionStrip.replacesWord,
                            )
                            swipeChoices = emptyList()
                            swipeWord = if (replace) item.text else null
                            keyboardState = keyboardState.copy(
                                composing = "",
                                lastWasSpace = true,
                                capitalizeAfterSpace = false,
                            )
                            onSuggestionPicked(item.text, replace)
                        }
                    },
                )
                Spacer(Modifier.height(4.dp))
                when (preferencePanel) {
                    PreferencePanel.MENU -> ToolbarMenuPanel(
                        clipboardOn = settings.clipboardHistoryEnabled && !editor.sensitive,
                        height = keyAreaHeight,
                        onLanguage = { preferencePanel = PreferencePanel.LANGUAGE },
                        onStyle = { preferencePanel = PreferencePanel.STYLE },
                        onClipboard = { preferencePanel = PreferencePanel.CLIPBOARD },
                        onOpenSettings = { page ->
                            preferencePanel = null
                            onOpenSettings(page)
                        },
                        onClose = { preferencePanel = null },
                    )
                    PreferencePanel.CLIPBOARD -> ClipboardHistoryPanel(
                        items = settings.clipboardHistory,
                        height = keyAreaHeight,
                        enabled = !isPreferenceWritePending,
                        onPaste = { text ->
                            preferencePanel = null
                            onPasteClipboard(text)
                        },
                        onRemove = onRemoveClipboardHistory,
                        onClear = onClearClipboardHistory,
                        onClose = { preferencePanel = null },
                    )
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
                            shift = keyboardState.shift,
                            layer = keyboardState.layer,
                            catalog = emojiCatalog,
                            recents = settings.emojiRecents,
                            category = emojiCategory,
                            split = splitKeys,
                            spacerFraction = spacerFraction,
                            onEmoji = onEmojiStable,
                            onKey = onKeyStable,
                            onKeyHold = onKeyHoldStable,
                            onCursorMove = onCursorMoveStable,
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
                            shift = keyboardState.shift,
                            layer = keyboardState.layer,
                            editor = editor,
                            keyHeight = fittedKeyHeight,
                            showKeyHints = settings.numberKeyHintsEnabled,
                            split = splitKeys,
                            spacerFraction = spacerFraction,
                            swipeEnabled = settings.swipeTypingEnabled &&
                                keyboardState.layer == KeyboardLayer.LETTERS,
                            onSwipe = onSwipeStable,
                            onKey = onKeyStable,
                            onKeyHold = onKeyHoldStable,
                            onCursorMove = onCursorMoveStable,
                        )
                    }
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
    suggestions: List<SuggestionItem>,
    emojiCategory: EmojiCategory?,
    hasEmojiRecents: Boolean,
    asciiEmojiEnabled: Boolean,
    onEmojiCategory: (EmojiCategory) -> Unit,
    onMicTap: () -> Unit,
    onOpenApp: () -> Unit,
    menuOpen: Boolean,
    onMenuTap: () -> Unit,
    onPaste: () -> Unit,
    onDismissClipboard: () -> Unit,
    onSuggestion: (SuggestionItem) -> Unit,
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
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(
                    if (menuOpen) {
                        MaterialTheme.colorScheme.surfaceContainerHighest
                    } else {
                        MaterialTheme.colorScheme.surfaceContainerHigh
                    },
                )
                .semantics {
                    role = Role.Button
                    contentDescription = "Keyboard menu. Long press to open VocaPhone."
                }
                .pointerInput(idle, menuOpen) {
                    detectTapGestures(
                        onTap = {
                            view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                            if (idle) onMenuTap()
                        },
                        onLongPress = {
                            view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                            onOpenApp()
                        },
                    )
                },
            contentAlignment = Alignment.Center,
        ) {
            KeyboardIcon(
                glyph = Glyph.SETTINGS,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp),
            )
        }

        Row(
            modifier = Modifier
                .weight(1f)
                .semantics { liveRegion = LiveRegionMode.Polite },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            when {
                !idle || !editor.dictationAllowed -> {
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxHeight(),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (state.isRecording) {
                            Waveform(
                                level = state.level,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(34.dp),
                                alpha = 0.34f,
                                bars = 13,
                            )
                        }
                        Column(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            Text(
                                text = status,
                                modifier = Modifier.fillMaxWidth(),
                                style = MaterialTheme.typography.labelLarge,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                textAlign = TextAlign.Center,
                            )
                            if (detail.isNotEmpty()) {
                                Text(
                                    text = detail,
                                    modifier = Modifier.fillMaxWidth(),
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    style = MaterialTheme.typography.labelSmall,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    textAlign = TextAlign.Center,
                                )
                            }
                        }
                    }
                }
                emojiCategory != null -> EmojiCategoryRow(
                    selected = emojiCategory,
                    hasRecents = hasEmojiRecents,
                    asciiEmojiEnabled = asciiEmojiEnabled,
                    onSelect = onEmojiCategory,
                    modifier = Modifier.weight(1f),
                )
                clipboard != null -> ClipboardChipButton(
                    preview = clipboard.preview,
                    imagePath = clipboard.imagePath,
                    onClick = onPaste,
                    onLongClick = onDismissClipboard,
                    modifier = Modifier.weight(1f),
                )
                suggestions.isNotEmpty() -> SuggestionStripRow(
                    suggestions = suggestions,
                    onSuggestion = onSuggestion,
                )
                else -> Spacer(Modifier.weight(1f))
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
private fun ToolbarMenuPanel(
    clipboardOn: Boolean,
    height: Dp,
    onLanguage: () -> Unit,
    onStyle: () -> Unit,
    onClipboard: () -> Unit,
    onOpenSettings: (String) -> Unit,
    onClose: () -> Unit,
) {
    PreferencePanelShell(
        title = "Keyboard",
        subtitle = "Tiles open a panel or the app.",
        height = height,
        onClose = onClose,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            listOf(
                listOf(
                    MenuTile("Language", R.drawable.ic_language, onLanguage),
                    MenuTile("Style", R.drawable.ic_style, onStyle),
                    MenuTile(
                        "Clipboard",
                        R.drawable.ic_clipboard,
                        if (clipboardOn) onClipboard else ({ onOpenSettings("keyboard") }),
                    ),
                ),
                listOf(
                    MenuTile("Models", R.drawable.ic_models) { onOpenSettings("models") },
                    MenuTile("Keyboard", R.drawable.ic_keyboard) { onOpenSettings("keyboard") },
                    MenuTile("Dictation", R.drawable.ic_dictation) { onOpenSettings("dictation") },
                ),
                listOf(
                    MenuTile("Speech", R.drawable.ic_connection) { onOpenSettings("connection") },
                    MenuTile("About", R.drawable.ic_about) { onOpenSettings("about") },
                    MenuTile("App", R.drawable.ic_settings) { onOpenSettings("") },
                ),
            ).forEach { row ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    row.forEach { tile ->
                        ToolbarMenuTile(title = tile.title, icon = tile.icon, onClick = tile.onClick)
                    }
                }
            }
        }
    }
}

private data class MenuTile(
    val title: String,
    val icon: Int,
    val onClick: () -> Unit,
)

@Composable
private fun RowScope.ToolbarMenuTile(
    title: String,
    icon: Int,
    onClick: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .weight(1f)
            .fillMaxHeight(),
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        onClick = onClick,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 4.dp, vertical = 4.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
        ) {
            Icon(
                painter = painterResource(icon),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(20.dp),
            )
            Text(
                title,
                fontWeight = FontWeight.Medium,
                fontSize = 11.sp,
                lineHeight = 14.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun ClipboardHistoryPanel(
    items: List<String>,
    height: Dp,
    enabled: Boolean,
    onPaste: (String) -> Unit,
    onRemove: (String) -> Unit,
    onClear: () -> Unit,
    onClose: () -> Unit,
) {
    PreferencePanelShell(
        title = "Clipboard",
        subtitle = if (items.isEmpty()) {
            "Copy text or an image to save it here"
        } else {
            "Tap to paste. Long press to remove."
        },
        height = height,
        onClose = onClose,
    ) {
        if (items.isNotEmpty()) {
            TextButton(
                onClick = onClear,
                enabled = enabled,
                modifier = Modifier.align(Alignment.End),
            ) {
                Text("Clear", fontSize = 12.sp)
            }
        }
        if (items.isEmpty()) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    "Nothing saved yet",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 13.sp,
                )
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                items(items, key = { it.hashCode().toString() + it.take(12) }) { stored ->
                    val image = ClipboardHistory.parseImage(stored)
                    Surface(
                        modifier = Modifier
                            .fillMaxWidth()
                            .pointerInput(stored) {
                                detectTapGestures(
                                    onTap = { if (enabled) onPaste(stored) },
                                    onLongPress = { if (enabled) onRemove(stored) },
                                )
                            },
                        shape = RoundedCornerShape(8.dp),
                        color = MaterialTheme.colorScheme.surfaceContainerHigh,
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            if (image != null) {
                                ClipboardThumb(
                                    relativePath = image.second,
                                    modifier = Modifier
                                        .size(36.dp)
                                        .clip(RoundedCornerShape(6.dp)),
                                )
                            }
                            Text(
                                text = ClipboardHistory.preview(stored),
                                fontSize = 13.sp,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
        }
    }
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
                    .height(34.dp)
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
private fun Waveform(
    level: Float,
    modifier: Modifier = Modifier.size(width = 44.dp, height = 28.dp),
    alpha: Float = 1f,
    bars: Int = 7,
) {
    val color = MaterialTheme.colorScheme.primary.copy(alpha = alpha)
    val phase by rememberInfiniteTransition(label = "wave").animateFloat(
        initialValue = 0f,
        targetValue = (PI * 2).toFloat(),
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 650, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "phase",
    )
    Canvas(modifier) {
        val normalized = level.coerceIn(0.14f, 1f)
        val barWidth = 2.6.dp.toPx()
        val gap = if (bars <= 1) 0f else (size.width - barWidth * bars) / (bars - 1)
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
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier,
    imagePath: String? = null,
) {
    val view = LocalView.current
    var dismissing by remember(preview) { mutableStateOf(false) }
    LaunchedEffect(dismissing) {
        if (dismissing) {
            delay(180)
            onLongClick()
        }
    }
    AnimatedVisibility(
        visible = !dismissing,
        enter = fadeIn(),
        exit = fadeOut() + shrinkHorizontally(),
        modifier = modifier,
    ) {
    Surface(
        modifier = Modifier
            .height(32.dp)
            .semantics {
                role = Role.Button
                contentDescription = "Clipboard, $preview. Long press to dismiss."
            }
            .pointerInput(preview) {
                detectTapGestures(
                    onTap = { onClick() },
                    onLongPress = {
                        view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                        dismissing = true
                    },
                )
            },
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (imagePath != null) {
                ClipboardThumb(
                    relativePath = imagePath,
                    modifier = Modifier
                        .size(20.dp)
                        .clip(RoundedCornerShape(4.dp)),
                )
            } else {
                KeyboardIcon(
                    glyph = Glyph.CLIPBOARD,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(16.dp),
                )
            }
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
}

@Composable
private fun RowScope.SuggestionStripRow(
    suggestions: List<SuggestionItem>,
    onSuggestion: (SuggestionItem) -> Unit,
) {
    if (suggestions.size <= 3) {
        suggestions.forEach { item ->
            SuggestionChip(
                label = item.text,
                emoji = item.isEmoji,
                onClick = { onSuggestion(item) },
                modifier = Modifier.weight(1f),
            )
        }
        return
    }
    val scroll = rememberScrollState()
    val fade = MaterialTheme.colorScheme.surfaceContainerLowest
    Box(
        modifier = Modifier
            .weight(1f)
            .fillMaxHeight()
            .drawWithContent {
                drawContent()
                if (scroll.canScrollForward) {
                    drawRect(
                        brush = Brush.horizontalGradient(
                            0.82f to Color.Transparent,
                            1f to fade,
                        ),
                    )
                }
            },
    ) {
        Row(
            modifier = Modifier
                .fillMaxHeight()
                .horizontalScroll(scroll),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            suggestions.forEach { item ->
                SuggestionChip(
                    label = item.text,
                    emoji = item.isEmoji,
                    onClick = { onSuggestion(item) },
                    modifier = Modifier.widthIn(min = if (item.isEmoji) 44.dp else 68.dp),
                )
            }
        }
    }
}

@Composable
private fun SuggestionChip(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    emoji: Boolean = false,
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
                fontSize = if (emoji) 18.sp else 14.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun ClipboardThumb(
    relativePath: String,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val bitmap = remember(relativePath) {
        val file = File(context.filesDir, relativePath)
        if (!file.exists()) {
            null
        } else {
            BitmapFactory.decodeFile(
                file.absolutePath,
                BitmapFactory.Options().apply { inSampleSize = 8 },
            )
        }
    }
    if (bitmap != null) {
        Image(
            bitmap = bitmap.asImageBitmap(),
            contentDescription = null,
            modifier = modifier,
            contentScale = ContentScale.Crop,
        )
    }
}

@Composable
private fun EmojiLayer(
    height: Dp,
    keyHeight: Dp,
    editor: KeyboardEditorConfig,
    shift: ShiftState,
    layer: KeyboardLayer,
    catalog: List<EmojiEntry>,
    recents: List<String>,
    category: EmojiCategory,
    split: Boolean = false,
    spacerFraction: Float = SplitKeyboardLayout.MIN_SPACER_FRACTION,
    onEmoji: (String) -> Unit,
    onKey: (KeyboardKey) -> Unit,
    onKeyHold: (KeyboardKey, Long) -> Unit = { _, _ -> },
    onCursorMove: (Int) -> Unit,
) {
    val bottomRow = KeyboardLayouts.rows(KeyboardLayer.EMOJI, editor)
    val glyphs = when (category) {
        EmojiCategory.RECENTS -> recents
        EmojiCategory.ASCII -> EmojiCatalog.asciiEmoticons
        else -> EmojiCatalog.inCategory(catalog, category).map { it.glyph }
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
            shift = shift,
            layer = layer,
            editor = editor,
            keyHeight = keyHeight,
            split = split,
            spacerFraction = spacerFraction,
            onKey = onKey,
            onKeyHold = onKeyHold,
            onCursorMove = onCursorMove,
        )
    }
}

@Composable
private fun EmojiCategoryRow(
    selected: EmojiCategory,
    hasRecents: Boolean,
    asciiEmojiEnabled: Boolean,
    onSelect: (EmojiCategory) -> Unit,
    modifier: Modifier = Modifier,
) {
    val categories = buildList {
        if (hasRecents) add(EmojiCategory.RECENTS)
        addAll(EmojiCategory.browsable(asciiEmojiEnabled))
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
                Text(glyph, fontSize = if (glyph.length > 2) 14.sp else 22.sp, maxLines = 1)
            }
        }
    }
}

@Composable
private fun KeyboardRows(
    rows: List<KeyboardRow>,
    shift: ShiftState,
    layer: KeyboardLayer,
    editor: KeyboardEditorConfig,
    keyHeight: Dp,
    showKeyHints: Boolean = false,
    split: Boolean = false,
    spacerFraction: Float = SplitKeyboardLayout.MIN_SPACER_FRACTION,
    swipeEnabled: Boolean = false,
    onSwipe: (String) -> Unit = {},
    onKey: (KeyboardKey) -> Unit,
    onKeyHold: (KeyboardKey, Long) -> Unit = { _, _ -> },
    onCursorMove: (Int) -> Unit,
) {
    val swipeConsumed = remember { mutableStateOf(false) }
    val keyBounds = remember { mutableMapOf<String, Pair<KeyboardKey, Rect>>() }
    var parentCoords by remember { mutableStateOf<LayoutCoordinates?>(null) }
    var trail by remember { mutableStateOf<List<Offset>>(emptyList()) }
    val trailColor = MaterialTheme.colorScheme.primary
    val currentOnSwipe = rememberUpdatedState(onSwipe)

    // Only the swipe gesture clears this, and it is only installed on the
    // letter layer, so a swipe that was still consuming when the layer changed
    // would leave the flag raised with nothing left to lower it.
    LaunchedEffect(swipeEnabled) {
        if (!swipeEnabled) swipeConsumed.value = false
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .onGloballyPositioned { parentCoords = it }
            .then(
                if (swipeEnabled) {
                    Modifier.swipeTypingGesture(
                        keyBounds = keyBounds,
                        parentCoords = { parentCoords },
                        swipeConsumed = swipeConsumed,
                        onTrail = { trail = it },
                        onSwipe = { currentOnSwipe.value(it) },
                    )
                } else {
                    Modifier
                },
            ),
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
                    val items = if (split) {
                        SplitKeyboardLayout.splitRow(row, spacerFraction).items
                    } else {
                        row.keys.map { SplitItem.Key(it) }
                    }
                    items.forEach { item ->
                        when (item) {
                            is SplitItem.Gap -> Spacer(Modifier.weight(item.weight))
                            is SplitItem.Key -> {
                                val key = item.key
                                KeyButton(
                                    key = key,
                                    shift = shift,
                                    layer = layer,
                                    editor = editor,
                                    keyHeight = keyHeight,
                                    showKeyHints = showKeyHints,
                                    // A swipe can only begin on a letter, so a
                                    // letter is the only key whose own tap can
                                    // be the tail of one. Handing the flag to
                                    // shift or `?123` let a swipe that ended
                                    // without a match swallow the next tap on
                                    // them instead.
                                    swipeConsumed = if (key.type == KeyboardKeyType.CHARACTER) {
                                        swipeConsumed
                                    } else {
                                        null
                                    },
                                    onPress = { onKey(key) },
                                    onHold = { heldMs -> onKeyHold(key, heldMs) },
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
                                    modifier = Modifier
                                        .weight(key.weight)
                                        .onGloballyPositioned { coords ->
                                            val origin = coords.positionInRoot()
                                            keyBounds[key.id] = key to Rect(
                                                origin.x,
                                                origin.y,
                                                origin.x + coords.size.width,
                                                origin.y + coords.size.height,
                                            )
                                        },
                                )
                            }
                        }
                    }
                    if (row.trailingSpace > 0f) Spacer(Modifier.weight(row.trailingSpace))
                }
            }
        }
        if (trail.size >= 2) {
            Canvas(Modifier.matchParentSize()) {
                val path = Path().apply {
                    moveTo(trail.first().x, trail.first().y)
                    trail.drop(1).forEach { lineTo(it.x, it.y) }
                }
                drawPath(
                    path = path,
                    color = trailColor,
                    style = Stroke(width = 5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round),
                )
            }
        }
    }
}

private fun Modifier.swipeTypingGesture(
    keyBounds: Map<String, Pair<KeyboardKey, Rect>>,
    parentCoords: () -> LayoutCoordinates?,
    swipeConsumed: MutableState<Boolean>,
    onTrail: (List<Offset>) -> Unit,
    onSwipe: (String) -> Unit,
) = pointerInput(Unit) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
        swipeConsumed.value = false
        val start = hitLetter(keyBounds, parentCoords()?.localToRoot(down.position))
        if (start == null) return@awaitEachGesture
        val path = StringBuilder(start.output.lowercase())
        var lastId = start.id
        val points = mutableListOf(down.position)
        while (true) {
            val event = awaitPointerEvent(PointerEventPass.Initial)
            val change = event.changes.firstOrNull { it.id == down.id } ?: break
            points.add(change.position)
            val hit = hitLetter(keyBounds, parentCoords()?.localToRoot(change.position))
            if (hit != null && hit.id != lastId) {
                swipeConsumed.value = true
                path.append(hit.output.lowercase())
                lastId = hit.id
            }
            if (swipeConsumed.value) {
                change.consume()
                onTrail(points.toList())
            }
            if (!change.pressed) break
        }
        onTrail(emptyList())
        if (swipeConsumed.value) onSwipe(path.toString())
    }
}

private fun hitLetter(
    keyBounds: Map<String, Pair<KeyboardKey, Rect>>,
    root: Offset?,
): KeyboardKey? {
    if (root == null) return null
    val hit = keyBounds.values.firstOrNull { (_, rect) -> rect.contains(root) }?.first ?: return null
    return hit.takeIf {
        it.type == KeyboardKeyType.CHARACTER && it.output.length == 1 && it.output[0].isLetter()
    }
}

@Composable
private fun RowScope.KeyButton(
    key: KeyboardKey,
    shift: ShiftState,
    layer: KeyboardLayer,
    editor: KeyboardEditorConfig,
    keyHeight: Dp,
    showKeyHints: Boolean = false,
    swipeConsumed: MutableState<Boolean>? = null,
    onPress: () -> Unit,
    onHold: (Long) -> Unit = {},
    onCommitText: (String) -> Unit,
    onCursorMove: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val view = LocalView.current
    val previewOffset = with(LocalDensity.current) { -(keyHeight + 8.dp).roundToPx() }
    val currentOnPress = rememberUpdatedState(onPress)
    val currentOnHold = rememberUpdatedState(onHold)
    val currentOnCommitText = rememberUpdatedState(onCommitText)
    val currentOnCursorMove = rememberUpdatedState(onCursorMove)
    var pressed by remember(key.id) { mutableStateOf(false) }
    var accentIndex by remember(key.id) { mutableStateOf(-1) }
    val accents = remember(key.id, shift) { KeyAccents.forKey(key, shift) }
    val isReturnAction = key.type == KeyboardKeyType.RETURN && editor.returnKey != ReturnKeyKind.ENTER
    val activeShift = key.type == KeyboardKeyType.SHIFT && shift != ShiftState.OFF
    val background = when {
        isReturnAction -> MaterialTheme.colorScheme.primary
        activeShift -> MaterialTheme.colorScheme.primaryContainer
        key.type == KeyboardKeyType.CHARACTER || key.type == KeyboardKeyType.SPACE ->
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
        layer == KeyboardLayer.LETTERS &&
        shift != ShiftState.OFF
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
            swipeConsumed = swipeConsumed,
            onTap = { currentOnPress.value() },
            onVariant = { index -> currentOnCommitText.value(accents[index]) },
            onPressedChange = { pressed = it },
            onAccentIndex = { accentIndex = it },
            onHaptic = { view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP) },
        )
        else -> Modifier.keyGesture(
            pointerKey = key.id,
            repeat = key.type == KeyboardKeyType.DELETE,
            swipeConsumed = swipeConsumed,
            onPress = { currentOnPress.value() },
            onHold = { currentOnHold.value(it) },
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
                contentDescription = keyDescription(key, previewLabel, editor.returnKey, shift)
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
            shift = shift,
            returnKey = editor.returnKey,
            tint = foreground,
            hint = if (showKeyHints) KeyAccents.hint(key) else null,
        )

        if (pressed && swipeConsumed?.value != true && key.type == KeyboardKeyType.CHARACTER) {
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
    onHold: (Long) -> Unit = {},
    onPressedChange: (Boolean) -> Unit,
    onHaptic: () -> Unit,
    swipeConsumed: MutableState<Boolean>? = null,
) = pointerInput(pointerKey, repeat) {
    coroutineScope {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            down.consume()
            onPressedChange(true)
            onHaptic()
            val downAt = SystemClock.uptimeMillis()
            if (repeat) onPress()
            val repeatJob = if (repeat) {
                launch {
                    delay(DeleteHold.REPEAT_DELAY_MS)
                    while (isActive) {
                        val heldMs = SystemClock.uptimeMillis() - downAt
                        onHold(heldMs)
                        delay(DeleteHold.interval(heldMs))
                    }
                }
            } else {
                null
            }
            val up = waitForUpOrCancellation()
            repeatJob?.cancel()
            onPressedChange(false)
            if (!repeat && up != null && swipeConsumed?.value != true) onPress()
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
    swipeConsumed: MutableState<Boolean>? = null,
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
            if (swipeConsumed?.value != true) {
                if (showing) {
                    onVariant(index)
                } else {
                    onTap()
                }
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
    hint: String? = null,
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
        KeyboardKeyType.SPACE -> if (!SplitKeyboardLayout.isSplitSpace(key)) {
            KeyLabel("VocaPhone", tint.copy(alpha = 0.78f), utility = true)
        }
        KeyboardKeyType.LAYER_SWITCH -> KeyLabel(displayLabel, tint, utility = true)
        KeyboardKeyType.CHARACTER -> {
            if (hint == null) {
                KeyLabel(displayLabel, tint, utility = false)
            } else {
                Box(Modifier.fillMaxWidth().fillMaxHeight()) {
                    Text(
                        text = hint,
                        color = tint.copy(alpha = 0.38f),
                        fontSize = 10.sp,
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .padding(top = 2.dp, end = 4.dp),
                    )
                    Box(Modifier.align(Alignment.Center)) {
                        KeyLabel(displayLabel, tint, utility = false)
                    }
                }
            }
        }
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
    SETTINGS,
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
            Glyph.SETTINGS -> {
                drawCircle(
                    color = tint,
                    radius = w * 0.16f,
                    center = Offset(w * 0.5f, h * 0.5f),
                    style = stroke,
                )
                drawCircle(
                    color = tint,
                    radius = w * 0.34f,
                    center = Offset(w * 0.5f, h * 0.5f),
                    style = stroke,
                )
                repeat(6) { index ->
                    val angle = (index * 60f) * (PI.toFloat() / 180f)
                    val inner = w * 0.34f
                    val outer = w * 0.46f
                    drawLine(
                        color = tint,
                        start = Offset(
                            w * 0.5f + kotlin.math.cos(angle) * inner,
                            h * 0.5f + sin(angle) * inner,
                        ),
                        end = Offset(
                            w * 0.5f + kotlin.math.cos(angle) * outer,
                            h * 0.5f + sin(angle) * outer,
                        ),
                        strokeWidth = stroke.width,
                        cap = StrokeCap.Round,
                    )
                }
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
