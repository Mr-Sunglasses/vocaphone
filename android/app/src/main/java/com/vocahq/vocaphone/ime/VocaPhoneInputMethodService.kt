package com.vocahq.vocaphone.ime

import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.ExtractedTextRequest
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputContentInfo
import android.view.inputmethod.InputMethodManager
import android.view.inputmethod.InputMethodSubtype
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.vocahq.vocaphone.VocaPhoneApplication
import com.vocahq.vocaphone.core.CustomVocabulary
import com.vocahq.vocaphone.core.DictatedTranscript
import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.core.ImeInputPolicy
import com.vocahq.vocaphone.core.ModelLanguageSupport
import com.vocahq.vocaphone.core.TranscriptionLanguage
import com.vocahq.vocaphone.core.TranscriptRepair
import com.vocahq.vocaphone.core.TranscriptSanitizer
import com.vocahq.vocaphone.core.WritingStyle
import com.vocahq.vocaphone.dictation.AppliedInsertion
import com.vocahq.vocaphone.dictation.DictationService
import com.vocahq.vocaphone.dictation.DictationSource
import com.vocahq.vocaphone.dictation.InsertionOutcome
import com.vocahq.vocaphone.dictation.InsertionReport
import com.vocahq.vocaphone.dictation.TranscriptInserter
import com.vocahq.vocaphone.grammar.TypedGrammar
import com.vocahq.vocaphone.local.GrammarModelCatalog
import com.vocahq.vocaphone.settings.ClipboardHistory
import com.vocahq.vocaphone.settings.ClipboardImages
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
    /**
     * Typing data, loaded off the thread that draws the keyboard.
     *
     * Both were `by lazy`, and the first thing to touch them was composition:
     * bringing the keyboard up for the first time parsed a ten thousand word
     * list, its bigram table, a four thousand entry emoji catalog and the
     * suggestion table — a few hundred kilobytes of assets — inside the first
     * frame. Nothing could be drawn until it finished.
     *
     * Both surfaces already render without them: the strip takes a nullable
     * dictionary and the emoji panel an empty catalog, so the keyboard appears
     * immediately and gains suggestions a moment later.
     */
    private val suggestionDictionary = MutableStateFlow<SuggestionDictionary?>(null)
    private val emojiCatalog = MutableStateFlow<List<EmojiEntry>>(emptyList())
    private val mainHandler = Handler(Looper.getMainLooper())
    private val clipboardListener = ClipboardManager.OnPrimaryClipChangedListener {
        // A failed empty dictation owns the suggestion strip. A new copy is
        // the user moving on; drop the banner so the clipboard chip can show.
        if (lastState.phase == DictationPhase.FAILED) {
            container.dictation.clearTransient()
        }
        refreshClipboard()
    }
    private val preferenceWrites by lazy {
        KeyboardPreferenceCoordinator(scope) {
            container.diagnostics.recordError("settings", DictationSource.IME.name)
        }
    }

    private var lastState = DictationState()
    private var currentInputType: Int = 0
    private var startedImeDictation = false
    private var voiceShortcutActive by mutableStateOf(false)
    private var voiceShortcutOwnedSession = false
    private var voiceShortcutStartRequested = false
    private var voiceShortcutLeftIdle = false
    private var voiceShortcutReturned = false
    private var voiceShortcutWindowWaits = 0
    private var voiceShortcutRejectGuidance by mutableStateOf(false)
    private val startVoiceShortcutDictation = Runnable { maybeStartVoiceShortcutDictation() }
    private val delayedRejectedHandback = Runnable {
        // EditorInfo can land a frame after the picker flips us to voice.
        // Re-check before leaving so a late dictation-capable field can still
        // auto-start instead of bouncing back.
        when (
            VoiceShortcutIme.rejectedHandback(
                isVoiceShortcut = voiceShortcutActive,
                dictationAllowed = editorConfig.dictationAllowed,
                sensitive = editorConfig.sensitive,
            )
        ) {
            VoiceShortcutIme.RejectedHandback.NONE -> {
                voiceShortcutRejectGuidance = false
                maybeStartVoiceShortcutDictation()
            }
            VoiceShortcutIme.RejectedHandback.IMMEDIATE,
            VoiceShortcutIme.RejectedHandback.GUIDED,
            -> returnToPreviousIme()
        }
    }
    /**
     * Hands back after a failure has been on screen long enough to read; see
     * [VoiceShortcutIme.handbackDelayMillis]. Re-checked when it fires: a
     * Retry or a new dictation in the meantime keeps the shortcut up.
     */
    private val delayedFailedHandback = Runnable {
        if (voiceShortcutActive && !lastState.phase.isBusy) returnToPreviousIme()
    }

    /**
     * [editorSession] when this keyboard's dictation started (or was retried).
     * A transcript is only ever inserted into that same field: leaving it
     * mid-dictation finishes the dictation into History instead.
     */
    private var dictationEditorSession = -1
    private var ignoredClipboardText: String? = null
    private var lastRecordedClip: String? = null
    private var lastImageSource: String? = null
    private var editorSession = 0
    private var editorIdentity: EditorIdentity? = null
    private var editorConfig by mutableStateOf(KeyboardEditorConfig.empty())
    private var lastCandidatesStart = -1
    private var lastCandidatesEnd = -1
    private var lastSelStart = -1
    private var lastSelEnd = -1
    private var caseCycleOriginal: String? = null
    private var caseCycleEmitted: String? = null
    /** Set in onDestroy; posted work checks it before touching the service. */
    private var destroyed = false
    /** True while the editor still has a composing region we set. */
    private var composingRegionActive = false

    private val editorTextRefresh = Runnable { refreshEditorText() }

    /**
     * "Check grammar while typing". The model is the app's own
     * [com.vocahq.vocaphone.grammar.GrammarCorrector], shared with dictation's
     * Fix grammar; this keyboard runs in the app's process, so the typed text
     * never leaves it.
     */
    private val typedGrammar by lazy {
        TypedGrammarCheck(
            scope = scope,
            worker = Dispatchers.Default,
            readBefore = { limit ->
                runCatching { currentInputConnection?.getTextBeforeCursor(limit, 0)?.toString() }.getOrNull()
            },
            correct = { text, keep -> container.grammar.correctTyped(text, keep) },
            isEnglish = { text ->
                TranscriptRepair.isEnglish(text, "auto") { suggestionDictionary.value?.isKnown(it) == true }
            },
        )
    }

    /**
     * Gives the grammar session back a while after the keyboard goes away.
     * Dictation's idle release only runs after a dictation, and somebody who
     * only types would otherwise keep tens of megabytes loaded for nothing.
     */
    private val releaseTypedGrammar = Runnable {
        if (!lastState.phase.isBusy) container.grammar.release()
    }

    override fun onCreate() {
        super.onCreate()
        publishVoiceShortcutSubtypes()
        container.dictation.imeInserter = this
        scope.launch {
            container.dictation.state.collect { state ->
                lastState = state
                visibleDictationState.value = state
                if (!state.phase.isBusy) startedImeDictation = false
                if (voiceShortcutOwnedSession && state.phase != DictationPhase.IDLE) {
                    voiceShortcutLeftIdle = true
                }
                maybeReturnToPreviousIme()
            }
        }
        scope.launch {
            container.settings.settings.collect { settings ->
                visibleSettings.value = settings
                if (ignoredClipboardText == null && settings.dismissedClipboardText.isNotEmpty()) {
                    ignoredClipboardText = settings.dismissedClipboardText
                }
                refreshClipboard()
            }
        }
        scope.launch(Dispatchers.Default) {
            // Failures are silent on purpose: a keyboard that cannot read its
            // word list still types, and there is no screen here to report on.
            suggestionDictionary.value = runCatching { SuggestionDictionary.load(assets) }.getOrNull()
            emojiCatalog.value = runCatching { EmojiCatalog.load(assets) }.getOrNull().orEmpty()
            runCatching { EmojiSuggestions.load(assets) }
        }
    }

    @Composable
    override fun KeyboardContent() {
        val dictationState by visibleDictationState.collectAsState()
        val settings by visibleSettings.collectAsState()
        val isPreferenceWritePending by preferenceWrites.pending.collectAsState()
        if (voiceShortcutActive) {
            VoiceShortcutListeningChrome(
                dictationState = dictationState,
                editor = editorConfig,
                settings = settings,
                isPreferenceWritePending = isPreferenceWritePending,
                rejectGuidance = voiceShortcutRejectGuidance,
                onMicTap = ::toggleDictation,
                onMicLongPress = ::cancelDictationFromMic,
                onRetry = ::retryImeDictation,
                onInsertSaved = ::insertSavedTranscript,
                onReadyToListen = ::scheduleVoiceShortcutDictation,
            )
        } else {
            val clipboard by visibleClipboard.collectAsState()
            val editorText by visibleEditorText.collectAsState()
            val dictionary by suggestionDictionary.collectAsState()
            val emojis by emojiCatalog.collectAsState()
            val grammarFix by typedGrammar.fix.collectAsState()
            VocaPhoneKeyboard(
                dictationState = dictationState,
                editor = editorConfig,
                settings = settings,
                isPreferenceWritePending = isPreferenceWritePending,
                clipboard = clipboard,
                editorText = editorText,
                suggestions = dictionary,
                emojiCatalog = emojis,
                grammarFix = grammarFix,
                onCommand = ::handleCommand,
                onMicTap = ::toggleDictation,
                onMicLongPress = ::cancelDictationFromMic,
                onRetry = ::retryImeDictation,
                onInsertSaved = ::insertSavedTranscript,
                onOpenSettings = ::openCompanion,
                onLanguageSelected = ::setLanguage,
                onStyleSelected = ::setStyle,
                onSuggestionPicked = ::commitSuggestion,
                onSaveToDictionary = ::addPersonalWord,
                onEmojiSuggestion = ::commitEmojiSuggestion,
                onPasteClipboard = { pasteClipboard(it) },
                onDismissClipboard = ::dismissClipboard,
                onRemoveClipboardHistory = ::removeClipboardHistory,
                onClearClipboardHistory = ::clearClipboardHistory,
                onEmojiUsed = ::recordEmojiRecent,
                onSpaceLongPress = ::showKeyboardPicker,
                onApplyGrammarFix = ::applyGrammarFix,
                onDismissGrammarFix = ::dismissGrammarFix,
            )
        }
    }

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        currentInputType = attribute?.inputType ?: 0
        applyVoiceShortcutSubtype(currentSubtype())
        val identity = EditorIdentity.of(attribute)
        val sameEditor = EditorRestart.keepsSession(editorIdentity, identity)
        editorIdentity = identity
        if (!sameEditor) editorSession += 1
        lastCandidatesStart = -1
        lastCandidatesEnd = -1
        lastSelStart = attribute?.initialSelStart ?: -1
        lastSelEnd = attribute?.initialSelEnd ?: -1
        composingRegionActive = false
        val autoCapitalize = visibleSettings.value.autoCapitalizeEnabled
        // Off, the answer is ignored, so skip the Binder call.
        val cursorCapsMode = if (voiceShortcutActive || !autoCapitalize) {
            0
        } else {
            runCatching {
                currentInputConnection?.getCursorCapsMode(currentInputType) ?: 0
            }.getOrDefault(0)
        }
        val started = KeyboardEditorConfig.from(attribute, editorSession, autoCapitalize).let { config ->
            if (config.initialLayer == KeyboardLayer.LETTERS) {
                config.copy(
                    initialShift = KeyboardEditorConfig.shiftFromCapsMode(cursorCapsMode, autoCapitalize),
                )
            } else {
                config
            }
        }
        editorConfig = if (sameEditor) {
            started.copy(
                // The keyboard is still the one the user left, so leave its
                // shift alone: a restart is not a reason to unlock caps.
                shiftSync = editorConfig.shiftSync,
                // The restart did drop the editor's composing region, so the
                // half-typed word the strip was building there has to go with
                // it, or the next letter commits the whole prefix again.
                cursorSync = editorConfig.cursorSync + 1,
            )
        } else {
            started
        }
        if (!voiceShortcutActive) {
            refreshEditorText()
        } else {
            // Picker activation can finish StartInput after the subtype flip.
            // Re-evaluate reject/handback against the editor we just learned.
            maybeHandBackVoiceShortcut()
        }
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        applyVoiceShortcutSubtype(currentSubtype())
        if (!voiceShortcutActive) {
            startClipboardWatch()
            refreshEditorText()
        }
        mainHandler.removeCallbacks(releaseTypedGrammar)
        // Loaded while the user types their first sentence, so the first
        // pause has a model to ask.
        if (typedGrammarEnabled()) container.grammar.warm()
        // Auto-start waits for VoiceShortcutListeningChrome's first frame.
        // A microphone FGS is not eligible on this handoff (targetSdk 36).
        maybeHandBackVoiceShortcut()
        // A permission granted while the keyboard was away clears its repair
        // here, rather than on a tap that would otherwise open the app.
        if (lastState.phase == DictationPhase.PERMISSION_REPAIR) {
            scope.launch { container.dictation.recheckRepair(DictationSource.IME) }
        }
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        if (VoiceShortcutIme.shouldKeepShortcutSession(
                voiceShortcutActive,
                voiceShortcutStartRequested,
                voiceShortcutLeftIdle,
            )
        ) {
            super.onFinishInputView(finishingInput)
            return
        }
        mainHandler.removeCallbacks(startVoiceShortcutDictation)
        mainHandler.removeCallbacks(delayedRejectedHandback)
        mainHandler.removeCallbacks(delayedFailedHandback)
        voiceShortcutWindowWaits = 0
        voiceShortcutRejectGuidance = false
        if (voiceShortcutActive) {
            releaseOwnedDictation("voice_shortcut_hidden")
            if (VoiceShortcutIme.shouldReturnWhenViewFinishes(
                    voiceShortcutActive,
                    voiceShortcutReturned,
                )
            ) {
                returnToPreviousIme()
            }
        }
        stopClipboardWatch()
        visibleClipboard.value = null
        typedGrammar.reset()
        mainHandler.removeCallbacks(releaseTypedGrammar)
        mainHandler.postDelayed(releaseTypedGrammar, TYPED_GRAMMAR_RELEASE_DELAY_MS)
        super.onFinishInputView(finishingInput)
    }

    override fun onCurrentInputMethodSubtypeChanged(newSubtype: InputMethodSubtype?) {
        super.onCurrentInputMethodSubtypeChanged(newSubtype)
        val wasActive = voiceShortcutActive
        applyVoiceShortcutSubtype(newSubtype)
        if (voiceShortcutActive && !wasActive) {
            maybeHandBackVoiceShortcut()
        }
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
        if (voiceShortcutActive) {
            lastCandidatesStart = candidatesStart
            lastCandidatesEnd = candidatesEnd
            lastSelStart = newSelStart
            lastSelEnd = newSelEnd
            return
        }
        val userMove = EditorCursorSync.isUserMove(
            oldSelStart,
            oldSelEnd,
            newSelStart,
            newSelEnd,
            lastCandidatesStart,
            lastCandidatesEnd,
            candidatesStart,
            candidatesEnd,
        )
        lastCandidatesStart = candidatesStart
        lastCandidatesEnd = candidatesEnd
        lastSelStart = newSelStart
        lastSelEnd = newSelEnd
        if (userMove) {
            editorConfig = editorConfig.copy(cursorSync = editorConfig.cursorSync + 1)
            // A tap somewhere else is a new sentence position, so the pending
            // shift has to be re-read there. Without this the ONCE armed at the
            // start of the field, or by the last ". ", follows the cursor into
            // the middle of an existing word and capitalizes inside it.
            //
            // Only for a plain cursor. Once there is a selection the shift key
            // cycles its case instead of arming a capital, and "in a word" has
            // no answer for a span that covers several.
            //
            // finishComposingText on a range selection is what made shift-to-
            // cycle miss: several editors collapse the highlight when composing
            // is finished, so getSelectedText came back empty.
            if (newSelStart == newSelEnd) {
                currentInputConnection?.finishComposingText()
                syncShiftFromCursor()
            }
        }
        // Selecting text is rare and the shift key changes meaning once there
        // is a selection, so that one reads straight away. Typing conflates.
        if (EditorSelectionSync.mustReadSelection(newSelStart, newSelEnd)) {
            refreshEditorText()
        } else {
            scheduleEditorTextRefresh()
        }
    }

    override fun onFinishInput() {
        mainHandler.removeCallbacks(startVoiceShortcutDictation)
        mainHandler.removeCallbacks(delayedRejectedHandback)
        mainHandler.removeCallbacks(delayedFailedHandback)
        voiceShortcutWindowWaits = 0
        voiceShortcutRejectGuidance = false
        releaseOwnedDictation("editor_finished")
        if (VoiceShortcutIme.shouldReturnWhenViewFinishes(
                voiceShortcutActive,
                voiceShortcutReturned,
            )
        ) {
            returnToPreviousIme()
        }
        voiceShortcutOwnedSession = false
        voiceShortcutStartRequested = false
        voiceShortcutLeftIdle = false
        currentInputType = 0
        editorIdentity = null
        editorSession += 1
        lastCandidatesStart = -1
        lastCandidatesEnd = -1
        lastSelStart = -1
        lastSelEnd = -1
        caseCycleOriginal = null
        caseCycleEmitted = null
        composingRegionActive = false
        mainHandler.removeCallbacks(editorTextRefresh)
        typedGrammar.reset()
        editorConfig = KeyboardEditorConfig.empty().copy(sessionId = editorSession)
        super.onFinishInput()
    }

    override fun onUnbindInput() {
        releaseOwnedDictation("input_unbound")
        super.onUnbindInput()
    }

    override fun onDestroy() {
        destroyed = true
        // Everything this service posts — the clipboard read, the coalesced
        // editor read, the voice shortcut runnables — reads the service or its
        // connection, and none of it means anything once it is gone.
        mainHandler.removeCallbacksAndMessages(null)
        voiceShortcutWindowWaits = 0
        voiceShortcutRejectGuidance = false
        stopClipboardWatch()
        releaseOwnedDictation("keyboard_destroyed")
        // The delayed release was just removed with everything else posted.
        if (!lastState.phase.isBusy) container.grammar.release()
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
            // The field this dictation was for has closed since it started.
            // Whatever has focus now is not where it was meant to go, so it
            // lands in History ("Saved to History") rather than here.
            if (dictationEditorSession != editorSession) {
                return@withContext InsertionReport(InsertionOutcome.NO_TARGET)
            }

            val connection = currentInputConnection
                ?: return@withContext InsertionReport(InsertionOutcome.NO_TARGET)
            val cleaned = TranscriptSanitizer.clean(transcript)
            if (cleaned.isBlank()) {
                return@withContext InsertionReport(InsertionOutcome.NO_TARGET)
            }

            val committed = commitDictation(
                connection,
                cleaned,
                composingRegionActive,
                lastSelStart,
                lastSelEnd,
            )
            // The composing region was finished before the commit, so the
            // half-typed word stays in the field and the keyboard has to drop
            // it. Cleared here rather than left to onUpdateSelection, whose
            // EditorCursorSync takes a cursor landing at or one past the old
            // composing end for the keyboard's own update; the next letter
            // would then recompose the stale prefix after the transcript.
            composingRegionActive = false
            editorConfig = editorConfig.copy(cursorSync = editorConfig.cursorSync + 1)
            if (committed) {
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
        val connection = currentInputConnection
        when (command) {
            is KeyboardCommand.CommitText -> {
                if (connection == null) return
                if (composingRegionActive) {
                    connection.beginBatchEdit()
                    connection.finishComposingText()
                    connection.commitText(command.text, 1)
                    connection.endBatchEdit()
                } else {
                    connection.commitText(command.text, 1)
                }
                composingRegionActive = false
            }
            is KeyboardCommand.SetComposingText -> {
                connection?.setComposingText(command.text, 1)
                composingRegionActive = command.text.isNotEmpty()
            }
            KeyboardCommand.FinishComposing -> {
                if (composingRegionActive) connection?.finishComposingText()
                composingRegionActive = false
            }
            KeyboardCommand.DeleteBackward -> {
                sendKey(KeyEvent.KEYCODE_DEL)
                composingRegionActive = false
            }
            is KeyboardCommand.DeleteSurrounding -> {
                if (connection == null) return
                connection.beginBatchEdit()
                if (composingRegionActive) connection.finishComposingText()
                if (command.before > 0 || command.after > 0) {
                    connection.deleteSurroundingText(command.before, command.after)
                }
                connection.endBatchEdit()
                composingRegionActive = false
            }
            KeyboardCommand.PerformEditorAction -> {
                if (composingRegionActive) connection?.finishComposingText()
                composingRegionActive = false
                performEditorAction()
            }
            is KeyboardCommand.MoveCursor -> {
                if (composingRegionActive) connection?.finishComposingText()
                composingRegionActive = false
                moveCursor(command.positions)
            }
            is KeyboardCommand.ReplaceLastCommitted -> {
                if (connection == null) return
                connection.beginBatchEdit()
                if (composingRegionActive) connection.finishComposingText()
                connection.deleteSurroundingText(1, 0)
                connection.commitText(command.text, 1)
                connection.endBatchEdit()
                composingRegionActive = false
            }
            KeyboardCommand.DoubleSpacePeriod -> {
                if (connection == null) return
                connection.beginBatchEdit()
                if (composingRegionActive) connection.finishComposingText()
                connection.deleteSurroundingText(1, 0)
                connection.commitText(". ", 1)
                connection.endBatchEdit()
                composingRegionActive = false
            }
            KeyboardCommand.CycleSelectionCase -> cycleSelectionCase()
            KeyboardCommand.ShiftTap -> {
                if (cycleSelectionCase()) {
                    // Compose already armed a capital from a stale snapshot.
                    editorConfig = editorConfig.copy(
                        initialShift = ShiftState.OFF,
                        shiftSync = editorConfig.shiftSync + 1,
                    )
                }
            }
        }
        // Composing lives in keyboard state; the strip does not need a
        // round-trip into the editor until a word is committed or the cursor
        // moves.
        if (command !is KeyboardCommand.SetComposingText) {
            scheduleEditorTextRefresh()
        }
    }

    private fun commitSuggestion(word: String, replaceWord: Boolean) {
        val connection = currentInputConnection ?: return
        var after = runCatching {
            connection.getTextAfterCursor(32, 0)?.toString().orEmpty()
        }.getOrDefault("")
        if (replaceWord) {
            connection.finishComposingText()
            val before = runCatching {
                connection.getTextBeforeCursor(32, 0)?.toString().orEmpty()
            }.getOrDefault("")
            val span = SuggestionEngine.replaceableWord(before, after)
            if (span != null) {
                connection.deleteSurroundingText(span.beforeLength, span.afterLength)
                // What the commit lands in front of is what survives the
                // delete, not what was there when the suggestion was picked.
                after = after.substring(span.afterLength)
            }
        }
        // Leave composing alone so commitText replaces "hel" with "hello ".
        // Finishing first commits the stub, then this would insert in front of it.
        connection.commitText(SuggestionEngine.suggestionCommit(word, after), 1)
        // `commitText` ends the composing region whether or not it replaced one.
        composingRegionActive = false
        syncShiftFromCursor()
        scheduleEditorTextRefresh()
    }

    private fun commitEmojiSuggestion(emoji: String) {
        val connection = currentInputConnection ?: return
        connection.finishComposingText()
        val before = runCatching {
            connection.getTextBeforeCursor(32, 0)?.toString().orEmpty()
        }.getOrDefault("")
        val after = runCatching {
            connection.getTextAfterCursor(32, 0)?.toString().orEmpty()
        }.getOrDefault("")
        if (EmojiCommit.shouldReplaceTrigger("", before)) {
            val span = SuggestionEngine.replaceableWord(before, after)
            if (span != null) {
                connection.deleteSurroundingText(span.beforeLength, span.afterLength)
            }
            connection.commitText(emoji, 1)
        } else {
            connection.commitText(EmojiCommit.insertText(before, emoji), 1)
        }
        composingRegionActive = false
        recordEmojiRecent(emoji)
        syncShiftFromCursor()
        scheduleEditorTextRefresh()
    }

    private fun pasteClipboard(text: String = visibleClipboard.value?.fullText.orEmpty()) {
        if (text.isEmpty()) return
        currentInputConnection?.finishComposingText()
        val image = ClipboardHistory.parseImage(text)
        val pasted = if (image != null) {
            pasteClipboardImage(image.first, image.second)
        } else {
            currentInputConnection?.commitText(text, 1) == true
        }
        if (!pasted) return
        rememberDismissedClip(text)
        if (visibleClipboard.value?.fullText == text) visibleClipboard.value = null
        syncShiftFromCursor()
        scheduleEditorTextRefresh()
    }

    private fun pasteClipboardImage(mime: String, relativePath: String): Boolean {
        val file = ClipboardImages.file(this, relativePath)
        if (!file.exists()) return false
        val uri = ClipboardImages.contentUri(this, relativePath)
        currentInputEditorInfo?.packageName?.let { target ->
            grantUriPermission(target, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val info = InputContentInfo(uri, ClipDescription("image", arrayOf(mime)))
        return currentInputConnection?.commitContent(
            info,
            InputConnection.INPUT_CONTENT_GRANT_READ_URI_PERMISSION,
            null,
        ) == true
    }

    private fun dismissClipboard() {
        val text = visibleClipboard.value?.fullText ?: return
        rememberDismissedClip(text)
        visibleClipboard.value = null
    }

    private fun rememberDismissedClip(text: String) {
        ignoredClipboardText = text
        persistPreference { container.settings.setDismissedClipboardText(text) }
    }

    private fun dismissedClip(settings: VocaPhoneSettings): String? =
        ignoredClipboardText ?: settings.dismissedClipboardText.takeIf { it.isNotEmpty() }

    private fun removeClipboardHistory(text: String) {
        persistPreference { container.settings.removeClipboardHistory(text) }
    }

    private fun clearClipboardHistory() {
        persistPreference { container.settings.clearClipboardHistory() }
    }

    private fun recordEmojiRecent(emoji: String) {
        persistPreference { container.settings.recordEmojiRecent(emoji) }
    }

    private fun addPersonalWord(word: String) {
        // Not persistPreference: that gate drops a write while another is in
        // flight, and two + chips in a row would lose the first word.
        scope.launch {
            container.settings.addPersonalWord(word)
        }
    }

    private fun cycleSelectionCase(): Boolean {
        val connection = currentInputConnection ?: return false
        val selected = selectedText(connection)
        val start = selectionStart(connection) ?: return false
        if (selected != caseCycleEmitted) {
            caseCycleOriginal = selected
        }
        val plan = planCaseCycle(
            selected = selected,
            original = caseCycleOriginal,
            start = start,
            composingActive = composingRegionActive,
        ) ?: return false
        connection.beginBatchEdit()
        if (plan.restoreSelectionAfterFinish) {
            connection.finishComposingText()
            connection.setSelection(start, start + selected.length)
        }
        connection.commitText(plan.next, 1)
        connection.setSelection(plan.start, plan.end)
        connection.endBatchEdit()
        composingRegionActive = false
        lastSelStart = plan.start
        lastSelEnd = plan.end
        caseCycleEmitted = plan.next
        visibleEditorText.value = visibleEditorText.value.copy(
            selected = plan.next,
            hasSelection = true,
        )
        return true
    }

    private fun selectedText(connection: InputConnection): String {
        val surrounding = runCatching {
            connection.getSurroundingText(1024, 1024, 0)
        }.getOrNull()
        if (surrounding != null) {
            val text = surrounding.text.toString()
            val start = minOf(surrounding.selectionStart, surrounding.selectionEnd).coerceAtLeast(0)
            val end = maxOf(surrounding.selectionStart, surrounding.selectionEnd).coerceAtMost(text.length)
            if (start < end) return text.substring(start, end)
        }
        val live = runCatching {
            connection.getSelectedText(0)?.toString()
        }.getOrNull()
        if (!live.isNullOrEmpty()) return live
        val extracted = runCatching {
            connection.getExtractedText(ExtractedTextRequest(), 0)
        }.getOrNull() ?: return ""
        val start = minOf(extracted.selectionStart, extracted.selectionEnd)
        val end = maxOf(extracted.selectionStart, extracted.selectionEnd)
        val text = extracted.text?.toString().orEmpty()
        if (start < 0 || end > text.length || start >= end) return ""
        return text.substring(start, end)
    }

    private fun selectionStart(connection: InputConnection): Int? {
        val surrounding = runCatching {
            connection.getSurroundingText(1024, 1024, 0)
        }.getOrNull()
        if (surrounding != null) {
            val start = minOf(surrounding.selectionStart, surrounding.selectionEnd)
            if (start >= 0) return start
        }
        val extracted = runCatching {
            connection.getExtractedText(ExtractedTextRequest(), 0)
        }.getOrNull()
        if (extracted != null) {
            val start = minOf(extracted.selectionStart, extracted.selectionEnd)
            if (start >= 0) return start
        }
        if (lastSelStart >= 0 && lastSelEnd >= 0 && lastSelStart != lastSelEnd) {
            return minOf(lastSelStart, lastSelEnd)
        }
        return null
    }

    /**
     * Asks for the text around the cursor once typing settles, rather than on
     * the frame that has a key to draw.
     *
     * [InputConnection.getTextBeforeCursor] and its neighbours are blocking
     * round trips into the app being typed into, and the moment just after
     * pushing an edit is the worst one to make them: that app's main thread is
     * busy applying the edit, so the read queues behind it. Measured on a POCO
     * F1 typing into Messages, that was 7 to 16 ms per keystroke against a
     * 16.7 ms frame — the whole budget, spent unevenly depending on how busy
     * the other app happened to be, which is what made it read as a stutter
     * rather than as lag.
     *
     * Deferring alone is not enough, because the read is just as slow wherever
     * it lands; it only stops being slow *here*. So this also conflates: each
     * keystroke cancels the pending read and posts another, and a run of them
     * costs one read after the last, not one per letter. Nothing on the other
     * side needs to be fresher than that — the composing prefix the strip is
     * built from lives in the keyboard's own state, and what this supplies is
     * the surrounding context, which changes a word at a time.
     */
    private fun scheduleEditorTextRefresh() {
        mainHandler.removeCallbacks(editorTextRefresh)
        mainHandler.postDelayed(editorTextRefresh, EDITOR_TEXT_REFRESH_DELAY_MS)
    }

    private fun refreshEditorText() {
        mainHandler.removeCallbacks(editorTextRefresh)
        val hasSelection = lastSelStart >= 0 && lastSelEnd >= 0 && lastSelStart != lastSelEnd
        val selected = if (EditorSelectionSync.mustReadSelection(lastSelStart, lastSelEnd)) {
            runCatching {
                currentInputConnection?.getSelectedText(0)?.toString().orEmpty()
            }.getOrDefault("")
        } else {
            ""
        }
        if (!visibleSettings.value.suggestionsEnabled || editorConfig.sensitive) {
            visibleEditorText.value = EditorTextWindow(
                selected = selected,
                hasSelection = hasSelection,
            )
            typedGrammar.textChanged("", enabled = false, keep = ::typedGrammarKeeps)
            return
        }
        val before = runCatching {
            currentInputConnection?.getTextBeforeCursor(32, 0)?.toString().orEmpty()
        }.getOrDefault("")
        val after = runCatching {
            currentInputConnection?.getTextAfterCursor(32, 0)?.toString().orEmpty()
        }.getOrDefault("")
        visibleEditorText.value = EditorTextWindow(before, after, selected, hasSelection)
        // Restarts the pause timer only. The read the check needs, and the
        // model, wait until the typing stops.
        typedGrammar.textChanged(
            before,
            enabled = typedGrammarEnabled() && !hasSelection,
            keep = ::typedGrammarKeeps,
        )
    }

    private fun typedGrammarEnabled(): Boolean {
        val settings = visibleSettings.value
        return settings.typingGrammar && settings.suggestionsEnabled && !voiceShortcutActive &&
            GrammarModelCatalog.available && container.grammarModel.state.value.ready &&
            ImeInputPolicy.acceptsGrammarCheck(currentInputType)
    }

    /** Words the grammar model may not change: the user's own, as for dictation. */
    private fun typedGrammarKeeps(): Set<String> {
        val settings = visibleSettings.value
        return DictatedTranscript.grammarKeeps(
            PersonalDictionary.terms(settings.personalDictionary) + CustomVocabulary.terms(settings.customVocabulary),
            settings.snippets,
        )
    }

    private fun dismissGrammarFix() = typedGrammar.dismiss()

    /**
     * The grammar chip, tapped. The text is read again first: the fix is
     * applied only if the sentence it was worked out for is still the one
     * before the cursor, as one batch edit.
     */
    private fun applyGrammarFix() {
        // commitText replaces a selection, so a fix applied over one would
        // delete it. The strip hides the fix then; this is the backstop for a
        // tap that lands as a selection is made.
        if (lastSelStart != lastSelEnd) {
            typedGrammar.reset()
            return
        }
        val fix = typedGrammar.take() ?: return
        val connection = currentInputConnection ?: return
        val before = runCatching {
            connection.getTextBeforeCursor(TypedGrammar.READ_LIMIT, 0)?.toString()
        }.getOrNull() ?: return
        val edit = TypedGrammar.edit(fix, before) ?: return
        connection.beginBatchEdit()
        if (composingRegionActive) connection.finishComposingText()
        connection.deleteSurroundingText(edit.deleteBefore, 0)
        connection.commitText(edit.insert, 1)
        connection.endBatchEdit()
        composingRegionActive = false
        editorConfig = editorConfig.copy(cursorSync = editorConfig.cursorSync + 1)
        syncShiftFromCursor()
        scheduleEditorTextRefresh()
    }

    /**
     * Re-reads the platform's caps mode for wherever the cursor is now.
     *
     * `getCursorCapsMode` is position-aware: mid-word it answers 0 even when
     * the field asks for sentence capitalization, which is exactly the check
     * the keyboard's own shift state cannot make for itself.
     */
    private fun syncShiftFromCursor() {
        if (editorConfig.initialLayer != KeyboardLayer.LETTERS) return
        // With "Capitalize sentences" off nothing here may arm shift, and
        // leaving the user's own shift alone needs no editor read at all.
        if (!visibleSettings.value.autoCapitalizeEnabled) return
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
        if (destroyed) return
        mainHandler.post {
            // The settings collector and the clipboard listener can both get
            // here in the frame onDestroy runs; the post then lands after it.
            if (destroyed) return@post
            val settings = visibleSettings.value
            if (editorConfig.sensitive) {
                visibleClipboard.value = null
                return@post
            }
            val manager = getSystemService(ClipboardManager::class.java)
            val description = manager?.primaryClipDescription
            val clip = manager?.primaryClip
            val imageMime = clipImageMime(description)
            val rawText = runCatching {
                clip?.getItemAt(0)?.coerceToText(this)?.toString()
            }.getOrNull()?.trim().orEmpty()
            val text = rawText.takeIf { it.isNotEmpty() && !isImageUriText(it, imageMime != null) }
            when {
                !text.isNullOrEmpty() -> showClipboardText(text, settings)
                imageMime != null -> {
                    val uri = clip?.getItemAt(0)?.uri
                    if (uri != null) showClipboardImage(uri, imageMime, settings)
                    else visibleClipboard.value = null
                }
                else -> visibleClipboard.value = null
            }
        }
    }

    private fun showClipboardText(text: String, settings: VocaPhoneSettings) {
        if (settings.clipboardHistoryEnabled && text != lastRecordedClip) {
            lastRecordedClip = text
            persistPreference { container.settings.recordClipboardHistory(text) }
        }
        visibleClipboard.value = text.takeIf {
            KeyboardChrome.offersClipboardChip(it, dismissedClip(settings), settings.clipboardChipEnabled)
        }?.let { value ->
            ClipboardChip(
                preview = KeyboardChrome.clipboardPreview(value),
                fullText = value,
            )
        }
    }

    private fun showClipboardImage(uri: Uri, mime: String, settings: VocaPhoneSettings) {
        val source = uri.toString()
        val reused = lastRecordedClip
        if (source == lastImageSource && reused != null && ClipboardHistory.isImage(reused)) {
            visibleClipboard.value = reused.takeIf {
                KeyboardChrome.offersClipboardChip(it, dismissedClip(settings), settings.clipboardChipEnabled)
            }?.let {
                ClipboardChip(
                    preview = "Image",
                    fullText = it,
                    imagePath = ClipboardHistory.parseImage(it)?.second,
                )
            }
            return
        }
        scope.launch {
            val relative = withContext(Dispatchers.IO) {
                ClipboardImages.cache(this@VocaPhoneInputMethodService, uri, mime)
            } ?: run {
                visibleClipboard.value = null
                return@launch
            }
            val encoded = ClipboardHistory.encodeImage(mime, relative)
            lastImageSource = source
            if (settings.clipboardHistoryEnabled && encoded != lastRecordedClip) {
                lastRecordedClip = encoded
                persistPreference { container.settings.recordClipboardHistory(encoded) }
            } else {
                lastRecordedClip = encoded
            }
            visibleClipboard.value = encoded.takeIf {
                KeyboardChrome.offersClipboardChip(it, dismissedClip(settings), settings.clipboardChipEnabled)
            }?.let {
                ClipboardChip(preview = "Image", fullText = it, imagePath = relative)
            }
        }
    }

    private fun clipImageMime(description: ClipDescription?): String? {
        if (description == null) return null
        for (index in 0 until description.mimeTypeCount) {
            val mime = description.getMimeType(index)
            if (mime.startsWith("image/")) return mime
        }
        return null
    }

    private fun isImageUriText(text: String, hasImage: Boolean): Boolean =
        hasImage && (text.startsWith("content://") || text.startsWith("file://"))

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
            else -> when (MicDictationControl.tap(lastState.phase)) {
                MicDictationAction.FINISH -> {
                    container.diagnostics.recordAction("finish", DictationSource.IME.name)
                    finishImeDictation()
                }
                MicDictationAction.CANCEL -> {
                    container.diagnostics.recordAction("cancel", DictationSource.IME.name)
                    cancelImeDictation()
                }
                MicDictationAction.RECHECK_SETUP -> scope.launch {
                    if (container.dictation.recheckRepair(DictationSource.IME)) {
                        startImeDictation()
                    } else {
                        // Straight to the page with the fix: Models for a
                        // model, Speech for a gateway, Dictate for permissions.
                        openCompanion(page = container.dictation.state.value.repairPage)
                    }
                }
                MicDictationAction.NONE -> Unit
                MicDictationAction.START -> startImeDictation()
            }
        }
    }

    private fun cancelDictationFromMic() {
        if (MicDictationControl.longPress(lastState.phase) != MicDictationAction.CANCEL) return
        container.diagnostics.recordAction("cancel", DictationSource.IME.name)
        cancelImeDictation()
    }

    private fun setLanguage(language: TranscriptionLanguage) {
        val settings = visibleSettings.value
        if (!ModelLanguageSupport.isSelectable(language, settings.activeModelLanguages)) {
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

    /**
     * The field this keyboard's dictation was for is going away.
     *
     * This used to cancel, which deleted the recording -- a sentence lost to
     * tapping another field, or the keyboard being swapped out, mid-dictation.
     * It finishes instead: recording stops now, and transcription carries on.
     * The transcript can never land in whichever field has focus by then,
     * because [insert] only accepts the field the dictation started in; it is
     * saved to History, and the keyboard offers it as "Saved to History".
     * finish() only completes a signal, so it is safe from onDestroy too.
     */
    private fun releaseOwnedDictation(reason: String) {
        if (!startedImeDictation) return
        container.diagnostics.recordAction(reason, DictationSource.IME.name)
        startedImeDictation = false
        container.dictation.finish()
    }

    /** Retry of the recording the keyboard's failure kept, into this field. */
    private fun retryImeDictation() {
        val state = lastState
        if (!state.canRetry || preferenceWrites.isPending) return
        val sessionId = state.sessionId ?: return
        if (!ImeInputPolicy.acceptsDictation(currentInputType)) return
        container.diagnostics.recordAction("retry", DictationSource.IME.name)
        startedImeDictation = true
        dictationEditorSession = editorSession
        if (voiceShortcutActive) {
            mainHandler.removeCallbacks(delayedFailedHandback)
            voiceShortcutOwnedSession = true
            voiceShortcutStartRequested = true
        }
        container.dictation.retry(sessionId.toString(), DictationSource.IME)
    }

    /**
     * "Insert" on a transcript saved to History: the user asking for it here,
     * in the field they are in now. Never automatic -- see [insert].
     */
    private fun insertSavedTranscript() {
        val state = lastState
        if (state.phase != DictationPhase.READY_TO_INSERT) return
        val transcript = state.transcript?.let(TranscriptSanitizer::clean)?.takeIf { it.isNotBlank() } ?: return
        if (!ImeInputPolicy.acceptsDictation(currentInputType)) return
        val connection = currentInputConnection ?: return
        val committed = commitDictation(connection, transcript, composingRegionActive, lastSelStart, lastSelEnd)
        composingRegionActive = false
        editorConfig = editorConfig.copy(cursorSync = editorConfig.cursorSync + 1)
        if (!committed) return
        container.diagnostics.recordAction("saved_inserted", DictationSource.IME.name)
        syncShiftFromCursor()
        refreshEditorText()
        container.dictation.savedTranscriptInserted(currentInputEditorInfo?.packageName)
    }

    private fun startImeDictation() {
        if (lastState.phase == DictationPhase.FAILED ||
            lastState.phase == DictationPhase.READY_TO_INSERT ||
            lastState.phase == DictationPhase.INSERTED
        ) {
            container.dictation.clearTransient()
        }
        startedImeDictation = true
        dictationEditorSession = editorSession
        if (voiceShortcutActive) {
            voiceShortcutOwnedSession = true
            voiceShortcutStartRequested = true
        }
        if (VoiceShortcutIme.usesMicrophoneForegroundService(voiceShortcutActive)) {
            DictationService.start(this, DictationSource.IME)
        } else {
            container.dictation.start(DictationSource.IME)
        }
    }

    private fun finishImeDictation() {
        if (VoiceShortcutIme.usesMicrophoneForegroundService(voiceShortcutActive)) {
            DictationService.send(this, DictationService.ACTION_FINISH)
        } else {
            container.dictation.finish()
        }
    }

    private fun cancelImeDictation() {
        if (VoiceShortcutIme.usesMicrophoneForegroundService(voiceShortcutActive)) {
            DictationService.send(this, DictationService.ACTION_CANCEL)
        } else {
            container.dictation.cancel()
        }
    }

    private fun currentSubtype(): InputMethodSubtype? =
        getSystemService(InputMethodManager::class.java)?.currentInputMethodSubtype

    private fun publishVoiceShortcutSubtypes() {
        VoiceShortcutIme.publishEnabledSubtypes(this)
    }

    private fun applyVoiceShortcutSubtype(subtype: InputMethodSubtype?) {
        val active = VoiceShortcutIme.isVoiceShortcutSubtype(
            mode = subtype?.mode,
            auxiliary = subtype?.isAuxiliary == true,
        )
        if (active == voiceShortcutActive) return
        voiceShortcutActive = active
        voiceShortcutOwnedSession = false
        voiceShortcutStartRequested = false
        voiceShortcutLeftIdle = false
        voiceShortcutReturned = false
        voiceShortcutWindowWaits = 0
        mainHandler.removeCallbacks(delayedRejectedHandback)
        mainHandler.removeCallbacks(delayedFailedHandback)
        voiceShortcutRejectGuidance = false
    }

    private fun scheduleVoiceShortcutDictation() {
        if (!voiceShortcutActive) return
        mainHandler.removeCallbacks(startVoiceShortcutDictation)
        voiceShortcutWindowWaits = 0
        mainHandler.post(startVoiceShortcutDictation)
    }

    private fun maybeStartVoiceShortcutDictation() {
        if (VoiceShortcutIme.shouldAutoStart(
                isVoiceShortcut = voiceShortcutActive,
                dictationAllowed = editorConfig.dictationAllowed,
                isBusy = lastState.phase.isBusy,
                alreadyRequested = voiceShortcutStartRequested,
                inputViewShown = isInputViewShown,
            )
        ) {
            startImeDictation()
            return
        }
        if (VoiceShortcutIme.shouldWaitForInputView(
                isVoiceShortcut = voiceShortcutActive,
                alreadyRequested = voiceShortcutStartRequested,
                inputViewShown = isInputViewShown,
                waitAttempts = voiceShortcutWindowWaits,
            )
        ) {
            voiceShortcutWindowWaits++
            mainHandler.postDelayed(startVoiceShortcutDictation, VoiceShortcutIme.WINDOW_WAIT_DELAY_MS)
        }
    }

    private fun maybeHandBackVoiceShortcut() {
        val effects = VoiceShortcutIme.rejectedHandbackEffects(
            decision = VoiceShortcutIme.rejectedHandback(
                isVoiceShortcut = voiceShortcutActive,
                dictationAllowed = editorConfig.dictationAllowed,
                sensitive = editorConfig.sensitive,
            ),
            alreadyReturned = voiceShortcutReturned,
        ) ?: return
        // Keep the chrome up for a beat with a one-line hint so the system
        // IME picker path does not look like a broken flicker. Late-capable
        // EditorInfo while GUIDED chrome is up cancels the bounce and starts
        // (same as delayedRejectedHandback's NONE arm).
        if (effects.cancelDelayedHandback) {
            mainHandler.removeCallbacks(delayedRejectedHandback)
        }
        voiceShortcutRejectGuidance = effects.showGuidance
        if (effects.scheduleDelayedHandback) {
            mainHandler.postDelayed(
                delayedRejectedHandback,
                VoiceShortcutIme.REJECTED_HANDBACK_DELAY_MS,
            )
        }
        if (effects.returnImmediately) {
            returnToPreviousIme()
        }
        if (effects.requestAutoStart) {
            maybeStartVoiceShortcutDictation()
        }
    }

    private fun maybeReturnToPreviousIme() {
        if (voiceShortcutReturned) return
        if (!VoiceShortcutIme.shouldReturnToPreviousIme(
                isVoiceShortcut = voiceShortcutActive,
                ownedSession = voiceShortcutOwnedSession,
                sessionLeftIdle = voiceShortcutLeftIdle,
                phase = lastState.phase,
            )
        ) {
            // A Retry, or anything else that keeps the shortcut, calls off a
            // handback a failure scheduled.
            mainHandler.removeCallbacks(delayedFailedHandback)
            return
        }
        val delay = VoiceShortcutIme.handbackDelayMillis(lastState.phase)
        if (delay > 0L) {
            // Once per failure: a later emission of the same state must not
            // push the handback back again.
            if (!mainHandler.hasCallbacks(delayedFailedHandback)) {
                mainHandler.postDelayed(delayedFailedHandback, delay)
            }
            return
        }
        mainHandler.removeCallbacks(delayedFailedHandback)
        returnToPreviousIme()
    }

    private fun returnToPreviousIme() {
        if (voiceShortcutReturned) return
        voiceShortcutReturned = true
        voiceShortcutOwnedSession = false
        if (!switchToPreviousInputMethod()) {
            voiceShortcutReturned = false
        }
    }

    /** Space bar long-press: the system list of enabled keyboards (#402). */
    private fun showKeyboardPicker() {
        getSystemService(InputMethodManager::class.java)?.showInputMethodPicker()
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

        /**
         * Long enough that a burst of typing collapses into one read, short
         * enough that it has landed before anyone who paused looks up.
         */
        const val EDITOR_TEXT_REFRESH_DELAY_MS = 50L

        /** How long the grammar session outlives the keyboard going away. */
        const val TYPED_GRAMMAR_RELEASE_DELAY_MS = 60_000L
    }
}
