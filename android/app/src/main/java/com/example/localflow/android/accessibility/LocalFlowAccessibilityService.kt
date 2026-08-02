package com.example.localflow.android.accessibility

import android.accessibilityservice.AccessibilityService
import android.app.KeyguardManager
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.example.localflow.android.LocalFlowApplication
import com.example.localflow.android.core.FieldClassifier
import com.example.localflow.android.core.FieldEligibility
import com.example.localflow.android.core.FieldSignals
import com.example.localflow.android.core.TextInsertion
import com.example.localflow.android.dictation.AppliedInsertion
import com.example.localflow.android.dictation.InsertionOutcome
import com.example.localflow.android.dictation.InsertionReport
import com.example.localflow.android.dictation.TranscriptInserter
import com.example.localflow.android.overlay.BubbleController
import com.example.localflow.android.settings.BubbleBehavior
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
        if (bubbleBehavior == BubbleBehavior.OFF) {
            controller.hide()
            return
        }
        // A dictation already in flight keeps the bubble up while the user moves
        // between apps; only an idle bubble follows focus.
        if (LocalFlowApplication.container(this).dictation.state.value.phase.isBusy) {
            controller.show()
            return
        }
        val node = focusedEditableNode()
        val eligible = node != null && classify(node) == FieldEligibility.ELIGIBLE
        node?.recycleCompat()
        if (eligible) controller.show() else controller.hide()
    }

    private fun classify(node: AccessibilityNodeInfo): FieldEligibility =
        FieldClassifier.classify(node.toSignals(), excludedPackages)

    private fun focusedEditableNode(): AccessibilityNodeInfo? {
        val focused = findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return null
        if (!focused.isEditable) {
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
                if (!node.refresh()) return@withContext InsertionReport(InsertionOutcome.NO_TARGET)
                if (classify(node) != FieldEligibility.ELIGIBLE) {
                    return@withContext InsertionReport(InsertionOutcome.NO_TARGET)
                }

                val existing = TextInsertion.fieldContents(
                    text = node.text?.toString(),
                    showingHintText = node.isShowingHintText,
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
                if (!node.refresh()) return@withContext false
                if (node.packageName?.toString() != insertion.packageName) return@withContext false

                val current = TextInsertion.fieldContents(
                    text = node.text?.toString(),
                    showingHintText = node.isShowingHintText,
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
