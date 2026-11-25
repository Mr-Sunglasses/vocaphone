package com.vocahq.vocaphone.ime

import android.content.Context
import android.content.res.Configuration
import android.util.Size
import android.widget.inline.InlinePresentationSpec
import android.view.inputmethod.InlineSuggestionsRequest
import androidx.autofill.inline.UiVersions
import androidx.autofill.inline.common.TextViewStyle
import androidx.autofill.inline.v1.InlineSuggestionUi

/**
 * Inline autofill (Android 11+): what the keyboard asks password managers and
 * the SMS one-time-code filler for, so their suggestions arrive as chips in
 * the suggestion strip instead of a dropdown over the app. The chips are the
 * autofill service's own views, on the library's default chip; the keyboard
 * sizes them and sets the text colour for the theme. (The chip background and
 * padding setters are restricted to the library in androidx.autofill 1.1.0.)
 */
internal object InlineAutofill {
    const val MAX_SUGGESTIONS = 3

    fun request(context: Context): InlineSuggestionsRequest {
        val density = context.resources.displayMetrics.density
        fun px(dp: Int): Int = (dp * density).toInt()
        val night = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES
        val text = TextViewStyle.Builder()
            .setTextColor(if (night) 0xFFDEE4E5.toInt() else 0xFF161D1E.toInt())
            .setTextSize(14f)
            .build()
        val style = InlineSuggestionUi.newStyleBuilder()
            .setTitleStyle(text)
            .setSubtitleStyle(text)
            .build()
        val styles = UiVersions.newStylesBuilder().addStyle(style).build()
        val spec = InlinePresentationSpec.Builder(Size(px(48), px(32)), Size(px(240), px(40)))
            .setStyle(styles)
            .build()
        return InlineSuggestionsRequest.Builder(listOf(spec))
            .setMaxSuggestionCount(MAX_SUGGESTIONS)
            .build()
    }
}
