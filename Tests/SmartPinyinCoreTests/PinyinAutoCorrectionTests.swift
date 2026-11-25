import Foundation
import PinyinEngineCore
import SharedIPC
import SmartPinyinCore
import XCTest

private final class TypoMockEngine: PinyinEngineProtocol {
    var buffer = ""
    var preeditMap: [String: String] = [
        "shaighai": "s hai g hai",
        "shanhai": "shan hai",
        "shnaghai": "s h na g hai",
        "shanghaii": "shang hai i",
        "xtwt": "x t w t"
    ]
    var candidatesMap: [String: [String]] = [
        "shaighai": ["上海归海", "晒干后", "上海工"],
        "shanhai": ["山海", "山", "删改"],
        "shnaghai": ["甚海", "上海归"],
        "shanghaii": ["上海一", "伤害一"],
        "xtwt": ["系统问题", "协同问题"]
    ]
    var probeMap: [String: [String]] = [
        "shanghai": ["上海", "伤害", "尚海"],
        "nihao": ["你好", "拟好"],
        "women": ["我们", "卧们"],
        "shenme": ["什么", "神魔"]
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
        let t = currentSnapshot().bestSentence
        buffer = ""
        return t.isEmpty ? nil : t
    }

    func clearComposition() { buffer = "" }

    func currentSnapshot() -> PinyinEngineSnapshot {
        guard !buffer.isEmpty else { return .idle }
        let texts = candidatesMap[buffer] ?? [buffer]
        let cands = texts.enumerated().map { PinyinCandidate(index: $0.offset, text: $0.element) }
        return PinyinEngineSnapshot(
            isComposing: true,
            preedit: preeditMap[buffer] ?? buffer,
            rawInput: buffer,
            candidates: cands
        )
    }

    func probeCandidates(forPinyin pinyin: String, limit: Int) -> [PinyinCandidate] {
        guard let list = probeMap[pinyin] else { return [] }
        return list.prefix(limit).enumerated().map {
            PinyinCandidate(index: $0.offset, text: $0.element, source: .typoCorrected)
        }
    }
}

final class PinyinAutoCorrectionTests: XCTestCase {
    func testPinyinTypoCorrectorCoversAllMajorFastTypingErrors() {
        let corrector = PinyinTypoCorrector()

        // 1. 截图 3：跨排误触 shaighai (i -> n) -> shanghai
        let shaighai = corrector.suggestCorrections(rawPinyin: "shaighai", preedit: "s hai g hai")
        XCTAssertTrue(shaighai.contains(where: { $0.correctedPinyin == "shanghai" && $0.isFragmentedSource }), "Got \(shaighai)")

        // 2. 截图 2：前后鼻音漏 g shanhai -> shanghai
        let shanhai = corrector.suggestCorrections(rawPinyin: "shanhai", preedit: "shan hai", enableNasalCompletion: true)
        XCTAssertTrue(shanhai.contains(where: { $0.correctedPinyin == "shanghai" && !$0.isFragmentedSource }), "Got \(shanhai)")

        // 3. 相邻字母倒序（transposition）
        let shnaghai = corrector.suggestCorrections(rawPinyin: "shnaghai", preedit: "s h na g hai")
        XCTAssertTrue(shnaghai.contains(where: { $0.correctedPinyin == "shanghai" }), "Got \(shnaghai)")
        let nihoa = corrector.suggestCorrections(rawPinyin: "nihoa", preedit: "ni ho a")
        XCTAssertTrue(nihoa.contains(where: { $0.correctedPinyin == "nihao" }), "Got \(nihoa)")
        let womne = corrector.suggestCorrections(rawPinyin: "womne", preedit: "wo m ne")
        XCTAssertTrue(womne.contains(where: { $0.correctedPinyin == "women" }), "Got \(womne)")
        let shenem = corrector.suggestCorrections(rawPinyin: "shenem", preedit: "she ne m")
        XCTAssertTrue(shenem.contains(where: { $0.correctedPinyin == "shenme" }), "Got \(shenem)")

        // 4. QWERTY 邻键误触
        let shamghai = corrector.suggestCorrections(rawPinyin: "shamghai", preedit: "sha m g hai")
        XCTAssertTrue(shamghai.contains(where: { $0.correctedPinyin == "shanghai" }), "Got \(shamghai)")
        let nijao = corrector.suggestCorrections(rawPinyin: "nijao", preedit: "ni j ao")
        XCTAssertTrue(nijao.contains(where: { $0.correctedPinyin == "nihao" }), "Got \(nijao)")

        // 5. 多敲重复连键与漏元音
        let dupKey = corrector.suggestCorrections(rawPinyin: "shanghaii", preedit: "shang hai i")
        XCTAssertTrue(dupKey.contains(where: { $0.correctedPinyin == "shanghai" }), "Got \(dupKey)")
        let missingVowel = corrector.suggestCorrections(rawPinyin: "shnghai", preedit: "sh n g hai")
        XCTAssertTrue(missingVowel.contains(where: { $0.correctedPinyin == "shanghai" }), "Got \(missingVowel)")

        // 6. 纯简拼与短简拼绝不误改
        XCTAssertTrue(corrector.suggestCorrections(rawPinyin: "xtwt", preedit: "x t w t").isEmpty)
        XCTAssertTrue(corrector.suggestCorrections(rawPinyin: "zgr", preedit: "z g r").isEmpty)
    }

    func testStateMachinePromotesFragmentedTypoToTop1AndRecordsCorrectedPinyinOnly() {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smartpinyin-typo-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("user_memory.sqlite3")
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let store = UserMemoryStore(databaseURL: dbURL)
        let engine = TypoMockEngine()
        let sm = InputStateMachine(engine: engine, memoryStore: store)
        sm.updateRuntimeContext(leftContext: "", appBundleID: "com.google.Chrome", isSecureInput: false)

        // 复现截图 3：敲 shaighai，纠偏候选「上海」应跃居第 1 位（.typoCorrected）
        var lastSnap: CandidatePanelSnapshot?
        for ch in "shaighai" {
            let acts = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
            if let s = acts.compactMap({ act -> CandidatePanelSnapshot? in
                if case .updateUI(let p) = act { return p }
                return nil
            }).last {
                lastSnap = s
            }
        }
        XCTAssertEqual(lastSnap?.candidates.first?.text, "上海")
        XCTAssertEqual(lastSnap?.candidates.first?.source, .typoCorrected)

        // 按空格选中「上海」后，记忆库应按正确拼音 shanghai 记录，绝不污染错拼 shaighai！
        let commitActs = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(commitActs.contains(where: {
            if case .commitText(let text, _) = $0 { return text == "上海" }
            return false
        }))
        let cleanSig = store.lookupSignals(pinyin: "shanghai", word: "上海", leftContext: "", appBundleID: "com.google.Chrome")
        let dirtySig = store.lookupSignals(pinyin: "shaighai", word: "上海", leftContext: "", appBundleID: "com.google.Chrome")
        XCTAssertGreaterThan(cleanSig.exactPref, 0.5, "Should record under corrected pinyin shanghai")
        XCTAssertEqual(dirtySig.exactPref, 0.0, "Must never pollute memory store with typo shaighai")

        // 复现截图 2：shanhai 本身合法时，无强记忆排第 2 位；刚高频用过上海后可被记忆辅助上浮！
        var shanhaiSnap: CandidatePanelSnapshot?
        for ch in "shanhai" {
            let acts = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
            if let s = acts.compactMap({ act -> CandidatePanelSnapshot? in
                if case .updateUI(let p) = act { return p }
                return nil
            }).last {
                shanhaiSnap = s
            }
        }
        let shanhaiTexts = shanhaiSnap?.candidates.prefix(3).map(\.text) ?? []
        XCTAssertTrue(shanhaiTexts.contains("山海") && shanhaiTexts.contains("上海"), "Expected both 山海 and 上海 for shanhai, got \(shanhaiTexts)")
    }

    func testRealRimeEngineFuzzyNasalAndShadowProbeCorrection() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dataDir = projectRoot.appendingPathComponent("Resources/RimeData")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dataDir.path), "RimeData not present")

        let tempUser = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartPinyinAutoCorr_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempUser) }

        var prefs = SmartPinyinPreferences.default
        prefs.enableAutoCorrection = true
        prefs.fuzzyNasalPinyin = true
        let engine = RimeEngineAdapter(
            bundledDataDirectory: dataDir,
            userDataDirectory: tempUser,
            preferredSchemaID: "wanxiang",
            initialPreferences: prefs
        )

        // 1. 真实 librime + 万象：开启前后鼻音模糊后，输入 shanhai 应同时包含「山海」与「上海」
        let shanhaiSnap = engine.feedASCII("shanhai")
        let topShanhai = (shanhaiSnap.candidates + shanhaiSnap.extendedCandidates).map(\.text)
        XCTAssertTrue(topShanhai.contains("上海"), "Expected fuzzy nasal shanhai to recall 上海 in real Rime, got \(topShanhai)")

        // 2. 真实 Shadow Probe：在主会话正输入 shaighai 时调用 probeCandidates("shanghai")，
        //    既能查出「上海」，又绝不破坏主会话的 rawInput / preedit！
        engine.clearComposition()
        let beforeProbe = engine.feedASCII("shaighai")
        let probed = engine.probeCandidates(forPinyin: "shanghai", limit: 3)
        XCTAssertTrue(probed.map(\.text).contains("上海"), "Expected Shadow Probe to return 上海, got \(probed)")
        let afterProbe = engine.currentSnapshot()
        XCTAssertEqual(afterProbe.rawInput, beforeProbe.rawInput, "Shadow probe must never mutate main Rime session")

        // 3. 端到端真实 InputStateMachine + 真实 RimeEngineAdapter：
        //    - 截图 3：shaighai（碎裂错拼）-> 「上海」直接排第 1 位（带 .typoCorrected）
        //    - 截图 2：shanhai（合法前后鼻音）-> 前 3 位同时包含「山海」与「上海」
        //    - 连键/漏元音：shanghaii / shnghai -> 「上海」直接排第 1 位
        //    - 正常全拼：nihaoshijie -> 首候选「你好世界」，无暴力纠错噪声
        engine.clearComposition()
        let sm = InputStateMachine(engine: engine, preferences: prefs)
        func typeAndGetPanel(_ text: String) -> CandidatePanelSnapshot? {
            _ = sm.handle(NormalizedKeyEvent(kind: .escape))
            var last: CandidatePanelSnapshot?
            for ch in text {
                let acts = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
                if let p = acts.compactMap({ act -> CandidatePanelSnapshot? in
                    if case .updateUI(let snap) = act { return snap }
                    return nil
                }).last {
                    last = p
                }
            }
            return last
        }

        let shaighaiPanel = typeAndGetPanel("shaighai")
        XCTAssertEqual(shaighaiPanel?.candidates.first?.text, "上海", "Real Rime shaighai got \(shaighaiPanel?.candidates.map(\.text) ?? [])")
        XCTAssertEqual(shaighaiPanel?.candidates.first?.source, .typoCorrected)

        let shanhaiPanel = typeAndGetPanel("shanhai")
        let shanhaiTop3 = shanhaiPanel?.candidates.prefix(3).map(\.text) ?? []
        XCTAssertTrue(shanhaiTop3.contains("山海") && shanhaiTop3.contains("上海"), "Real Rime shanhai top3 got \(shanhaiTop3)")

        let dupPanel = typeAndGetPanel("shanghaii")
        XCTAssertEqual(dupPanel?.candidates.first?.text, "上海", "Real Rime shanghaii got \(dupPanel?.candidates.map(\.text) ?? [])")

        let omitPanel = typeAndGetPanel("shnghai")
        XCTAssertEqual(omitPanel?.candidates.first?.text, "上海", "Real Rime shnghai got \(omitPanel?.candidates.map(\.text) ?? [])")

        let beijngPanel = typeAndGetPanel("beijng")
        XCTAssertEqual(beijngPanel?.candidates.first?.text, "北京", "Real Rime beijng got \(beijngPanel?.candidates.map(\.text) ?? [])")

        let womnePanel = typeAndGetPanel("womne")
        XCTAssertEqual(womnePanel?.candidates.first?.text, "我们", "Real Rime womne got \(womnePanel?.candidates.map(\.text) ?? [])")

        let shenemPanel = typeAndGetPanel("shenem")
        XCTAssertEqual(shenemPanel?.candidates.first?.text, "什么", "Real Rime shenem got \(shenemPanel?.candidates.map(\.text) ?? [])")

        let zhognguoPanel = typeAndGetPanel("zhognguo")
        XCTAssertEqual(zhognguoPanel?.candidates.first?.text, "中国", "Real Rime zhognguo got \(zhognguoPanel?.candidates.map(\.text) ?? [])")

        let cleanPanel = typeAndGetPanel("nihaoshijie")
        XCTAssertEqual(cleanPanel?.candidates.first?.text, "你好世界", "Real Rime nihaoshijie got \(cleanPanel?.candidates.map(\.text) ?? [])")
    }
}
