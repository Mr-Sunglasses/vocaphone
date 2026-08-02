package io.github.mrsunglasses.localflow.accessibility

import android.accessibilityservice.AccessibilityService
import android.app.KeyguardManager
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import io.github.mrsunglasses.localflow.LocalFlowApplication
import io.github.mrsunglasses.localflow.core.BubblePolicy
import io.github.mrsunglasses.localflow.core.FieldClassifier
import io.github.mrsunglasses.localflow.core.FieldEligibility
import io.github.mrsunglasses.localflow.core.FieldSignals
import io.github.mrsunglasses.localflow.core.TextInsertion
import io.github.mrsunglasses.localflow.dictation.AppliedInsertion
import io.github.mrsunglasses.localflow.dictation.InsertionOutcome
import io.github.mrsunglasses.localflow.dictation.InsertionReport
import io.github.mrsunglasses.localflow.dictation.TranscriptInserter
import io.github.mrsunglasses.localflow.overlay.BubbleController
import io.github.mrsunglasses.localflow.settings.BubbleBehavior
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.withContext

/**
 * Local Flow's only use of accessibility access: knowing whether the focused
 * field can be dictated into, and writing the user's transcript into it. Field
 * contents are read into memory only at the moment of insertion, and are never
 * stored, logged or uploaded.
 */
class LocalFlowAccessibilityService : AccessibilityService(), TranscriptInserter {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var bubble: BubbleController? = null
    private var excludedPackages: Set<String> = emptySet()
    private var bubbleBehavior: BubbleBehavior = BubbleBehavior.EVERY_EDITABLE_FIELD

    override fun onServiceConnected() {
        super.onServiceConnected()
        val container = LocalFlowApplication.container(this)
        container.dictation.inserter = this

        bubble = BubbleController(this, container.dictation).also { it.attach(scope) }

        container.settings.settings
            .onEach { settings ->
                excludedPackages = settings.excludedPackages
                bubbleBehavior = settings.bubbleBehavior
                if (settings.bubbleBehavior == BubbleBehavior.OFF) bubble?.hide()
            }
            .launchIn(scope)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        when (event?.eventType) {
            AccessibilityEvent.TYPE_VIEW_FOCUSED,
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOWS_CHANGED,
            -> refreshBubble()

            else -> Unit
        }
    }

    override fun onInterrupt() = Unit

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        val container = LocalFlowApplication.container(this)
        if (container.dictation.inserter === this) container.dictation.inserter = null
        bubble?.detach()
        bubble = null
        scope.cancel()
        return super.onUnbind(intent)
    }

    // -------------------------------------------------------------- bubble

    private fun refreshBubble() {
        val controller = bubble ?: return
        val imeVisible = isImeVisible()
        // The keyboard closing is what clears a ✕ dismissal, so the controller
        // has to hear about every visibility change, including while hidden.
        controller.onImeVisibility(imeVisible)

        val node = focusedEditableNode()
        val eligible = node != null && classify(node) == FieldEligibility.ELIGIBLE
        node?.recycleCompat()

        val decision = BubblePolicy.decide(
            bubbleEnabled = bubbleBehavior != BubbleBehavior.OFF,
            dictationBusy = LocalFlowApplication.container(this).dictation.state.value.phase.isBusy,
            imeVisible = imeVisible,
            fieldEligible = eligible,
            snoozed = controller.isSnoozed,
            dismissed = controller.isDismissed,
        )
        if (decision == BubblePolicy.Decision.SHOW) controller.show() else controller.hide()
    }

    /**
     * The bubble lives with the keyboard, so IME visibility is the primary
     * signal. An empty window list means the interactive-windows flag has not
     * taken effect yet; treating that as visible degrades to focus-only
     * behaviour instead of never showing the bubble at all.
     */
    private fun isImeVisible(): Boolean {
        val visibleWindows = runCatching { windows }.getOrNull() ?: return true
        if (visibleWindows.isEmpty()) return true
        return visibleWindows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
    }

    private fun classify(node: AccessibilityNodeInfo): FieldEligibility =
        FieldClassifier.classify(node.toSignals(), excludedPackages)

    private fun focusedEditableNode(): AccessibilityNodeInfo? {
        val focused = findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return null
        // The framework can hand back a node from a window that no longer
        // exists; refresh proves it is still alive, still focused, and still
        // editable before anything trusts it.
        if (!focused.refresh() || !focused.isEditable || !focused.isFocused) {
            focused.recycleCompat()
            return null
        }
        return focused
    }

    // ----------------------------------------------------------- insertion

    override fun currentTargetPackage(): String? =
        runCatching { rootInActiveWindow?.packageName?.toString() }.getOrNull()

    override suspend fun insert(transcript: String): InsertionReport =
        withContext(Dispatchers.Main.immediate) {
            if (isDeviceLocked()) return@withContext InsertionReport(InsertionOutcome.NO_TARGET)

            // Reacquired here, not at Start: cross-app dictation must follow the
            // latest safe target rather than a node that may no longer exist.
            val node = focusedEditableNode() ?: return@withContext InsertionReport(InsertionOutcome.NO_TARGET)
            try {
                if (classify(node) != FieldEligibility.ELIGIBLE) {
                    return@withContext InsertionReport(InsertionOutcome.NO_TARGET)
                }

                var existing = TextInsertion.fieldContents(
                    text = node.text?.toString(),
                    showingHintText = node.isShowingHintText,
                    hintText = node.hintText?.toString(),
                )
                // WhatsApp exposes its placeholder as plain text: no hint, no
                // showing-hint flag, and — the tell — no cursor. A focused
                // editable with genuine content always reports one. Probe by
                // trying to place the cursor at the end of the claimed text:
                // on the empty editable underneath a placeholder that position
                // is out of bounds and the action fails, while real typed text
                // accepts it. Either way nothing is modified except, at most,
                // moving a real cursor to exactly where the splice would put it.
                var probedEmpty = false
                if (existing.isNotEmpty() && node.textSelectionStart < 0 && node.textSelectionEnd < 0) {
                    val probe = Bundle().apply {
                        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, existing.length)
                        putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, existing.length)
                    }
                    if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, probe)) {
                        existing = ""
                        probedEmpty = true
                    }
                }
                // Kept at debug for diagnosing the next misbehaving editor via
                // `adb logcat -s LocalFlow`. Metadata only — lengths, flags and
                // the app's own hint; never the user's text or transcript.
                android.util.Log.d(
                    "LocalFlow",
                    "insert target: pkg=${node.packageName} textLen=${node.text?.length ?: -1} " +
                        "showingHint=${node.isShowingHintText} hint=${node.hintText} " +
                        "sel=${node.textSelectionStart}..${node.textSelectionEnd} " +
                        "probedEmpty=$probedEmpty treatedAsEmpty=${existing.isEmpty()}",
                )
                val selectionStart = node.textSelectionStart.takeIf { it in 0..existing.length }
                    ?: existing.length
                val selectionEnd = node.textSelectionEnd.takeIf { it in 0..existing.length }
                    ?: selectionStart
                val plan = TextInsertion.plan(existing, selectionStart, selectionEnd, transcript)
                    ?: return@withContext InsertionReport(InsertionOutcome.NO_TARGET)

                val setText = Bundle().apply {
                    putCharSequence(
                        AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                        plan.updatedText,
                    )
                }
                if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, setText)) {
                    // A custom editor without text actions: the transcript stays in
                    // history with an explicit manual-copy action. Never the clipboard.
                    return@withContext InsertionReport(InsertionOutcome.UNSUPPORTED_EDITOR)
                }
                restoreCursor(node, plan.cursor)

                InsertionReport(
                    outcome = InsertionOutcome.INSERTED,
                    applied = AppliedInsertion(
                        packageName = node.packageName?.toString(),
                        insertionStart = plan.insertionStart,
                        inserted = plan.inserted,
                    ),
                )
            } finally {
                node.recycleCompat()
            }
        }

    override suspend fun undo(insertion: AppliedInsertion): Boolean =
        withContext(Dispatchers.Main.immediate) {
            val node = focusedEditableNode() ?: return@withContext false
            try {
                if (node.packageName?.toString() != insertion.packageName) return@withContext false

                val current = TextInsertion.fieldContents(
                    text = node.text?.toString(),
                    showingHintText = node.isShowingHintText,
                    hintText = node.hintText?.toString(),
                )
                // Undo is only safe while the exact transcript is still where it was
                // written; any edit by the user or the app disables it.
                val reverted = TextInsertion.undo(current, insertion.insertionStart, insertion.inserted)
                    ?: return@withContext false

                val setText = Bundle().apply {
                    putCharSequence(
                        AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                        reverted,
                    )
                }
                if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, setText)) {
                    return@withContext false
                }
                restoreCursor(node, insertion.insertionStart)
                true
            } finally {
                node.recycleCompat()
            }
        }

    private fun restoreCursor(node: AccessibilityNodeInfo, position: Int) {
        val selection = Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, position)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, position)
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, selection)
    }

    private fun isDeviceLocked(): Boolean =
        getSystemService(KeyguardManager::class.java)?.isKeyguardLocked ?: false
}

internal fun AccessibilityNodeInfo.toSignals() = FieldSignals(
    editable = isEditable,
    visibleToUser = isVisibleToUser,
    enabled = isEnabled,
    password = isPassword,
    inputType = inputType,
    hintText = hintText?.toString(),
    viewIdResourceName = viewIdResourceName,
    packageName = packageName?.toString(),
)

/** `recycle()` is a no-op from API 33 onward but keeps older behaviour explicit. */
@Suppress("DEPRECATION")
internal fun AccessibilityNodeInfo.recycleCompat() {
    runCatching { recycle() }
}
