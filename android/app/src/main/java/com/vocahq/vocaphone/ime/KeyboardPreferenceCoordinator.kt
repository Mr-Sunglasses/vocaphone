package com.vocahq.vocaphone.ime

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Serializes preference writes so dictation cannot start with a stale selection. */
internal class KeyboardPreferenceCoordinator(
    private val scope: CoroutineScope,
    private val onError: () -> Unit,
) {
    private val mutablePending = MutableStateFlow(false)
    val pending: StateFlow<Boolean> = mutablePending.asStateFlow()
    val isPending: Boolean get() = mutablePending.value

    fun submit(write: suspend () -> Unit): Boolean {
        if (mutablePending.value) return false
        mutablePending.value = true
        scope.launch {
            try {
                write()
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                onError()
            } finally {
                mutablePending.value = false
            }
        }
        return true
    }
}
