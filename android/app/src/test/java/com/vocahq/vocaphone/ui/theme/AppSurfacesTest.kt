package com.vocahq.vocaphone.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The companion app's warm surfaces, and the keyboard palette they must not touch. */
class AppSurfacesTest {

    private fun contrast(a: Color, b: Color): Double {
        val (light, dark) = listOf(a.luminance(), b.luminance()).sortedDescending()
        return (light + 0.05) / (dark + 0.05)
    }

    private val light = VocaPhoneLightColors.withAppSurfaces(dark = false)
    private val dark = VocaPhoneDarkColors.withAppSurfaces(dark = true)

    @Test
    fun `the light page is the iOS canvas and groups sit one step lighter`() {
        assertEquals(Color(0xFFF4F1E8), light.background)
        assertEquals(Color(0xFFFFFDF7), light.surfaceContainerLow)
        assertTrue(light.surfaceContainerLow.luminance() > light.surface.luminance())
    }

    @Test
    fun `dark groups are lifted off the page`() {
        assertTrue(dark.surfaceContainerLow.luminance() > dark.surface.luminance())
    }

    @Test
    fun `text on the page and in groups stays readable`() {
        for (scheme in listOf(light, dark)) {
            for (background in listOf(scheme.surface, scheme.surfaceContainerLow)) {
                assertTrue(contrast(scheme.onSurface, background) >= 7.0)
                assertTrue(contrast(scheme.onSurfaceVariant, background) >= 4.5)
                assertTrue(contrast(scheme.primary, background) >= 4.5)
            }
        }
    }

    @Test
    fun `the keyboard keeps its own palette`() {
        assertEquals(Color(0xFFFFFFFF), VocaPhoneLightColors.surface)
        assertEquals(Color(0xFF1B1C1B), VocaPhoneDarkColors.surface)
    }
}
