import Testing

/// Expected values are OpenCC 1.4.2's own output (`s2twp`, `s2hkp`), and
/// `TraditionalChineseTest.kt` checks the same pairs, so a drift in either
/// port shows up as a disagreement with OpenCC rather than with the other app.
struct TraditionalChineseTests {
    private static let cases: [(simplified: String, taiwan: String, hongKong: String)] = [
        ("我们用软件打印鼠标的信息。", "我們用軟體列印滑鼠的資訊。", "我們用軟件打印滑鼠的信息。"),
        ("头发发现了里面的问题", "頭髮發現了裡面的問題", "頭髮發現了裏面的問題"),
        ("这个程序的内存不够，请重新启动。", "這個程式的記憶體不夠，請重新啟動。", "這個程序的內存不夠，請重新啓動。"),
        ("明天下午三点开会，记得带笔记本电脑。", "明天下午三點開會，記得帶筆記型電腦。", "明天下午三點開會，記得帶筆記本電腦。"),
        ("𠮷野家的面条", "𠮷野家的麵條", "𠮷野家的麪條"),
    ]

    @Test func matchesOpenCCForTaiwan() {
        for item in Self.cases {
            #expect(TraditionalChinese.apply(item.simplified, script: .taiwan, language: "zh") == item.taiwan)
        }
    }

    @Test func matchesOpenCCForHongKong() {
        for item in Self.cases {
            #expect(TraditionalChinese.apply(item.simplified, script: .hongKong, language: "zh") == item.hongKong)
        }
    }

    /// 软件 is in no phrase table, so it only becomes 軟體 because the
    /// characters between phrase matches reach the Taiwan table as one run.
    @Test func unmatchedRunReachesTheRegionalTableWhole() {
        #expect(TraditionalChinese.apply("软件", script: .taiwan, language: "zh") == "軟體")
    }

    @Test func unchangedLeavesTextAlone() {
        #expect(TraditionalChinese.apply("软件", script: .unchanged, language: "zh") == "软件")
    }

    @Test func alreadyTraditionalTextStaysTraditional() {
        #expect(TraditionalChinese.apply("頭髮發現了問題", script: .taiwan, language: "zh") == "頭髮發現了問題")
    }

    @Test func automaticConvertsChineseButNotJapanese() {
        #expect(TraditionalChinese.apply("这是软件", script: .taiwan, language: "auto") == "這是軟體")
        #expect(TraditionalChinese.apply("会社に行きます", script: .taiwan, language: "auto") == "会社に行きます")
    }

    @Test func pinnedNonChineseLanguageIsNeverConverted() {
        #expect(TraditionalChinese.apply("会社", script: .taiwan, language: "ja") == "会社")
        #expect(TraditionalChinese.apply("软件", script: .taiwan, language: "en") == "软件")
    }

    @Test func cantoneseAndRegionalCodesConvert() {
        #expect(TraditionalChinese.apply("软件", script: .hongKong, language: "yue") == "軟件")
        #expect(TraditionalChinese.apply("软件", script: .taiwan, language: "zh-CN") == "軟體")
    }

    @Test func latinTextIsUntouched() {
        #expect(TraditionalChinese.apply("Meet at 3pm.", script: .taiwan, language: "auto") == "Meet at 3pm.")
    }

    /// A Chinese path names one page; its Traditional spelling names another.
    @Test func webAddressesAreLeftAlone() {
        #expect(
            TraditionalChinese.apply("打开 https://example.com/软件 看看软件", script: .taiwan, language: "zh")
                == "開啟 https://example.com/软件 看看軟體"
        )
    }

    /// A model that reports `zh` for a mixed sentence has not made its
    /// Japanese Chinese: the kana guard holds whatever the language says.
    @Test func kanaBlocksConversionEvenWhenReportedAsChinese() {
        #expect(TraditionalChinese.apply("软件は会社です", script: .taiwan, language: "zh") == "软件は会社です")
    }

    /// The trigger is Traditional and the spoken text Simplified, so the
    /// snippet only fires if conversion runs first; and the expansion is
    /// Simplified, so it stays that way only if conversion does not run after.
    @Test func conversionRunsBeforeSnippetsAndNotAfter() {
        #expect(
            DictatedTranscript.finished(
                "软件",
                style: .raw,
                language: "zh",
                repairSpeech: false,
                numbersAsDigits: false,
                spokenEmoji: false,
                chineseScript: .taiwan,
                snippets: [Snippet(trigger: "軟體", expansion: "简体软件")],
                vocabulary: []
            ) == "简体软件"
        )
    }

    /// Applies to `raw` too: it is a writing system, not an edit.
    @Test func funnelConvertsRaw() {
        #expect(
            DictatedTranscript.finished(
                "我们用软件",
                style: .raw,
                language: "zh",
                repairSpeech: false,
                numbersAsDigits: false,
                spokenEmoji: false,
                chineseScript: .taiwan,
                snippets: [],
                vocabulary: []
            ) == "我們用軟體"
        )
    }
}
