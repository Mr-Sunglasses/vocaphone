package com.vocahq.vocaphone.ime

import android.inputmethodservice.InputMethodService
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import com.vocahq.vocaphone.R
import com.vocahq.vocaphone.VocaPhoneApplication
import com.vocahq.vocaphone.core.DictationPhase
import com.vocahq.vocaphone.core.DictationState
import com.vocahq.vocaphone.core.ImeInputPolicy
import com.vocahq.vocaphone.core.TranscriptSanitizer
import com.vocahq.vocaphone.dictation.AppliedInsertion
import com.vocahq.vocaphone.dictation.DictationService
import com.vocahq.vocaphone.dictation.DictationSource
import com.vocahq.vocaphone.dictation.InsertionOutcome
import com.vocahq.vocaphone.dictation.InsertionReport
import com.vocahq.vocaphone.dictation.TranscriptInserter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Feasibility-spike keyboard for system-wide dictation.
 *
 * This service deliberately stays small. It proves the important platform path:
 * the keyboard owns the focused InputConnection, while the existing dictation
 * controller continues to own capture, gateway delivery and retryable history.
 */
class VocaPhoneInputMethodService : InputMethodService(), TranscriptInserter {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val container by lazy { VocaPhoneApplication.container(this) }

    private var inputView: View? = null
    private var statusView: TextView? = null
    private var partialView: TextView? = null
    private var elapsedView: TextView? = null
    private var progressView: ProgressBar? = null
    private var dictateButton: Button? = null
    private var lastState = DictationState()
    private var currentInputType: Int = 0
    private var startedImeDictation = false

    override fun onCreate() {
        super.onCreate()
        container.dictation.imeInserter = this
        scope.launch {
            container.dictation.state.collect { state ->
                lastState = state
                if (!state.phase.isBusy) startedImeDictation = false
                render(state)
            }
        }
    }

    override fun onCreateInputView(): View = layoutInflater
        .inflate(R.layout.input_method_view, null)
        .also { view ->
            inputView = view
            statusView = view.findViewById(R.id.ime_status)
            partialView = view.findViewById(R.id.ime_partial)
            elapsedView = view.findViewById(R.id.ime_elapsed)
            progressView = view.findViewById(R.id.ime_progress)
            dictateButton = view.findViewById<Button>(R.id.ime_dictate).also { button ->
                button.setOnClickListener { toggleDictation() }
            }
            view.findViewById<Button>(R.id.ime_switch).setOnClickListener {
                getSystemService(InputMethodManager::class.java)?.showInputMethodPicker()
            }
            render(lastState)
        }

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        currentInputType = attribute?.inputType ?: 0
        render(lastState)
    }

    override fun onFinishInput() {
        // The InputConnection belongs to the editor that just lost focus. Do not
        // leave its input type eligible while Android is transitioning elsewhere.
        currentInputType = 0
        render(lastState)
        super.onFinishInput()
    }

    override fun onDestroy() {
        if (startedImeDictation && lastState.phase.isBusy) {
            // Switching away from VocaPhone must not leave its microphone session
            // alive after the keyboard that owns it has gone away.
            container.dictation.cancel()
        }
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

            val committed = runCatching { connection.commitText(cleaned, 1) }
                .getOrDefault(false)
            if (!committed) {
                InsertionReport(InsertionOutcome.UNSUPPORTED_EDITOR)
            } else {
                // InputConnection does not expose a portable undo range. The IME
                // proves insertion only; undo is intentionally not advertised.
                InsertionReport(InsertionOutcome.INSERTED)
            }
        }

    override suspend fun undo(insertion: AppliedInsertion): Boolean = false

    override fun currentTargetPackage(): String? =
        currentInputEditorInfo?.packageName

    private fun toggleDictation() {
        when {
            !ImeInputPolicy.acceptsDictation(currentInputType) -> render(lastState)
            lastState.phase == DictationPhase.LISTENING ->
                DictationService.send(this, DictationService.ACTION_FINISH)
            lastState.phase.isBusy ->
                DictationService.send(this, DictationService.ACTION_CANCEL)
            lastState.phase == DictationPhase.PERMISSION_REPAIR -> openCompanion()
            lastState.phase == DictationPhase.FAILED -> openCompanion()
            else -> {
                startedImeDictation = true
                DictationService.start(this, DictationSource.IME)
            }
        }
    }

    private fun openCompanion() {
        packageManager.getLaunchIntentForPackage(packageName)?.let { intent ->
            startActivity(intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    private fun render(state: DictationState) {
        if (inputView == null) return

        val accepted = ImeInputPolicy.acceptsDictation(currentInputType)
        statusView?.text = when {
            !accepted -> "Dictation is unavailable in password or non-text fields."
            state.phase == DictationPhase.PERMISSION_REPAIR -> "Open VocaPhone to finish setup."
            else -> state.statusText
        }
        val recording = state.isRecording
        partialView?.apply {
            text = state.partialTranscript
            visibility = if (recording && state.partialTranscript.isNotEmpty()) View.VISIBLE else View.GONE
        }
        elapsedView?.apply {
            text = if (recording) "${state.recordedMillis / 1000}s" else ""
            visibility = if (recording) View.VISIBLE else View.GONE
        }
        progressView?.apply {
            progress = (state.level.coerceIn(0f, 1f) * 100).toInt()
            visibility = if (recording) View.VISIBLE else View.GONE
        }
        dictateButton?.apply {
            isEnabled = accepted && state.phase !in setOf(
                DictationPhase.FINALIZING,
                DictationPhase.UPLOADING,
                DictationPhase.TRANSCRIBING,
                DictationPhase.INSERTING,
            )
            text = when {
                state.phase == DictationPhase.LISTENING -> getString(R.string.ime_finish)
                state.phase.isBusy -> getString(R.string.ime_cancel)
                state.phase == DictationPhase.PERMISSION_REPAIR || state.phase == DictationPhase.FAILED ->
                    getString(R.string.ime_open_app)
                else -> getString(R.string.ime_dictate)
            }
            contentDescription = text
        }
    }
}
