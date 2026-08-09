package com.vocahq.vocaphone.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import com.vocahq.vocaphone.ui.theme.VocaPhoneDarkColors
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Keeps the non-Compose keyboard palette aligned with the Compose dark scheme. */
class ColorPaletteTest {

    private val colors: Map<String, String> by lazy {
        val file = File("src/main/res/values/colors.xml")
        assertTrue("cannot find ${file.absolutePath}", file.isFile)
        Regex("""<color name="([^"]+)">#([0-9A-Fa-f]{8})</color>""")
            .findAll(file.readText())
            .associate { it.groupValues[1] to it.groupValues[2].uppercase() }
    }

    private fun resource(name: String): String =
        colors[name] ?: error("res/values/colors.xml has no colour named '$name'")

    private fun Color.hex(): String = "%08X".format(toArgb())

    @Test
    fun theResourcePaletteMatchesTheComposeDarkScheme() {
        val expected = mapOf(
            "on_surface_dark" to VocaPhoneDarkColors.onSurface,
            "brand_dark" to VocaPhoneDarkColors.primary,
            "on_brand_dark" to VocaPhoneDarkColors.onPrimary,
        )
        for ((name, composeColor) in expected) {
            assertEquals(
                "res/values/colors.xml '$name' has drifted from Theme.kt",
                composeColor.hex(),
                resource(name),
            )
        }
    }
}
