package com.vocahq.vocaphone.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.vocahq.vocaphone.ui.theme.VocaPhoneTheme

/**
 * Writing check as its own screen, reachable from anywhere text is:
 *
 * - **Selected text in any app** ("Writing check" in the selection menu,
 *   `ACTION_PROCESS_TEXT`). When the field is editable, "Replace" hands the
 *   corrected text back and the app puts it in place, Grammarly's "accept"
 *   for apps the keyboard is not typing into.
 * - **Share** (`ACTION_SEND` with text): check, then copy or share it on.
 * - The keyboard's "Open in app", Settings, and a History transcript.
 *
 * Everything is checked in this process; nothing is sent anywhere.
 */
class WritingCheckActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val processing = intent.action == Intent.ACTION_PROCESS_TEXT
        val readOnly = intent.getBooleanExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, false)
        val text = when (intent.action) {
            Intent.ACTION_PROCESS_TEXT -> intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
            Intent.ACTION_SEND -> intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            else -> intent.getStringExtra(EXTRA_TEXT)
        }.orEmpty()
        setContent {
            VocaPhoneTheme(appSurfaces = true) {
                WritingCheckScreen(
                    initialText = text,
                    onReplace = if (processing && !readOnly) {
                        { corrected ->
                            setResult(RESULT_OK, Intent().putExtra(Intent.EXTRA_PROCESS_TEXT, corrected))
                            finish()
                        }
                    } else {
                        null
                    },
                    onClose = ::finish,
                )
            }
        }
    }

    companion object {
        /** The text to open on, from the keyboard, Settings or History. */
        const val EXTRA_TEXT = "com.vocahq.vocaphone.WRITING_TEXT"

        fun open(context: Context, text: String = "") {
            context.startActivity(
                Intent(context, WritingCheckActivity::class.java)
                    .putExtra(EXTRA_TEXT, text)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }
}
