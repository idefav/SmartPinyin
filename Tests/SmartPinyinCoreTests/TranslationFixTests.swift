import LocalInferenceCore
import PinyinEngineCore
import SharedIPC
import SmartPinyinCore
import XCTest

private final class PiecemealMockEngine: PinyinEngineProtocol {
    var buffer = ""
    let dict: [String: [String]] = [
        "d": ["的", "到", "地"],
        "jt": ["今天", "具体"],
        "tqbc": ["天气不错", "天气不差"],
        "nh": ["你好", "女孩"]
    ]

    func processKey(keyval: Int32, mask: Int32) -> (handled: Bool, snapshot: PinyinEngineSnapshot) {
        if keyval == 0xff08 {
            guard !buffer.isEmpty else { return (false, .idle) }
            buffer.removeLast()
            return (true, currentSnapshot())
        }
        guard let scalar = UnicodeScalar(UInt32(keyval)) else { return (false, currentSnapshot()) }
        let ch = Character(scalar)
        guard ch.isLetter else { return (false, currentSnapshot()) }
        buffer.append(ch.lowercased())
        return (true, currentSnapshot())
    }

    func selectCandidateOnCurrentPage(index: Int) -> PinyinEngineSnapshot {
        let snap = currentSnapshot()
        guard snap.candidates.indices.contains(index) else { return snap }
        let chosen = snap.candidates[index].text
        buffer = ""
        return PinyinEngineSnapshot(isComposing: false, committedText: chosen)
    }

    func changePage(forward: Bool) -> PinyinEngineSnapshot { currentSnapshot() }
    func moveHighlight(delta: Int) -> PinyinEngineSnapshot { currentSnapshot() }
    func commitComposition() -> String? {
        let text = currentSnapshot().bestSentence
        buffer = ""
        return text.isEmpty ? nil : text
    }
    func clearComposition() { buffer = "" }

    func currentSnapshot() -> PinyinEngineSnapshot {
        guard !buffer.isEmpty else { return .idle }
        let texts = dict[buffer] ?? [buffer]
        let cands = texts.enumerated().map { PinyinCandidate(index: $0.offset, text: $0.element) }
        return PinyinEngineSnapshot(
            isComposing: true,
            preedit: buffer,
            rawInput: buffer,
            candidates: cands,
            highlightedIndex: 0
        )
    }
}

final class TranslationFixTests: XCTestCase {
    func testTranslationSpacingHelperPreventsGluedWords() {
        // 典型分段翻译粘连修复：Hello! + Today -> " Today"
        XCTAssertEqual(
            TranslationSpacingHelper.formatForCommit(
                translatedText: "Today",
                leftContext: "Hello!",
                target: .english,
                autoSpaceEnabled: true
            ),
            " Today"
        )
        XCTAssertEqual(
            TranslationSpacingHelper.formatForCommit(
                translatedText: "The weather is nice.",
                leftContext: "Hello! Today",
                target: .english,
                autoSpaceEnabled: true
            ),
            " The weather is nice."
        )
        // 左侧已有空格不重复补
        XCTAssertEqual(
            TranslationSpacingHelper.formatForCommit(
                translatedText: "Today",
                leftContext: "Hello! ",
                target: .english,
                autoSpaceEnabled: true
            ),
            "Today"
        )
        // 新译文以标点开头不补空格
        XCTAssertEqual(
            TranslationSpacingHelper.formatForCommit(
                translatedText: ", thank you.",
                leftContext: "Hello",
                target: .english,
                autoSpaceEnabled: true
            ),
            ", thank you."
        )
        // 日语不需要自动补空格
        XCTAssertEqual(
            TranslationSpacingHelper.formatForCommit(
                translatedText: "今日はいい天気です。",
                leftContext: "こんにちは！",
                target: .japanese,
                autoSpaceEnabled: true
            ),
            "今日はいい天気です。"
        )
        // 关闭自动补空格开关时保持原样
        XCTAssertEqual(
            TranslationSpacingHelper.formatForCommit(
                translatedText: "Today",
                leftContext: "Hello!",
                target: .english,
                autoSpaceEnabled: false
            ),
            "Today"
        )
    }

    func testTranslationOutputSanityValidatorBlocksEchoAndLeakage() {
        // 拦截回声复读（截图中的 "Hello! Hello!"）
        XCTAssertFalse(LocalInferenceCoordinator.isValidTranslationOutput(
            source: "的",
            output: "Hello! Hello!",
            target: .english
        ))
        // 拦截指令泄露
        XCTAssertFalse(LocalInferenceCoordinator.isValidTranslationOutput(
            source: "今天",
            output: "将以下文本翻译为英语：Today",
            target: .english
        ))
        // 拦截短词极端长度爆炸
        XCTAssertFalse(LocalInferenceCoordinator.isValidTranslationOutput(
            source: "的",
            output: String(repeating: "very long hallucination ", count: 4),
            target: .english
        ))
        // 拦截未翻译的纯中文原样返回
        XCTAssertFalse(LocalInferenceCoordinator.isValidTranslationOutput(
            source: "天气不错",
            output: "天气不错",
            target: .english
        ))
        // 正常高质量译文全部放行
        XCTAssertTrue(LocalInferenceCoordinator.isValidTranslationOutput(
            source: "你好",
            output: "Hello!",
            target: .english
        ))
        XCTAssertTrue(LocalInferenceCoordinator.isValidTranslationOutput(
            source: "今天天气不错",
            output: "The weather is nice today.",
            target: .english
        ))
    }

    func testSingleLetterIncompletePinyinDefersLoadingStateInTranslateMode() {
        let engine = PiecemealMockEngine()
        var prefs = SmartPinyinPreferences.default
        prefs.defaultTranslateMode = true
        let sm = InputStateMachine(engine: engine, preferences: prefs)

        // 刚敲 1 个字母 d -> 「的」，翻译栏保持 .hidden 温和等待提示，不立刻闪烁 loading
        let actions1 = sm.handle(NormalizedKeyEvent(kind: .character("d", keyCode: 0)))
        var panel1: CandidatePanelSnapshot?
        for a in actions1 {
            if case .updateUI(let p) = a { panel1 = p }
        }
        XCTAssertEqual(panel1?.showTranslationBar, true)
        XCTAssertEqual(panel1?.translationPreview, .hidden)

        // 清空后输入 2 字母完整词 "nh" -> 「你好」，立刻进入 .loading 实时翻译态
        _ = sm.resetSession()
        _ = sm.handle(NormalizedKeyEvent(kind: .character("n", keyCode: 0)))
        let actions2 = sm.handle(NormalizedKeyEvent(kind: .character("h", keyCode: 0)))
        var panel2: CandidatePanelSnapshot?
        for a in actions2 {
            if case .updateUI(let p) = a { panel2 = p }
        }
        XCTAssertEqual(panel2?.translationPreview, .loading(sourceText: "你好", target: .english))
    }

    func testComposeChineseSegmentSpaceBehaviorAssemblesWholeSentenceBeforeCommit() {
        let engine = PiecemealMockEngine()
        var prefs = SmartPinyinPreferences.default
        prefs.defaultTranslateMode = true
        prefs.translateSpaceBehavior = .composeChineseSegment
        let sm = InputStateMachine(engine: engine, preferences: prefs)

        // 输入 jt 并按空格 -> 不上屏英文，而是拼入待译中文句「今天」
        for ch in "jt" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        let afterFirstSpace = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertFalse(afterFirstSpace.contains(where: { if case .commitTranslation = $0 { return true }; return false }))

        // 继续输入 tqbc -> 待译完整中文句自动合并为「今天天气不错」
        var latestToken: UInt64 = 0
        var latestSentence = ""
        for ch in "tqbc" {
            let acts = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
            for a in acts {
                if case .requestNeuralEnhancement(let tok, _, let sentence, _, _) = a {
                    latestToken = tok
                    latestSentence = sentence
                }
            }
        }
        XCTAssertEqual(latestSentence, "今天天气不错")

        _ = sm.applyTranslationPreview(
            .ready(
                sourceText: "今天天气不错",
                translatedText: "The weather is nice today.",
                target: .english,
                latencyMs: 95
            ),
            forToken: latestToken
        )

        // 按回车一次性上屏整句自然英文译文
        let commitActs = sm.handle(NormalizedKeyEvent(kind: .returnKey))
        XCTAssertTrue(commitActs.contains(.commitTranslation(
            sourceText: "今天天气不错",
            target: .english,
            cachedTranslation: "The weather is nice today."
        )))
    }
}
