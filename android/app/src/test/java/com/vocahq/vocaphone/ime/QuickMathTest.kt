package com.vocahq.vocaphone.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QuickMathTest {

    @Test
    fun `a sum ending in equals is answered`() {
        assertEquals("48", QuickMath.resultFor("12*4="))
        assertEquals("48", QuickMath.resultFor("that is 12 x 4="))
        assertEquals("48", QuickMath.resultFor("12×4="))
        assertEquals("400", QuickMath.resultFor("1,200/3="))
        assertEquals("2,400", QuickMath.resultFor("1,200*2="))
        assertEquals("2.5", QuickMath.resultFor("10/4="))
        assertEquals("2.5", QuickMath.resultFor("10÷4="))
        assertEquals("-3", QuickMath.resultFor("7-10="))
        assertEquals("20", QuickMath.resultFor("(2+3)x4="))
        assertEquals("14", QuickMath.resultFor("2+3*4="))
        assertEquals("7", QuickMath.resultFor("3.5*2="))
        assertEquals("0.3333333333", QuickMath.resultFor("1/3="))
        assertEquals("6", QuickMath.resultFor("box 2x3="))
        assertEquals("-2", QuickMath.resultFor("-5+3="))
    }

    @Test
    fun `anything that is not a plain sum is left alone`() {
        assertNull(QuickMath.resultFor("12*4"))
        assertNull(QuickMath.resultFor("12="))
        assertNull(QuickMath.resultFor("(5)="))
        assertNull(QuickMath.resultFor("x="))
        assertNull(QuickMath.resultFor("5/0="))
        assertNull(QuickMath.resultFor("max(3,4)="))
        assertNull(QuickMath.resultFor("v1.2+3="))
        assertNull(QuickMath.resultFor("1,2+3="))
        assertNull(QuickMath.resultFor("1,20,000+1="))
        assertNull(QuickMath.resultFor("1.2.3+1="))
        assertNull(QuickMath.resultFor("2(3+4)="))
        assertNull(QuickMath.resultFor("$5+3="))
        assertNull(QuickMath.resultFor("5km+3="))
        assertNull(QuickMath.resultFor(""))
    }

    @Test
    fun `the result chip appears only between words`() {
        assertEquals(
            listOf(SuggestionItem("48", kind = SuggestionKind.RESULT)),
            TypingChips.extras("so 12*4=", "", emptyList()),
        )
        assertEquals(emptyList<SuggestionItem>(), TypingChips.extras("so 12*4=", "x", emptyList()))
    }
}
