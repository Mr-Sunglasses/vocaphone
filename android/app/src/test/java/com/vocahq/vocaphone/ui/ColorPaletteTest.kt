package com.vocahq.vocaphone.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import com.vocahq.vocaphone.ui.theme.VocaPhoneDarkColors
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Ties res/values/colors.xml to the Compose theme.
 *
 * The floating bubble is drawn from XML by a WindowManager overlay, so it cannot
 * read the Compose `ColorScheme` at all. That gap is why it spent its life in
 * Material's baseline purple while the rest of the app was brand green: nothing
 * connected the two, and nothing complained. Mirroring the values into `res/` is
 * only half a fix — this is the half that keeps them mirrored.
 */
class ColorPaletteTest {

    private val colors: Map<String, String> by lazy {
        // Gradle runs unit tests with the module directory as the working dir.
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

    /**
     * The chip is the dark surface at 95%. XML cannot re-alpha another colour, so
     * the RGB is written twice and only a test can hold the two together.
     */
    @Test
    fun theBubbleChipIsTheDarkSurfaceAtNinetyFivePercent() {
        val chip = resource("bubble_chip")
        assertEquals("bubble_chip is not 95% opaque", "F2", chip.take(2))
        assertEquals(
            "bubble_chip is no longer the Compose dark surface",
            VocaPhoneDarkColors.surface.hex().drop(2),
            chip.drop(2),
        )
    }

    /**
     * The bubble floats over other apps, so every colour it draws has to carry
     * against its own chip and every glyph against its own fill. A white glyph on
     * the mint idle fill — which is what the layout used to hardcode — is 1.8:1.
     *
     * Both the chip and the dismiss glyph are translucent, so the numbers are
     * measured on the *composited* colours rather than the literals, and the chip
     * is composited over white: it is 95% opaque, so a white app behind it is the
     * worst case for everything light drawn on top.
     */
    @Test
    fun everyBubbleColourCarriesOverTheBrightestAppBehindIt() {
        val chip = over(resource("bubble_chip"), background = "FFFFFF")
        val dismiss = over(resource("bubble_secondary_icon"), background = chip)
        val micFill = resource("brand_dark").drop(2)
        val recordingFill = resource("bubble_recording").drop(2)

        val pairs = listOf(
            Triple("mic fill on the chip", resource("brand_dark") to chip, 3.0),
            Triple("recording fill on the chip", resource("bubble_recording") to chip, 3.0),
            Triple("status text on the chip", resource("on_surface_dark") to chip, 4.5),
            Triple("dismiss glyph on the chip", dismiss to chip, 3.0),
            Triple("idle glyph on the mic fill", resource("on_brand_dark") to micFill, 3.0),
            Triple(
                "recording glyph on the recording fill",
                resource("bubble_recording_icon") to recordingFill,
                3.0,
            ),
        )
        for ((what, colours, minimum) in pairs) {
            val (foreground, background) = colours
            val measured = contrast(foreground, background)
            assertTrue(
                "$what is %.2f:1, below %.1f:1".format(measured, minimum),
                measured >= minimum,
            )
        }
    }

    /** Flattens an #AARRGGBB resource onto an opaque RRGGBB background. */
    private fun over(argb: String, background: String): String {
        val alpha = argb.take(2).toInt(16) / 255.0
        return (0..2).joinToString("") { index ->
            val channel = { hex: String -> hex.takeLast(6).substring(index * 2, index * 2 + 2).toInt(16) }
            "%02X".format(Math.round(alpha * channel(argb) + (1 - alpha) * channel(background)))
        }
    }

    private fun contrast(a: String, b: String): Double {
        val first = luminance(a)
        val second = luminance(b)
        return (maxOf(first, second) + 0.05) / (minOf(first, second) + 0.05)
    }

    private fun luminance(hex: String): Double {
        val rgb = hex.takeLast(6)
        val channels = (0..2).map { index ->
            val value = rgb.substring(index * 2, index * 2 + 2).toInt(16) / 255.0
            if (value <= 0.03928) value / 12.92 else Math.pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}
