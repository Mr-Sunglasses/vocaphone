package com.vocahq.vocaphone.accessibility

import android.accessibilityservice.AccessibilityService
import android.app.KeyguardManager
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import com.vocahq.vocaphone.VocaPhoneApplication
import com.vocahq.vocaphone.core.BubblePolicy
import com.vocahq.vocaphone.core.FieldClassifier
import com.vocahq.vocaphone.core.FieldEligibility
import com.vocahq.vocaphone.core.FieldSignals
import com.vocahq.vocaphone.core.TextInsertion
import com.vocahq.vocaphone.dictation.AppliedInsertion
import com.vocahq.vocaphone.dictation.InsertionOutcome
import com.vocahq.vocaphone.dictation.InsertionReport
import com.vocahq.vocaphone.dictation.TranscriptInserter
import com.vocahq.vocaphone.overlay.BubbleController
import com.vocahq.vocaphone.settings.BubbleBehavior
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.withContext

/**
 * VocaPhone's only use of accessibility access: knowing whether the focused
 * field can be dictated into, and writing the user's transcript into it. Field
 * contents are read into memory only at the moment of insertion, and are never
 * stored, logged or uploaded.
 */
class VocaPhoneAccessibilityService : AccessibilityService(), TranscriptInserter {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var bubble: BubbleController? = null
    private var excludedPackages: Set<String> = emptySet()
    private var bubbleBehavior: BubbleBehavior = BubbleBehavior.EVERY_EDITABLE_FIELD

    override fun onServiceConnected() {
        super.onServiceConnected()
        applyEventMask()
        val container = VocaPhoneApplication.container(this)
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
        val type = event?.eventType ?: return
        if (type and EVENT_MASK != 0) refreshBubble()
    }

    /**
     * Re-declares which events this service wants, every time it connects.
     *
     * The same list is in `accessibility_service_config.xml`, but that file is
     * only read when the service is enabled — an app update does not re-read
     * it. Measured on a POCO F1: shipping a build that added two event types
     * left the framework serving the *old* mask, so the newly handled fields
     * stayed dead until the user toggled the service off and on. Every existing
     * user would have updated into that. Asserting the mask here applies it on
     * the connect that follows the update, so the XML only ever has to be right
     * for a fresh install.
     */
    private fun applyEventMask() {
        val info = serviceInfo ?: return
        if (info.eventTypes == EVENT_MASK) return
        info.eventTypes = EVENT_MASK
        runCatching { serviceInfo = info }
    }

    override fun onInterrupt() = Unit

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        val container = VocaPhoneApplication.container(this)
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
            dictationBusy = VocaPhoneApplication.container(this).dictation.state.value.phase.isBusy,
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

    /**
     * The focused text field, however the app's UI toolkit chooses to describe
     * one.
     *
     * `findFocus(FOCUS_INPUT)` alone only answers for classic View hierarchies,
     * and it fails in two different directions. On a Compose toolbar it hands
     * back the non-editable wrapper around the real field — a bare
     * `android.view.View` reporting `isFocused` as false. Inside a WebView
     * editor it returns null outright. Firefox's address bar and Gmail's
     * compose body were both silent dead ends for those reasons.
     *
     * So: take the framework's answer when it is usable, then look inside it
     * for the field a wrapper is hiding, and failing that ask the windows
     * directly for the node that claims focus itself. Both routes are needed —
     * the wrapper descent is what recovers Compose, the window search is what
     * recovers WebView.
     */
    private fun focusedEditableNode(): AccessibilityNodeInfo? {
        val reported = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (reported != null) {
            // The framework can hand back a node from a window that no longer
            // exists; refresh proves it is still alive before anything trusts it.
            if (reported.refresh() && reported.isUsableTarget) return reported
            // A wrapper: the field Compose actually draws is inside it.
            reported.focusedTargetInSubtree()?.let { found ->
                reported.recycleCompat()
                return found
            }
            reported.recycleCompat()
        }
        // Not rootInActiveWindow alone: it comes back null often enough that a
        // single source would be its own dead end, so every window is asked.
        // The IME's own window is skipped — its keys are editable-looking nodes
        // and none of them is the user's field.
        val budget = intArrayOf(SEARCH_NODE_BUDGET)
        for (root in searchableRoots()) {
            val found = root.focusedTargetInSubtree(budget)
            if (found != null) {
                if (found !== root) root.recycleCompat()
                return found
            }
            root.recycleCompat()
        }
        return null
    }

    private fun searchableRoots(): List<AccessibilityNodeInfo> = buildList {
        rootInActiveWindow?.let { add(it) }
        runCatching { windows }.getOrNull().orEmpty().forEach { window ->
            if (window.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD) return@forEach
            runCatching { window.root }.getOrNull()?.let { add(it) }
        }
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
                // `adb logcat -s VocaPhone`. Metadata only — lengths, flags and
                // the app's own hint; never the user's text or transcript.
                android.util.Log.d(
                    "VocaPhone",
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

    private companion object {
        /**
         * Everything that can mean "the field under the cursor may have
         * changed". Mirrored in `accessibility_service_config.xml` for the
         * first connection of a fresh install; [applyEventMask] is what keeps
         * an updated install honest.
         *
         * Text-changed and clicked are here for editors that announce nothing
         * else: focusing Gmail's compose body reports neither focus nor
         * selection, so without them the bubble never re-evaluated at all.
         */
        const val EVENT_MASK =
            AccessibilityEvent.TYPE_VIEW_FOCUSED or
                AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED or
                AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED or
                AccessibilityEvent.TYPE_VIEW_CLICKED or
                AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
                AccessibilityEvent.TYPE_WINDOWS_CHANGED
    }
}

/**
 * Whether this node is the field the user is typing in and can be written to.
 *
 * `isEditable` is not required on its own: a WebView editor or a Compose text
 * field can advertise [AccessibilityNodeInfo.ACTION_SET_TEXT] — which is the
 * capability insertion actually uses — without setting the editable flag.
 */
internal val AccessibilityNodeInfo.isUsableTarget: Boolean
    get() = isFocused && isEnabled && isVisibleToUser && acceptsText

internal val AccessibilityNodeInfo.acceptsText: Boolean
    get() = isEditable || actionList.any { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT }

/**
 * Depth-first search for the node that reports itself focused. Bounded because
 * this runs on every accessibility event, and an unbounded walk of a large web
 * page would be paid on each one.
 */
internal fun AccessibilityNodeInfo.focusedTargetInSubtree(
    budget: IntArray = intArrayOf(SEARCH_NODE_BUDGET),
    depth: Int = 0,
): AccessibilityNodeInfo? {
    if (depth > SEARCH_MAX_DEPTH || budget[0] <= 0) return null
    budget[0]--

    if (isUsableTarget) return this

    for (index in 0 until childCount) {
        val child = runCatching { getChild(index) }.getOrNull() ?: continue
        val found = child.focusedTargetInSubtree(budget, depth + 1)
        if (found != null) return found
        child.recycleCompat()
    }
    return null
}

private const val SEARCH_NODE_BUDGET = 600
private const val SEARCH_MAX_DEPTH = 40

internal fun AccessibilityNodeInfo.toSignals() = FieldSignals(
    editable = acceptsText,
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
