import SharedIPC
import SmartPinyinCore
import XCTest

final class SmartPunctuationTests: XCTestCase {
    func testDirectEnglishModeAlwaysUsesHalfWidthPunctuation() {
        let engine = SmartPunctuationEngine()
        let ctx = SmartPunctuationEngine.Context(
            mode: .directEnglish,
            preferences: .default,
            appBundleID: "com.tencent.xinWeChat",
            leftContext: "你好"
        )
        for ch in [",", ".", "!", "?", ":", ";", "(", ")", "\"", "'"] {
            XCTAssertNil(engine.mapPunctuation(ch, context: ctx), "Expected half-width for \(ch)")
        }
    }

    func testChineseAndMixedChineseEnglishUseChinesePunctuationAndPairedQuotes() {
        let engine = SmartPunctuationEngine()
        let baseCtx = SmartPunctuationEngine.Context(
            mode: .chinesePinyin,
            preferences: .default,
            appBundleID: "com.tencent.xinWeChat",
            leftContext: "今天天气不错"
        )
        XCTAssertEqual(engine.mapPunctuation(",", context: baseCtx), "，")
        XCTAssertEqual(engine.mapPunctuation(".", context: baseCtx), "。")
        XCTAssertEqual(engine.mapPunctuation("!", context: baseCtx), "！")
        XCTAssertEqual(engine.mapPunctuation("?", context: baseCtx), "？")
        XCTAssertEqual(engine.mapPunctuation("(", context: baseCtx), "（")
        XCTAssertEqual(engine.mapPunctuation(")", context: baseCtx), "）")

        // 智能配对中式双引号与单引号
        XCTAssertEqual(engine.mapPunctuation("\"", context: baseCtx), "“")
        XCTAssertEqual(engine.mapPunctuation("\"", context: baseCtx), "”")
        XCTAssertEqual(engine.mapPunctuation("'", context: baseCtx), "‘")
        XCTAssertEqual(engine.mapPunctuation("'", context: baseCtx), "’")

        // 中英混输：如 "重启了" + T3 + "," -> 中文逗号，但 "React" + "(" -> 半角代码括号！
        let mixedCtx = SmartPunctuationEngine.Context(
            mode: .chinesePinyin,
            preferences: .default,
            appBundleID: "com.tencent.xinWeChat",
            leftContext: "重启了",
            isTrailingInlineEnglish: true
        )
        XCTAssertEqual(engine.mapPunctuation(",", context: mixedCtx), "，")
        XCTAssertEqual(engine.mapPunctuation("!", context: mixedCtx), "！")
        XCTAssertNil(engine.mapPunctuation("(", context: mixedCtx))
        XCTAssertNil(engine.mapPunctuation("[", context: mixedCtx))

        // 纯英文前文下尾随逗号保持半角
        let englishCtx = SmartPunctuationEngine.Context(
            mode: .chinesePinyin,
            preferences: .default,
            appBundleID: "com.tencent.xinWeChat",
            leftContext: "Hello ",
            isTrailingInlineEnglish: true
        )
        XCTAssertNil(engine.mapPunctuation(",", context: englishCtx))
    }

    func testNumbersAndURLsKeepHalfWidthDotAndColon() {
        let engine = SmartPunctuationEngine()
        let numCtx = SmartPunctuationEngine.Context(
            mode: .chinesePinyin,
            preferences: .default,
            appBundleID: "com.tencent.xinWeChat",
            leftContext: "价格是3"
        )
        XCTAssertNil(engine.mapPunctuation(".", context: numCtx))
        XCTAssertNil(engine.mapPunctuation(":", context: numCtx))
        // 数字后逗号依然走中文逗号（如 "共3，"）
        XCTAssertEqual(engine.mapPunctuation(",", context: numCtx), "，")

        let urlCtx = SmartPunctuationEngine.Context(
            mode: .chinesePinyin,
            preferences: .default,
            appBundleID: "com.tencent.xinWeChat",
            leftContext: "访问 https"
        )
        XCTAssertNil(engine.mapPunctuation(":", context: urlCtx))
    }

    func testCodingModeAutoDetectsDevAppsAndManualOverrideWorks() {
        let engine = SmartPunctuationEngine()
        let prefs = SmartPinyinPreferences.default
        XCTAssertTrue(prefs.autoCodingModeForDevApps)
        XCTAssertFalse(prefs.codingModeEnabled)

        // IDE / 终端 / T3 Code 自动启用 Coding 模式 -> 半角英文标点
        for devApp in ["com.t3tools.t3code", "com.microsoft.VSCode", "com.apple.Terminal", "com.jetbrains.intellij"] {
            XCTAssertTrue(SmartPunctuationEngine.isEffectiveCodingMode(preferences: prefs, appBundleID: devApp))
            let ctx = SmartPunctuationEngine.Context(
                mode: .chinesePinyin,
                preferences: prefs,
                appBundleID: devApp,
                leftContext: "写一句注释"
            )
            XCTAssertNil(engine.mapPunctuation(",", context: ctx))
            XCTAssertNil(engine.mapPunctuation(".", context: ctx))
            XCTAssertNil(engine.mapPunctuation("(", context: ctx))
        }

        // 微信 / 备忘录默认非 Coding 模式 -> 中文标点
        let wechatCtx = SmartPunctuationEngine.Context(
            mode: .chinesePinyin,
            preferences: prefs,
            appBundleID: "com.tencent.xinWeChat",
            leftContext: "晚上一起吃饭"
        )
        XCTAssertEqual(engine.mapPunctuation(",", context: wechatCtx), "，")

        // 手动开启全局 Coding 模式后，即使在微信也输出半角英文标点
        var manualCoding = prefs
        manualCoding.codingModeEnabled = true
        let forcedCtx = SmartPunctuationEngine.Context(
            mode: .chinesePinyin,
            preferences: manualCoding,
            appBundleID: "com.tencent.xinWeChat",
            leftContext: "晚上一起吃饭"
        )
        XCTAssertNil(engine.mapPunctuation(",", context: forcedCtx))
    }

    func testTranslateModePunctuationRespectsTargetLanguageAndBuffer() {
        let engine = SmartPunctuationEngine()

        // 翻译模式空态（英语）：输出英文半角
        let enIdle = SmartPunctuationEngine.Context(
            mode: .translateOnCommit(.english),
            preferences: .default,
            appBundleID: "com.tencent.xinWeChat",
            leftContext: "Hello"
        )
        XCTAssertNil(engine.mapPunctuation("!", context: enIdle))

        // 翻译模式空态（日语）：输出日式标点
        let jaIdle = SmartPunctuationEngine.Context(
            mode: .translateOnCommit(.japanese),
            preferences: .default,
            appBundleID: "com.tencent.xinWeChat",
            leftContext: "こんにちは"
        )
        XCTAssertEqual(engine.mapPunctuation(",", context: jaIdle), "、")
        XCTAssertEqual(engine.mapPunctuation(".", context: jaIdle), "。")

        // 翻译模式待译中文缓冲中：始终按中文标点断句
        let inBuffer = SmartPunctuationEngine.Context(
            mode: .translateOnCommit(.english),
            preferences: .default,
            appBundleID: "com.t3tools.t3code",
            leftContext: "你好",
            isInsideChineseTranslationBuffer: true
        )
        XCTAssertEqual(engine.mapPunctuation("!", context: inBuffer), "！")
    }
}
