package com.vocahq.vocaphone.ime

import android.graphics.Color
import android.inputmethodservice.InputMethodService
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.core.graphics.drawable.toDrawable
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

        val composeView = ComposeView(this).apply {
            setViewTreeLifecycleOwner(this@LifecycleInputMethodService)
            setViewTreeViewModelStoreOwner(this@LifecycleInputMethodService)
            setViewTreeSavedStateRegistryOwner(this@LifecycleInputMethodService)
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnDetachedFromWindow)
            setContent { KeyboardContent() }
        }
        window?.window?.decorView?.apply {
            setViewTreeLifecycleOwner(this@LifecycleInputMethodService)
            setViewTreeViewModelStoreOwner(this@LifecycleInputMethodService)
            setViewTreeSavedStateRegistryOwner(this@LifecycleInputMethodService)
        }
        window?.window?.setBackgroundDrawable(Color.TRANSPARENT.toDrawable())
        return composeView
    }

    @Composable
    protected abstract fun KeyboardContent()

    override fun onStartInputView(info: android.view.inputmethod.EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        if (lifecycleRegistry.currentState == Lifecycle.State.STARTED) {
            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)
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
        store.clear()
        super.onDestroy()
    }
}
