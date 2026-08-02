package com.example.localflow.android.overlay

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.PixelFormat
import android.os.SystemClock
import android.provider.Settings
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.TextView
import com.example.localflow.android.R
import com.example.localflow.android.core.DictationPhase
import com.example.localflow.android.core.DictationState
import com.example.localflow.android.dictation.DictationController
import com.example.localflow.android.dictation.DictationService
import com.example.localflow.android.dictation.DictationSource
import kotlin.math.abs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach

/**
 * The floating dictation bubble. It never takes focus, so the user's own
 * keyboard stays active and ordinary typing is unaffected.
 */
class BubbleController(
    private val context: Context,
    private val dictation: DictationController,
) {
    private val windowManager = context.getSystemService(WindowManager::class.java)
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private val longPressTimeout = ViewConfiguration.getLongPressTimeout().toLong()

    private var root: View? = null
    private var status: TextView? = null
    private var mic: ImageButton? = null
    private var finish: ImageButton? = null
    private var cancel: ImageButton? = null

    private var snoozedUntilElapsed = 0L
    private var pushToTalkActive = false

    /** Set by a tap on ✕; cleared the next time the keyboard closes. */
    private var dismissed = false
    private var imeWasVisible = false

    val isSnoozed: Boolean
        get() = SystemClock.elapsedRealtime() < snoozedUntilElapsed

    val isDismissed: Boolean
        get() = dismissed

    /**
     * A ✕ dismissal means "not for this typing session", so it lasts exactly
     * until the keyboard goes away. Closing and reopening the keyboard brings
     * the bubble back — matching what reopening it looks like to the user.
     */
    fun onImeVisibility(visible: Boolean) {
        if (imeWasVisible && !visible) dismissed = false
        imeWasVisible = visible
    }

    private val layoutParams = WindowManager.LayoutParams(
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
        // No FLAG_LAYOUT_NO_LIMITS: the bubble grows when its status text appears,
        // and being allowed past the screen edge is what clipped it there.
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH,
        PixelFormat.TRANSLUCENT,
    ).apply {
        // Anchored by its right edge: the bubble grows and shrinks with its
        // status text, and an END anchor makes that growth extend leftward and
        // collapse back to the same spot instead of walking across the screen.
        gravity = Gravity.TOP or Gravity.END
        x = 0
        y = 0
    }

    fun attach(scope: CoroutineScope) {
        dictation.state
            .onEach(::render)
            .launchIn(scope)
    }

    fun detach() {
        hide()
    }

    // An overlay has no parent view; its layout parameters come from the
    // WindowManager below, so a null root is the only option here.
    @SuppressLint("InflateParams")
    fun show() {
        if (root != null) return
        if (isSnoozed || dismissed) return
        if (!Settings.canDrawOverlays(context)) return

        val view = LayoutInflater.from(context).inflate(R.layout.view_bubble, null, false)
        status = view.findViewById(R.id.bubble_status)
        mic = view.findViewById(R.id.bubble_mic)
        finish = view.findViewById(R.id.bubble_finish)
        cancel = view.findViewById(R.id.bubble_cancel)

        if (layoutParams.y == 0) {
            // First show: flush against the right edge, halfway down. With END
            // gravity, x is the distance in from the right edge.
            layoutParams.y = windowManager.currentWindowMetrics.bounds.height() / 2
        }

        mic?.setOnTouchListener(MicTouchListener())
        finish?.setOnClickListener { DictationService.send(context, DictationService.ACTION_FINISH) }
        cancel?.setOnClickListener { onCancelTapped() }
        cancel?.setOnLongClickListener {
            snooze()
            true
        }

        runCatching { windowManager.addView(view, layoutParams) }
            .onSuccess { root = view }
        render(dictation.state.value)
    }

    fun hide() {
        val view = root ?: return
        // Never pull the bubble out from under a dictation in progress.
        if (dictation.state.value.phase.isBusy) return
        runCatching { windowManager.removeView(view) }
        root = null
        status = null
        mic = null
        finish = null
        cancel = null
    }

    /** Long-press only: gets out of the way without turning the feature off. */
    private fun snooze() {
        snoozedUntilElapsed = SystemClock.elapsedRealtime() + SNOOZE_MILLIS
        if (dictation.state.value.phase.isBusy) {
            DictationService.send(context, DictationService.ACTION_CANCEL)
        }
        dictation.clearTransient()
        forceHide()
    }

    private fun forceHide() {
        val view = root ?: return
        runCatching { windowManager.removeView(view) }
        root = null
        status = null
        mic = null
        finish = null
        cancel = null
    }

    private fun onCancelTapped() {
        val phase = dictation.state.value.phase
        when {
            // Mid-dictation, ✕ cancels the dictation; the bubble stays.
            phase.isBusy -> DictationService.send(context, DictationService.ACTION_CANCEL)
            // A failure or leftover result: first tap clears it back to idle.
            phase != DictationPhase.IDLE -> dictation.clearTransient()
            // Idle: dismiss for this typing session only, not for 15 minutes.
            else -> {
                dismissed = true
                forceHide()
            }
        }
    }

    private fun render(state: DictationState) {
        val view = root ?: return
        status?.text = when {
            state.approachingLimit && state.phase == DictationPhase.LISTENING ->
                "Listening — one minute left"

            state.phase == DictationPhase.LISTENING && state.partialTranscript.isNotEmpty() ->
                state.partialTranscript.takeLast(PARTIAL_PREVIEW_CHARACTERS)

            else -> state.statusText
        }
        status?.visibility = if (state.phase == DictationPhase.IDLE) View.GONE else View.VISIBLE
        finish?.visibility = if (state.phase.holdsMicrophone) View.VISIBLE else View.GONE
        mic?.isSelected = state.phase.holdsMicrophone
        mic?.setImageResource(
            when (state.phase) {
                DictationPhase.FAILED -> R.drawable.ic_retry
                DictationPhase.PERMISSION_REPAIR -> R.drawable.ic_warning
                else -> R.drawable.ic_dictation
            }
        )
        view.contentDescription = state.statusText
        // Showing or hiding the status text changes the bubble's width, so its
        // position has to be re-checked against the screen every time.
        clampToScreen()
    }

    /** Keeps the whole bubble on screen after a resize or a drag. */
    private fun clampToScreen() {
        val view = root ?: return
        view.post {
            val current = root ?: return@post
            val width = current.width
            val height = current.height
            if (width <= 0 || height <= 0) return@post

            val bounds = windowManager.currentWindowMetrics.bounds
            val x = layoutParams.x.coerceIn(0, (bounds.width() - width).coerceAtLeast(0))
            val y = layoutParams.y.coerceIn(0, (bounds.height() - height).coerceAtLeast(0))
            if (x == layoutParams.x && y == layoutParams.y) return@post

            layoutParams.x = x
            layoutParams.y = y
            runCatching { windowManager.updateViewLayout(current, layoutParams) }
        }
    }

    private fun toggle() {
        val phase = dictation.state.value.phase
        when {
            phase.holdsMicrophone -> DictationService.send(context, DictationService.ACTION_FINISH)
            phase == DictationPhase.FAILED -> {
                dictation.state.value.sessionId?.let { dictation.retry(it.toString()) }
            }

            phase == DictationPhase.PERMISSION_REPAIR -> openCompanionApp()
            phase.isBusy -> Unit
            else -> {
                dictation.clearTransient()
                DictationService.start(context, DictationSource.BUBBLE)
            }
        }
    }

    private fun openCompanionApp() {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        launch.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(launch)
    }

    /**
     * Tap to start and tap to finish, hold for push-to-talk, drag to move. All
     * three share one listener because they are the same gesture until the user
     * commits to one.
     */
    private inner class MicTouchListener : View.OnTouchListener {
        private var downX = 0f
        private var downY = 0f
        private var originX = 0
        private var originY = 0
        private var downAt = 0L
        private var dragging = false

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouch(view: View, event: MotionEvent): Boolean {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    originX = layoutParams.x
                    originY = layoutParams.y
                    downAt = SystemClock.elapsedRealtime()
                    dragging = false
                    pushToTalkActive = false
                    return true
                }

                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downX
                    val dy = event.rawY - downY
                    if (!dragging && (abs(dx) > touchSlop || abs(dy) > touchSlop)) dragging = true
                    if (dragging) {
                        // END gravity: x measures in from the right edge, so a
                        // rightward finger movement shrinks it.
                        layoutParams.x = originX - dx.toInt()
                        layoutParams.y = originY + dy.toInt()
                        root?.let { runCatching { windowManager.updateViewLayout(it, layoutParams) } }
                        return true
                    }
                    // Held in place past the long-press timeout: start push-to-talk.
                    val held = SystemClock.elapsedRealtime() - downAt
                    if (!pushToTalkActive && held >= longPressTimeout &&
                        !dictation.state.value.phase.isBusy
                    ) {
                        pushToTalkActive = true
                        dictation.clearTransient()
                        DictationService.start(context, DictationSource.BUBBLE)
                    }
                    return true
                }

                MotionEvent.ACTION_UP -> {
                    when {
                        dragging -> clampToScreen()
                        pushToTalkActive -> DictationService.send(context, DictationService.ACTION_FINISH)
                        else -> {
                            view.performClick()
                            toggle()
                        }
                    }
                    pushToTalkActive = false
                    return true
                }

                MotionEvent.ACTION_CANCEL -> {
                    if (pushToTalkActive) DictationService.send(context, DictationService.ACTION_CANCEL)
                    pushToTalkActive = false
                    return true
                }
            }
            return false
        }
    }

    private companion object {
        const val SNOOZE_MILLIS = 15 * 60 * 1000L
        const val PARTIAL_PREVIEW_CHARACTERS = 48
    }
}
