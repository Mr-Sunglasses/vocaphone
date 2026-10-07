package com.vocahq.vocaphone.ime

import android.content.res.Configuration
import android.graphics.Color
import android.inputmethodservice.InputMethodService
import android.provider.Settings
import android.view.View
import android.view.inputmethod.EditorInfo
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.core.graphics.drawable.toDrawable
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.lifecycle.setViewTreeViewModelStoreOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner

/** Supplies the owners Compose normally receives from an Activity. */
abstract class LifecycleInputMethodService : InputMethodService(),
    LifecycleOwner,
    ViewModelStoreOwner,
    SavedStateRegistryOwner {

    private val lifecycleRegistry = LifecycleRegistry(this)
    private val store = ViewModelStore()
    private val savedStateController = SavedStateRegistryController.create(this)
    private var inputComposeView: ComposeView? = null
    private var appliedSurfaceColor: Int? = null
    private val surfaceColorSink: (Int) -> Unit = ::applySurfaceColor

    final override val lifecycle: Lifecycle get() = lifecycleRegistry
    final override val viewModelStore: ViewModelStore get() = store
    final override val savedStateRegistry: SavedStateRegistry
        get() = savedStateController.savedStateRegistry

    override fun onCreate() {
        super.onCreate()
        savedStateController.performRestore(null)
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE)
    }

    final override fun onCreateInputView(): View {
        if (lifecycleRegistry.currentState == Lifecycle.State.CREATED) {
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_START)
        }

        val surfaceColor = keyboardSurfaceColor()
        val composeView = ComposeView(this).apply {
            setViewTreeLifecycleOwner(this@LifecycleInputMethodService)
            setViewTreeViewModelStoreOwner(this@LifecycleInputMethodService)
            setViewTreeSavedStateRegistryOwner(this@LifecycleInputMethodService)
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnDetachedFromWindow)
            // Match keyboard chrome so nav-bar padding is not a transparent hole.
            setBackgroundColor(surfaceColor)
            // Pad before the first measure so the IME window height includes it.
            setPadding(0, 0, 0, navigationBarBottomInsetPx(this))
            setContent {
                CompositionLocalProvider(LocalKeyboardSurfaceSink provides surfaceColorSink) {
                    KeyboardFontScale { KeyboardContent() }
                }
            }
            ViewCompat.setOnApplyWindowInsetsListener(this) { view, insets ->
                val bottom = navigationBarBottomInsetPx(view, insets)
                if (view.paddingBottom != bottom) {
                    view.setPadding(0, 0, 0, bottom)
                }
                insets
            }
        }
        inputComposeView = composeView
        appliedSurfaceColor = surfaceColor

        window?.window?.let { imeWindow ->
            // Edge-to-edge so navigation-bar insets are dispatched to the input view.
            WindowCompat.setDecorFitsSystemWindows(imeWindow, false)
            imeWindow.setBackgroundDrawable(surfaceColor.toDrawable())
            imeWindow.decorView.apply {
                setViewTreeLifecycleOwner(this@LifecycleInputMethodService)
                setViewTreeViewModelStoreOwner(this@LifecycleInputMethodService)
                setViewTreeSavedStateRegistryOwner(this@LifecycleInputMethodService)
            }
        }
        return composeView
    }

    @Composable
    protected abstract fun KeyboardContent()

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        inputComposeView?.requestLayout()
        window?.window?.decorView?.requestLayout()
    }

    /**
     * Never the extract-text fullscreen mode. The framework turns it on in
     * landscape for any editor without IME_FLAG_NO_FULLSCREEN and draws its own
     * extract editor above the input view; this keyboard has no extract view of
     * its own and edits through the app's field, so that mode only hid the app
     * behind a bare system text box.
     */
    override fun onEvaluateFullscreenMode(): Boolean = false

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        if (lifecycleRegistry.currentState == Lifecycle.State.STARTED) {
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)
        }
        // Insets are often only available once the IME window is showing.
        inputComposeView?.let { view ->
            val bottom = navigationBarBottomInsetPx(view)
            if (view.paddingBottom != bottom) {
                view.setPadding(0, 0, 0, bottom)
                // First layout may have used a 0 inset; force the soft-input
                // window to remeasure now that padding is known.
                view.requestLayout()
                window?.window?.decorView?.requestLayout()
            }
            ViewCompat.requestApplyInsets(view)
        }
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        if (lifecycleRegistry.currentState == Lifecycle.State.RESUMED) {
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
        }
        super.onFinishInputView(finishingInput)
    }

    override fun onDestroy() {
        when (lifecycleRegistry.currentState) {
            Lifecycle.State.RESUMED -> lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
            else -> Unit
        }
        if (lifecycleRegistry.currentState == Lifecycle.State.STARTED) {
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
        }
        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_DESTROY)
        inputComposeView = null
        store.clear()
        super.onDestroy()
    }

    /**
     * The colour behind the navigation-bar padding before the keyboard has
     * composed. From the first composition on, [ReportKeyboardSurface] replaces
     * it with the scheme the keys are actually drawn in, which is the
     * wallpaper's when dynamic colour is on.
     */
    private fun keyboardSurfaceColor(): Int {
        val night = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES
        // Keep in sync with Theme.kt surfaceContainerLowest.
        return if (night) Color.rgb(0x10, 0x12, 0x10) else Color.WHITE
    }

    private fun applySurfaceColor(argb: Int) {
        if (argb == appliedSurfaceColor) return
        appliedSurfaceColor = argb
        inputComposeView?.setBackgroundColor(argb)
        window?.window?.setBackgroundDrawable(argb.toDrawable())
    }

    private fun navigationBarBottomInsetPx(
        view: View,
        insets: WindowInsetsCompat? = ViewCompat.getRootWindowInsets(view),
    ): Int {
        if (insets != null) {
            val navigation = insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom
            val gestures = insets.getInsets(WindowInsetsCompat.Type.systemGestures()).bottom
            val tappable = insets.getInsets(WindowInsetsCompat.Type.tappableElement()).bottom
            val resolved = maxOf(navigation, gestures, tappable)
            if (resolved > 0) return resolved
        }

        // IME windows often report 0 insets even when gesture nav draws over the
        // bottom row. Fall back to the framework nav-bar height for gesture mode.
        val navigationMode = Settings.Secure.getInt(contentResolver, "navigation_mode", 0)
        if (navigationMode != GESTURE_NAVIGATION_MODE) return 0

        val resId = resources.getIdentifier("navigation_bar_height", "dimen", "android")
        val fromRes = if (resId > 0) resources.getDimensionPixelSize(resId) else 0
        val fallback = (GESTURE_NAV_FALLBACK_DP * resources.displayMetrics.density).toInt()
        return maxOf(fromRes, fallback)
    }

    private companion object {
        const val GESTURE_NAVIGATION_MODE = 2
        const val GESTURE_NAV_FALLBACK_DP = 48
    }
}

/**
 * Where the keyboard reports the surface colour it is drawn on, so the strip
 * the service pads under it for the navigation bar matches. That strip is a
 * View background outside the composition and cannot read the theme itself.
 */
internal val LocalKeyboardSurfaceSink = staticCompositionLocalOf<(Int) -> Unit> { {} }

/** Call inside the keyboard's theme with the colour its root surface uses. */
@Composable
internal fun ReportKeyboardSurface(color: androidx.compose.ui.graphics.Color) {
    val sink = LocalKeyboardSurfaceSink.current
    val argb = color.toArgb()
    SideEffect { sink(argb) }
}

/**
 * Largest font scale the keyboard follows. Keys, the strip and the menu are
 * sized in dp and cannot grow with the text, so at the 1.5x and 2x system
 * settings `?123` cut down to `?`, number hints ran into their digits, and
 * menu labels ellipsized. System keyboards do the same thing: they follow a
 * larger font a little way, then stop.
 */
internal const val MAX_KEYBOARD_FONT_SCALE = 1.3f

@Composable
internal fun KeyboardFontScale(content: @Composable () -> Unit) {
    val density = LocalDensity.current
    val capped = density.fontScale.coerceAtMost(MAX_KEYBOARD_FONT_SCALE)
    // Always provided, so a font-scale change does not swap the tree and drop
    // the keyboard's remembered state.
    CompositionLocalProvider(
        LocalDensity provides Density(density.density, capped),
        content = content,
    )
}
