package com.vocahq.vocaphone.ime

import android.view.inputmethod.InputConnection
import java.lang.reflect.Proxy

/** A plain-text editor that can refuse a selection or a commit. */
internal class FakeWritingEditor(var text: String, var cursor: Int) {
    var refuseSelection: Pair<Int, Int>? = null
    var refuseCommit = false
    val calls = mutableListOf<String>()
    private var selection = cursor to cursor
    val connection = Proxy.newProxyInstance(
        InputConnection::class.java.classLoader,
        arrayOf(InputConnection::class.java),
    ) { _, method, args ->
        calls += method.name
        when (method.name) {
            "setSelection" -> {
                val range = args!![0] as Int to args[1] as Int
                if (range == refuseSelection) {
                    false
                } else {
                    selection = range
                    if (range.first == range.second) cursor = range.first
                    true
                }
            }
            "commitText" -> {
                if (refuseCommit) {
                    false
                } else {
                    val inserted = args!![0].toString()
                    text = text.substring(0, selection.first) + inserted + text.substring(selection.second)
                    selection = (selection.first + inserted.length).let { it to it }
                    true
                }
            }
            "beginBatchEdit", "endBatchEdit", "finishComposingText" -> true
            else -> error("Unexpected editor call: ${method.name}")
        }
    } as InputConnection
}
