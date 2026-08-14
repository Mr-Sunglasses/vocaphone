package com.vocahq.vocaphone.ime

import android.content.ClipDescription
import android.content.ClipboardManager
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.ExtractedTextRequest
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.vocahq.vocaphone.VocaPhoneApplication
import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.core.ImeInputPolicy
import com.vocahq.vocaphone.core.ModelLanguageSupport
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.core.TranscriptSanitizer
import com.vocahq.vocaphone.core.WritingStyle
import com.vocahq.vocaphone.dictation.AppliedInsertion
import com.vocahq.vocaphone.dictation.DictationService
import com.vocahq.vocaphone.dictation.DictationSource
import com.vocahq.vocaphone.dictation.InsertionOutcome
import com.vocahq.vocaphone.dictation.InsertionReport
import com.vocahq.vocaphone.dictation.TranscriptInserter
import com.vocahq.vocaphone.settings.VocaPhoneSettings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs

/** VocaPhone's private, full typing keyboard with a dedicated dictation control. */
class VocaPhoneInputMethodService : LifecycleInputMethodService(), TranscriptInserter {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val container by lazy { VocaPhoneApplication.container(this) }
    private val visibleDictationState = MutableStateFlow(DictationState())
    private val visibleSettings = MutableStateFlow(VocaPhoneSettings())
    private val visibleClipboard = MutableStateFlow<ClipboardChip?>(null)
    private val visibleEditorText = MutableStateFlow(EditorTextWindow())
    private val suggestionDictionary by lazy { SuggestionDictionary.load(assets) }
    private val emojiCatalog by lazy { EmojiCatalog.load(assets) }
    private val mainHandler = Handler(Looper.getMainLooper())
    private val clipboardListener = ClipboardManager.OnPrimaryClipChangedListener { refreshClipboard() }
    private val preferenceWrites by lazy {
        KeyboardPreferenceCoordinator(scope) {
            container.diagnostics.recordError("settings", DictationSource.IME.name)
        }
    }

    private var lastState = DictationState()
    private var currentInputType: Int = 0
    private var startedImeDictation = false
    private var ignoredClipboardText: String? = null
    private var lastRecordedClip: String? = null
    private var editorSession = 0
    private var editorConfig by mutableStateOf(KeyboardEditorConfig.empty())

    override fun onCreate() {
        super.onCreate()
        container.dictation.imeInserter = this
        scope.launch {
            container.dictation.state.collect { state ->
                lastState = state
                visibleDictationState.value = state
                if (!state.phase.isBusy) startedImeDictation = false
            }
        }
        scope.launch {
            container.settings.settings.collect { settings ->
                visibleSettings.value = settings
                refreshClipboard()
            }
        }
    }

    @Composable
    override fun KeyboardContent() {
        val dictationState by visibleDictationState.collectAsState()
        val settings by visibleSettings.collectAsState()
        val isPreferenceWritePending by preferenceWrites.pending.collectAsState()
        val clipboard by visibleClipboard.collectAsState()
        val editorText by visibleEditorText.collectAsState()
        VocaPhoneKeyboard(
            dictationState = dictationState,
            editor = editorConfig,
            settings = settings,
            isPreferenceWritePending = isPreferenceWritePending,
            clipboard = clipboard,
            editorText = editorText,
            suggestions = suggestionDictionary,
            emojiCatalog = emojiCatalog,
            onCommand = ::handleCommand,
            onMicTap = ::toggleDictation,
            onOpenApp = { openCompanion() },
            onOpenSettings = ::openCompanion,
            onLanguageSelected = ::setLanguage,
            onStyleSelected = ::setStyle,
            onSuggestionPicked = ::commitSuggestion,
            onPasteClipboard = { pasteClipboard(it) },
            onDismissClipboard = ::dismissClipboard,
            onRemoveClipboardHistory = ::removeClipboardHistory,
            onClearClipboardHistory = ::clearClipboardHistory,
            onEmojiUsed = ::recordEmojiRecent,
        )
    }

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        currentInputType = attribute?.inputType ?: 0
        editorSession += 1
        val cursorCapsMode = runCatching {
            currentInputConnection?.getCursorCapsMode(currentInputType) ?: 0
        }.getOrDefault(0)
        editorConfig = KeyboardEditorConfig.from(attribute, editorSession).let { config ->
            if (config.initialLayer == KeyboardLayer.LETTERS) {
                config.copy(initialShift = KeyboardEditorConfig.shiftFromCapsMode(cursorCapsMode))
            } else {
                config
            }
        }
        refreshEditorText()
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        startClipboardWatch()
        refreshEditorText()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        stopClipboardWatch()
        visibleClipboard.value = null
        super.onFinishInputView(finishingInput)
    }

    override fun onUpdateSelection(
        oldSelStart: Int,
        oldSelEnd: Int,
        newSelStart: Int,
        newSelEnd: Int,
        candidatesStart: Int,
        candidatesEnd: Int,
    ) {
        super.onUpdateSelection(
            oldSelStart,
            oldSelEnd,
            newSelStart,
            newSelEnd,
            candidatesStart,
            candidatesEnd,
        )
        refreshEditorText()
    }

    override fun onFinishInput() {
        cancelOwnedDictation("editor_finished")
        currentInputType = 0
        editorSession += 1
        editorConfig = KeyboardEditorConfig.empty().copy(sessionId = editorSession)
        super.onFinishInput()
    }

    override fun onUnbindInput() {
        cancelOwnedDictation("input_unbound")
        super.onUnbindInput()
    }

    override fun onDestroy() {
        stopClipboardWatch()
        cancelOwnedDictation("keyboard_destroyed")
        if (container.dictation.imeInserter === this) {
            container.dictation.imeInserter = null
        }
        scope.cancel()
        super.onDestroy()
    }

    override suspend fun insert(transcript: String): InsertionReport =
        withContext(Dispatchers.Main.immediate) {
            if (!ImeInputPolicy.acceptsDictation(currentInputType)) {
                return@withContext InsertionReport(InsertionOutcome.NO_TARGET)
            }

            val connection = currentInputConnection
                ?: return@withContext InsertionReport(InsertionOutcome.NO_TARGET)
            val cleaned = TranscriptSanitizer.clean(transcript)
            if (cleaned.isEmpty()) {
                return@withContext InsertionReport(InsertionOutcome.NO_TARGET)
            }

            if (runCatching { connection.commitText(cleaned, 1) }.getOrDefault(false)) {
                syncShiftFromCursor()
                refreshEditorText()
                InsertionReport(InsertionOutcome.INSERTED)
            } else {
                InsertionReport(InsertionOutcome.UNSUPPORTED_EDITOR)
            }
        }

    override suspend fun undo(insertion: AppliedInsertion): Boolean = false

    override fun currentTargetPackage(): String? = currentInputEditorInfo?.packageName

    private fun handleCommand(command: KeyboardCommand) {
        when (command) {
            is KeyboardCommand.CommitText -> {
                currentInputConnection?.finishComposingText()
                currentInputConnection?.commitText(command.text, 1)
            }
            is KeyboardCommand.SetComposingText ->
                currentInputConnection?.setComposingText(command.text, 1)
            KeyboardCommand.FinishComposing -> currentInputConnection?.finishComposingText()
            KeyboardCommand.DeleteBackward -> sendKey(KeyEvent.KEYCODE_DEL)
            is KeyboardCommand.DeleteSurrounding -> {
                val connection = currentInputConnection ?: return
                connection.finishComposingText()
                if (command.before > 0 || command.after > 0) {
                    connection.deleteSurroundingText(command.before, command.after)
                }
            }
            KeyboardCommand.PerformEditorAction -> {
                currentInputConnection?.finishComposingText()
                performEditorAction()
            }
            is KeyboardCommand.MoveCursor -> {
                currentInputConnection?.finishComposingText()
                moveCursor(command.positions)
            }
            KeyboardCommand.DoubleSpacePeriod -> {
                val connection = currentInputConnection ?: return
                connection.finishComposingText()
                connection.deleteSurroundingText(1, 0)
                connection.commitText(". ", 1)
            }
            KeyboardCommand.CycleSelectionCase -> cycleSelectionCase()
        }
        refreshEditorText()
    }

    private fun commitSuggestion(word: String, replaceWord: Boolean) {
        val connection = currentInputConnection ?: return
        if (replaceWord) {
            connection.finishComposingText()
            val before = runCatching {
                connection.getTextBeforeCursor(32, 0)?.toString().orEmpty()
            }.getOrDefault("")
            val after = runCatching {
                connection.getTextAfterCursor(32, 0)?.toString().orEmpty()
            }.getOrDefault("")
            val span = SuggestionEngine.replaceableWord(before, after)
            if (span != null) {
                connection.deleteSurroundingText(span.beforeLength, span.afterLength)
            }
        }
        // Leave composing alone so commitText replaces "hel" with "hello ".
        // Finishing first commits the stub, then this would insert in front of it.
        connection.commitText("$word ", 1)
        syncShiftFromCursor()
        refreshEditorText()
    }

    private fun pasteClipboard(text: String = visibleClipboard.value?.fullText.orEmpty()) {
        if (text.isEmpty()) return
        currentInputConnection?.finishComposingText()
        currentInputConnection?.commitText(text, 1)
        ignoredClipboardText = text
        if (visibleClipboard.value?.fullText == text) visibleClipboard.value = null
        syncShiftFromCursor()
        refreshEditorText()
    }

    private fun dismissClipboard() {
        ignoredClipboardText = visibleClipboard.value?.fullText ?: return
        visibleClipboard.value = null
    }

    private fun removeClipboardHistory(text: String) {
        persistPreference { container.settings.removeClipboardHistory(text) }
    }

    private fun clearClipboardHistory() {
        persistPreference { container.settings.clearClipboardHistory() }
    }

    private fun recordEmojiRecent(emoji: String) {
        persistPreference { container.settings.recordEmojiRecent(emoji) }
    }

    private fun cycleSelectionCase() {
        val connection = currentInputConnection ?: return
        connection.finishComposingText()
        val selected = runCatching {
            connection.getSelectedText(0)?.toString().orEmpty()
        }.getOrDefault("")
        if (selected.none { it.isLetter() }) return
        val next = CaseCycle.next(selected)
        val start = runCatching {
            connection.getExtractedText(ExtractedTextRequest(), 0)?.selectionStart
        }.getOrNull()
        connection.commitText(next, 1)
        if (start != null && start >= 0) {
            connection.setSelection(start, start + next.length)
        }
    }

    private fun refreshEditorText() {
        val selected = runCatching {
            currentInputConnection?.getSelectedText(0)?.toString().orEmpty()
        }.getOrDefault("")
        if (!visibleSettings.value.suggestionsEnabled || editorConfig.sensitive) {
            visibleEditorText.value = EditorTextWindow(selected = selected)
            return
        }
        val before = runCatching {
            currentInputConnection?.getTextBeforeCursor(32, 0)?.toString().orEmpty()
        }.getOrDefault("")
        val after = runCatching {
            currentInputConnection?.getTextAfterCursor(32, 0)?.toString().orEmpty()
        }.getOrDefault("")
        visibleEditorText.value = EditorTextWindow(before, after, selected)
    }

    private fun syncShiftFromCursor() {
        if (editorConfig.initialLayer != KeyboardLayer.LETTERS) return
        val capsMode = runCatching {
            currentInputConnection?.getCursorCapsMode(currentInputType) ?: 0
        }.getOrDefault(0)
        editorConfig = editorConfig.copy(
            initialShift = KeyboardEditorConfig.shiftFromCapsMode(capsMode),
            shiftSync = editorConfig.shiftSync + 1,
        )
    }

    private fun startClipboardWatch() {
        val manager = getSystemService(ClipboardManager::class.java) ?: return
        manager.removePrimaryClipChangedListener(clipboardListener)
        manager.addPrimaryClipChangedListener(clipboardListener)
        refreshClipboard()
    }

    private fun stopClipboardWatch() {
        getSystemService(ClipboardManager::class.java)
            ?.removePrimaryClipChangedListener(clipboardListener)
    }

    private fun refreshClipboard() {
        mainHandler.post {
            val settings = visibleSettings.value
            if (editorConfig.sensitive) {
                visibleClipboard.value = null
                return@post
            }
            val manager = getSystemService(ClipboardManager::class.java)
            val description = manager?.primaryClipDescription
            val isText = description?.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN) == true ||
                description?.hasMimeType(ClipDescription.MIMETYPE_TEXT_HTML) == true
            if (!isText) {
                visibleClipboard.value = null
                return@post
            }
            val text = runCatching {
                manager.primaryClip?.getItemAt(0)?.coerceToText(this)?.toString()
            }.getOrNull()?.trim().orEmpty()
            if (
                text.isNotEmpty() &&
                settings.clipboardHistoryEnabled &&
                text != lastRecordedClip
            ) {
                lastRecordedClip = text
                persistPreference { container.settings.recordClipboardHistory(text) }
            }
            visibleClipboard.value = text.takeIf {
                settings.clipboardChipEnabled && it.isNotEmpty() && it != ignoredClipboardText
            }?.let { value ->
                ClipboardChip(
                    preview = value.replace('\n', ' ').take(24),
                    fullText = value,
                )
            }
        }
    }

    private fun performEditorAction() {
        val actionId = editorConfig.editorActionId
        val handled = actionId != null &&
            currentInputConnection?.performEditorAction(actionId) == true
        if (!handled) sendKey(KeyEvent.KEYCODE_ENTER)
    }

    private fun moveCursor(positions: Int) {
        if (positions == 0) return
        val keyCode = if (positions > 0) KeyEvent.KEYCODE_DPAD_RIGHT else KeyEvent.KEYCODE_DPAD_LEFT
        repeat(abs(positions).coerceAtMost(MAX_CURSOR_STEPS_PER_EVENT)) { sendKey(keyCode) }
    }

    private fun sendKey(keyCode: Int) {
        val connection = currentInputConnection ?: return
        connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, keyCode))
    }

    private fun toggleDictation() {
        when {
            preferenceWrites.isPending -> Unit
            !ImeInputPolicy.acceptsDictation(currentInputType) -> {
                container.diagnostics.recordAction("input_rejected", DictationSource.IME.name)
            }
            lastState.phase == DictationPhase.LISTENING -> {
                container.diagnostics.recordAction("finish", DictationSource.IME.name)
                DictationService.send(this, DictationService.ACTION_FINISH)
            }
            lastState.phase.isBusy -> {
                DictationService.send(this, DictationService.ACTION_CANCEL)
            }
            lastState.phase == DictationPhase.PERMISSION_REPAIR -> openCompanion()
            else -> {
                if (lastState.phase == DictationPhase.FAILED ||
                    lastState.phase == DictationPhase.READY_TO_INSERT ||
                    lastState.phase == DictationPhase.INSERTED
                ) {
                    container.dictation.clearTransient()
                }
                startedImeDictation = true
                DictationService.start(this, DictationSource.IME)
            }
        }
    }

    private fun setLanguage(language: TranscriptionLanguage) {
        val settings = visibleSettings.value
        if (!ModelLanguageSupport.isSelectable(
                language,
                settings.activeModelLanguages,
                settings.activeModelDetectsLanguage,
            )
        ) {
            return
        }
        persistPreference { container.settings.setLanguage(language) }
    }

    private fun setStyle(style: WritingStyle) {
        persistPreference { container.settings.setStyle(style) }
    }

    private fun persistPreference(write: suspend () -> Unit) {
        if (lastState.phase.isBusy) return
        preferenceWrites.submit(write)
    }

    private fun cancelOwnedDictation(reason: String) {
        if (!startedImeDictation || !lastState.phase.isBusy) return
        container.diagnostics.recordAction(reason, DictationSource.IME.name)
        startedImeDictation = false
        // An editor connection is unsafe after this callback, so do not let a
        // late gateway response insert into whichever field receives focus next.
        container.dictation.cancel()
    }

    private fun openCompanion(page: String? = null) {
        val intent = packageManager.getLaunchIntentForPackage(packageName) ?: return
        intent.addFlags(
            android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP,
        )
        intent.putExtra(com.vocahq.vocaphone.ui.MainActivity.EXTRA_OPEN_SETTINGS, true)
        if (!page.isNullOrEmpty()) {
            intent.putExtra(com.vocahq.vocaphone.ui.MainActivity.EXTRA_SETTINGS_PAGE, page)
        }
        startActivity(intent)
    }

    private companion object {
        const val MAX_CURSOR_STEPS_PER_EVENT = 12
    }
}
