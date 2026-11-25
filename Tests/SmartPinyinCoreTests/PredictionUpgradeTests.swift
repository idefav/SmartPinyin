import Foundation
import LocalInferenceCore
import PinyinEngineCore
import SharedIPC
import SmartPinyinCore
import XCTest

private final class PredictionMockEngine: PinyinEngineProtocol {
    var buffer = ""
    var dictionary: [String: [String]] = [
        "n": ["你", "那", "能"],
        "nx": ["那些", "内心", "逆向"],
        "s": ["是", "说", "上"]
    ]

    func processKey(keyval: Int32, mask: Int32) -> (handled: Bool, snapshot: PinyinEngineSnapshot) {
        if keyval == 0xff08 {
            guard !buffer.isEmpty else { return (false, .idle) }
            buffer.removeLast()
            return (true, currentSnapshot())
        }
        guard let scalar = UnicodeScalar(UInt32(keyval)) else { return (false, currentSnapshot()) }
        let ch = Character(scalar)
        if ch.isLetter {
            buffer.append(ch.lowercased())
            return (true, currentSnapshot())
        }
        return (false, currentSnapshot())
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
        let texts = dictionary[buffer] ?? [buffer]
        let cands = texts.enumerated().map { PinyinCandidate(index: $0.offset, text: $0.element) }
        return PinyinEngineSnapshot(isComposing: true, preedit: buffer, rawInput: buffer, candidates: cands)
    }
}

final class PredictionUpgradeTests: XCTestCase {
    func testSuffixPrefixOverlapStrippingFixesRepeatedPrefixBug() {
        XCTAssertEqual(
            PredictionPostProcessor.stripSuffixPrefixOverlap(leftContext: "今天天气", candidate: "天气预报好了"),
            "预报好了"
        )
        XCTAssertEqual(
            PredictionPostProcessor.stripSuffixPrefixOverlap(leftContext: "系统问题", candidate: "问题排查"),
            "排查"
        )
        XCTAssertEqual(
            PredictionPostProcessor.stripSuffixPrefixOverlap(leftContext: "今天天气", candidate: "今天天气怎么样"),
            "怎么样"
        )
        XCTAssertEqual(
            PredictionPostProcessor.stripSuffixPrefixOverlap(leftContext: "我想", candidate: "想想办法"),
            "想想办法"
        )
    }

    func testRefineBranchesFiltersLowConfidenceDanglingParticlesAndDeduplicatesPrefix() {
        let branches = [
            RawContinuationBranch(text: "怎么样", avgLogProb: -1.1),
            RawContinuationBranch(text: "怎么样呀", avgLogProb: -1.3),
            RawContinuationBranch(text: "天气预报", avgLogProb: -1.5),
            RawContinuationBranch(text: "真好的", avgLogProb: -1.7),
            RawContinuationBranch(text: "继续享受", avgLogProb: -4.6),
            RawContinuationBranch(text: "的", avgLogProb: -0.9)
        ]

        let refined = PredictionPostProcessor.refineBranches(
            branches,
            leftContext: "今天天气",
            maxSuggestions: 3
        )
        XCTAssertEqual(refined, ["怎么样", "预报", "真好"])

        let noisyBranches = [
            RawContinuationBranch(text: "是2月25", avgLogProb: -0.9),
            RawContinuationBranch(text: "的天气怎么样", avgLogProb: -1.0),
            RawContinuationBranch(text: "会是星期几", avgLogProb: -1.2),
            RawContinuationBranch(text: "是星期几", avgLogProb: -1.3),
            RawContinuationBranch(text: "明天北京", avgLogProb: -0.8),
            RawContinuationBranch(text: "适合出行吗", avgLogProb: -1.4)
        ]
        let cleaned = PredictionPostProcessor.refineBranches(
            noisyBranches,
            leftContext: "明天北京",
            maxSuggestions: 3
        )
        XCTAssertEqual(cleaned, ["的天气怎么样", "会是星期几", "适合出行吗"])

        XCTAssertEqual(
            PredictionPostProcessor.sanitize(rawText: "，打扰一下", leftContext: "不好意思"),
            "，打扰一下"
        )
    }

    func testMergeAndRefineCombinesInstantMemoryAndNeuralWithoutDuplicates() {
        let merged = PredictionPostProcessor.mergeAndRefine(
            leftContext: "系统问题出现在",
            instantMemory: ["什么地方"],
            neuralSuggestions: ["什么地方呢", "哪里", "哪个模块", "什么原因"],
            maxSuggestions: 3
        )
        XCTAssertEqual(merged, ["什么地方", "哪里", "哪个模块"])
    }

    func testPredictionLRUCacheHitAndEviction() {
        let cache = PredictionLRUCache(capacity: 16)
        cache.set(contextTail: "今天天气", maxSuggestions: 3, suggestions: ["怎么样", "真好", "不错"])
        XCTAssertEqual(cache.get(contextTail: "今天天气", maxSuggestions: 3), ["怎么样", "真好", "不错"])
        XCTAssertNil(cache.get(contextTail: "今天天气", maxSuggestions: 2))

        for i in 0..<20 {
            cache.set(contextTail: "测试上文\(i)", maxSuggestions: 3, suggestions: ["方案", "进度"])
        }
        XCTAssertEqual(cache.count, 16)
        XCTAssertNil(cache.get(contextTail: "今天天气", maxSuggestions: 3))
    }

    func testDirectDigitSelectionNumericContextGuardOptionDigitsAndMemoryFeedback() {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smartpinyin-pred-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("user_memory.sqlite3")
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let store = UserMemoryStore(databaseURL: dbURL)
        let wm = SessionWorkingMemory()
        var now: TimeInterval = 1_700_000_000
        let sm = InputStateMachine(
            engine: PredictionMockEngine(),
            memoryStore: store,
            workingMemory: wm,
            clock: { now }
        )
        sm.updateRuntimeContext(leftContext: "上海秋天有", appBundleID: "com.google.Chrome", isSecureInput: false)

        // 1. 默认数字直选模式：predictionDirectDigitSelect == true，按 2 直接采纳第 2 条并反哺记忆
        let showAction = sm.applyPredictions(["什么好玩的", "哪些景点", "什么美食"], forToken: sm.sessionToken)
        guard case .updateUI(let initialSnap) = showAction else {
            return XCTFail("Expected initial prediction UI")
        }
        XCTAssertTrue(initialSnap.predictionDirectDigitSelect)

        let pick2Acts = sm.handle(NormalizedKeyEvent(kind: .character("2", keyCode: 19)))
        XCTAssertTrue(pick2Acts.contains(where: {
            if case .commitText(let text, let requestPredictions) = $0 {
                return text == "哪些景点" && requestPredictions
            }
            return false
        }))

        // 验证已同步写入 SessionWorkingMemory
        let instantWM = wm.immediateContinuations(
            forLeftContext: "上海秋天有",
            appBundleID: "com.google.Chrome",
            shareAcrossApps: true,
            limit: 2,
            now: now + 5
        )
        XCTAssertTrue(instantWM.contains("哪些景点"), "Accepted prediction must feed SessionWorkingMemory, got \(instantWM)")

        // 2. 数字语境智能避让：前文为「版本」时，predictionDirectDigitSelect 自动置 false 且按 2 放行不误触
        now += 10
        sm.updateRuntimeContext(leftContext: "升级到版本", appBundleID: "com.google.Chrome", isSecureInput: false)
        let numShow = sm.applyPredictions(["更新日志", "说明文档"], forToken: sm.sessionToken)
        guard case .updateUI(let numSnap) = numShow else {
            return XCTFail("Expected numeric-context prediction UI")
        }
        XCTAssertFalse(numSnap.predictionDirectDigitSelect)
        let digit2Pass = sm.handle(NormalizedKeyEvent(kind: .character("2", keyCode: 19)))
        XCTAssertTrue(digit2Pass.contains(.passThrough), "Digit 2 after 版本 must pass through as literal number")

        // 3. 切为 .optionDigits123 模式时：普通数字放行，Option + 3 直接采纳第 3 条
        var prefs = sm.preferences
        prefs.predictionSelectionShortcut = .optionDigits123
        sm.applyPreferences(prefs)
        sm.updateRuntimeContext(leftContext: "今天天气", appBundleID: "com.google.Chrome", isSecureInput: false)
        _ = sm.applyPredictions(["晴朗", "真好", "很热"], forToken: sm.sessionToken)
        let opt3Acts = sm.handle(NormalizedKeyEvent(kind: .character("3", keyCode: 20), modifiers: [.option]))
        XCTAssertTrue(opt3Acts.contains(where: {
            if case .commitText(let text, let requestPredictions) = $0 {
                return text == "很热" && requestPredictions
            }
            return false
        }))
    }

    func testFirstLetterZeroMsInlinePredictionFusionAndQuietModeAndExpiry() {
        var now: TimeInterval = 1_700_000_000
        let engine = PredictionMockEngine()
        var prefs = SmartPinyinPreferences.default
        prefs.predictionDisplayStyle = .inlineFusionOnly
        let sm = InputStateMachine(
            engine: engine,
            preferences: prefs,
            clock: { now }
        )
        sm.updateRuntimeContext(leftContext: "上海秋天有", appBundleID: "com.google.Chrome", isSecureInput: false)

        // 1. 安静模式（inlineFusionOnly）：不弹出独立联想条，但写入 6 秒静默接力缓存
        let barAction = sm.applyPredictions(["什么好玩的", "哪些景点", "什么美食"], forToken: sm.sessionToken)
        XCTAssertNil(barAction, "inlineFusionOnly mode must not show floating prediction bar")

        // 2. 不停顿直接敲单字母 n -> 候选栏第 1 位 0ms 立即给出「哪些景点」（带 .neuralPrediction 来源）
        let nActs = sm.handle(NormalizedKeyEvent(kind: .character("n", keyCode: 45)))
        let nSnap = nActs.compactMap { act -> CandidatePanelSnapshot? in
            if case .updateUI(let s) = act { return s }
            return nil
        }.last
        XCTAssertEqual(nSnap?.candidates.first?.text, "哪些景点")
        XCTAssertEqual(nSnap?.candidates.first?.source, .neuralPrediction)

        // 按空格直接整段上屏「哪些景点」
        let spaceActs = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(spaceActs.contains(where: {
            if case .commitText(let text, _) = $0 { return text == "哪些景点" }
            return false
        }))

        // 3. 超过 6 秒后缓存自动过期，不再串句
        sm.updateRuntimeContext(leftContext: "上海秋天有", appBundleID: "com.google.Chrome", isSecureInput: false)
        sm.cachePredictionsForInlineFusion(["哪些景点"], forLeftContext: "上海秋天有")
        now += 7.0
        let expiredActs = sm.handle(NormalizedKeyEvent(kind: .character("n", keyCode: 45)))
        let expiredSnap = expiredActs.compactMap { act -> CandidatePanelSnapshot? in
            if case .updateUI(let s) = act { return s }
            return nil
        }.last
        XCTAssertNotEqual(expiredSnap?.candidates.first?.text, "哪些景点", "Expired pending prediction must not leak")
    }
}
