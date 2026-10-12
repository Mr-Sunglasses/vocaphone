package com.vocahq.vocaphone.core

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Expected values are OpenCC 1.4.2's own output (`s2twp`, `s2hkp`), and
 * `TraditionalChineseTests.swift` checks the same pairs, so a drift in either
 * port shows up as a disagreement with OpenCC rather than with the other app.
 */
class TraditionalChineseTest {
    private val cases = listOf(
        Triple("我们用软件打印鼠标的信息。", "我們用軟體列印滑鼠的資訊。", "我們用軟件打印滑鼠的信息。"),
        Triple("头发发现了里面的问题", "頭髮發現了裡面的問題", "頭髮發現了裏面的問題"),
        Triple("这个程序的内存不够，请重新启动。", "這個程式的記憶體不夠，請重新啟動。", "這個程序的內存不夠，請重新啓動。"),
        Triple("明天下午三点开会，记得带笔记本电脑。", "明天下午三點開會，記得帶筆記型電腦。", "明天下午三點開會，記得帶筆記本電腦。"),
        Triple("𠮷野家的面条", "𠮷野家的麵條", "𠮷野家的麪條"),
    )

    @Test
    fun `matches OpenCC for Taiwan`() {
        for ((simplified, taiwan, _) in cases) {
            assertEquals(taiwan, TraditionalChinese.apply(simplified, ChineseScript.TAIWAN, "zh"))
        }
    }

    @Test
    fun `matches OpenCC for Hong Kong`() {
        for ((simplified, _, hongKong) in cases) {
            assertEquals(hongKong, TraditionalChinese.apply(simplified, ChineseScript.HONG_KONG, "zh"))
        }
    }

    /**
     * 软件 is in no phrase table, so it only becomes 軟體 because the
     * characters between phrase matches reach the Taiwan table as one run.
     */
    @Test
    fun `unmatched run reaches the regional table whole`() {
        assertEquals("軟體", TraditionalChinese.apply("软件", ChineseScript.TAIWAN, "zh"))
    }

    @Test
    fun `unchanged leaves text alone`() {
        assertEquals("软件", TraditionalChinese.apply("软件", ChineseScript.UNCHANGED, "zh"))
    }

    @Test
    fun `already traditional text stays traditional`() {
        assertEquals("頭髮發現了問題", TraditionalChinese.apply("頭髮發現了問題", ChineseScript.TAIWAN, "zh"))
    }

    @Test
    fun `automatic converts Chinese but not Japanese`() {
        assertEquals("這是軟體", TraditionalChinese.apply("这是软件", ChineseScript.TAIWAN, "auto"))
        assertEquals("会社に行きます", TraditionalChinese.apply("会社に行きます", ChineseScript.TAIWAN, "auto"))
    }

    @Test
    fun `pinned non-Chinese language is never converted`() {
        assertEquals("会社", TraditionalChinese.apply("会社", ChineseScript.TAIWAN, "ja"))
        assertEquals("软件", TraditionalChinese.apply("软件", ChineseScript.TAIWAN, "en"))
    }

    @Test
    fun `Cantonese and regional codes convert`() {
        assertEquals("軟件", TraditionalChinese.apply("软件", ChineseScript.HONG_KONG, "yue"))
        assertEquals("軟體", TraditionalChinese.apply("软件", ChineseScript.TAIWAN, "zh-CN"))
    }

    @Test
    fun `latin text is untouched`() {
        assertEquals("Meet at 3pm.", TraditionalChinese.apply("Meet at 3pm.", ChineseScript.TAIWAN, "auto"))
    }

    @Test
    fun `stored values round trip and default to unchanged`() {
        for (script in ChineseScript.entries) {
            assertEquals(script, ChineseScript.fromStored(script.storedValue))
        }
        assertEquals(ChineseScript.UNCHANGED, ChineseScript.fromStored(null))
        assertEquals(ChineseScript.UNCHANGED, ChineseScript.fromStored("zh-Hant"))
    }

    /** A Chinese path names one page; its Traditional spelling names another. */
    @Test
    fun `web addresses are left alone`() {
        assertEquals(
            "開啟 https://example.com/软件 看看軟體",
            TraditionalChinese.apply("打开 https://example.com/软件 看看软件", ChineseScript.TAIWAN, "zh"),
        )
    }

    /**
     * A model that reports `zh` for a mixed sentence has not made its Japanese
     * Chinese: the kana guard holds whatever the language says.
     */
    @Test
    fun `kana blocks conversion even when reported as Chinese`() {
        assertEquals("软件は会社です", TraditionalChinese.apply("软件は会社です", ChineseScript.TAIWAN, "zh"))
    }

    /**
     * The trigger is Traditional and the spoken text Simplified, so the snippet
     * only fires if conversion runs first; and the expansion is Simplified, so
     * it stays that way only if conversion does not run after.
     */
    @Test
    fun `conversion runs before snippets and not after`() {
        assertEquals(
            "简体软件",
            DictatedTranscript.finished(
                "软件",
                style = WritingStyle.RAW,
                language = "zh",
                repairSpeech = false,
                chineseScript = ChineseScript.TAIWAN,
                snippets = listOf(Snippet(id = "1", trigger = "軟體", expansion = "简体软件")),
            ),
        )
    }

    /** Applies to RAW too: it is a writing system, not an edit. */
    @Test
    fun `funnel converts raw`() {
        assertEquals(
            "我們用軟體",
            DictatedTranscript.finished(
                "我们用软件",
                style = WritingStyle.RAW,
                language = "zh",
                repairSpeech = false,
                chineseScript = ChineseScript.TAIWAN,
            ),
        )
    }
}
