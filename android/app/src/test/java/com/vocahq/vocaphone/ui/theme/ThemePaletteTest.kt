package com.vocahq.vocaphone.ui.theme

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Test

class ThemePaletteTest {

    @Test
    fun brandDarkPrimaryStaysVocaTeal() {
        assertEquals(Color(0xFF77D0B2), VocaPhoneDarkColors.primary)
    }
}
