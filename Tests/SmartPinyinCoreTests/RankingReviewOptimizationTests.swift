import Foundation
import LocalInferenceCore
import PinyinEngineCore
import SharedIPC
import SmartPinyinCore
import XCTest

/// 模拟支持多页翻页与 Top-16 深层候选池的引擎，用于验证 P0/P1/P2 排序修复
private final class DeepPoolMockEngine: PinyinEngineProtocol {
    var buffer = ""
    var pages: [[String]] = [
        ["审美", "什么", "神秘", "神庙", "神明", "神魔", "参谋"],
        ["生母", "声母", "深谋", "申明", "圣母", "身梦", "神木"]
    ]
    var pageNo = 0
    var highlightedIndex = 0
    var lastSelectedPageIndex: Int?
    var lastSelectedGlobalIndex: Int?

    func processKey(keyval: Int32, mask: Int32) -> (handled: Bool, snapshot: PinyinEngineSnapshot) {
        if keyval == 0xff08 {
            guard !buffer.isEmpty else { return (false, .idle) }
            buffer.removeLast()
            pageNo = 0
            highlightedIndex = 0
            return (true, currentSnapshot())
        }
        guard let scalar = UnicodeScalar(UInt32(keyval)) else { return (false, currentSnapshot()) }
        let ch = Character(scalar)
        if ch.isLetter {
            buffer.append(ch.lowercased())
            pageNo = 0
            highlightedIndex = 0
            return (true, currentSnapshot())
        }
        return (false, currentSnapshot())
    }

    func selectCandidateOnCurrentPage(index: Int) -> PinyinEngineSnapshot {
        lastSelectedPageIndex = index
        let page = pages[min(pageNo, pages.count - 1)]
        guard page.indices.contains(index) else { return currentSnapshot() }
        let chosen = page[index]
        buffer = ""
        pageNo = 0
        highlightedIndex = 0
        return PinyinEngineSnapshot(isComposing: false, committedText: chosen)
    }

    func selectCandidate(globalIndex: Int) -> PinyinEngineSnapshot {
        lastSelectedGlobalIndex = globalIndex
        let flat = pages.flatMap { $0 }
        guard flat.indices.contains(globalIndex) else { return currentSnapshot() }
        let chosen = flat[globalIndex]
        buffer = ""
        pageNo = 0
        highlightedIndex = 0
        return PinyinEngineSnapshot(isComposing: false, committedText: chosen)
    }

    func changePage(forward: Bool) -> PinyinEngineSnapshot {
        if forward {
            pageNo = min(pages.count - 1, pageNo + 1)
        } else {
            pageNo = max(0, pageNo - 1)
        }
        highlightedIndex = 0
        return currentSnapshot()
    }

    func moveHighlight(delta: Int) -> PinyinEngineSnapshot {
        let count = pages[min(pageNo, pages.count - 1)].count
        highlightedIndex = max(0, min(count - 1, highlightedIndex + delta))
        return currentSnapshot()
    }

    func commitComposition() -> String? {
        let text = currentSnapshot().bestSentence
        buffer = ""
        return text.isEmpty ? nil : text
    }

    func clearComposition() {
        buffer = ""
        pageNo = 0
        highlightedIndex = 0
    }

    func currentSnapshot() -> PinyinEngineSnapshot {
        guard !buffer.isEmpty else { return .idle }
        let curPage = pages[min(pageNo, pages.count - 1)]
        let cands = curPage.enumerated().map { PinyinCandidate(index: $0.offset, text: $0.element) }
        var ext: [PinyinCandidate] = []
        if pageNo == 0 && pages.count > 1 {
            let base = curPage.count
            ext = pages[1].enumerated().map { PinyinCandidate(index: base + $0.offset, text: $0.element) }
        }
        return PinyinEngineSnapshot(
            isComposing: true,
            preedit: buffer,
            rawInput: buffer,
            candidates: cands,
            extendedCandidates: ext,
            highlightedIndex: highlightedIndex,
            pageNo: pageNo,
            hasNextPage: pageNo + 1 < pages.count
        )
    }
}

final class RankingReviewOptimizationTests: XCTestCase {
    private func makeTempDBURL(tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("smartpinyin-\(tag)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("user_memory.sqlite3")
    }

    // P0-1: 翻到第 2 页时不得重复注入首页记忆/文档词，也不应再触发 L2 神经重排
    func testSubsequentPageDoesNotReinjectFirstPageMemoryOrTriggerNeuralRerank() {
        let engine = DeepPoolMockEngine()
        let wm = SessionWorkingMemory()
        wm.finalizeCurrentSentence(
            explicitText: "系统问题出现在什么模块",
            appBundleID: "com.apple.Notes",
            isSecureInput: false
        )
        let doc = DocumentContextIndex()
        doc.updateDocument(text: "系统问题出现在什么模块，需要排查什么原因。", cursorOffset: 20)

        let sm = InputStateMachine(
            engine: engine,
            documentIndex: doc,
            workingMemory: wm
        )
        sm.updateRuntimeContext(leftContext: "系统问题出现在", appBundleID: "com.apple.Notes", isSecureInput: false)

        var page1Actions: [InputAction] = []
        for ch in "shenm" {
            page1Actions = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        let page1Snapshot = page1Actions.compactMap { action -> CandidatePanelSnapshot? in
            if case .updateUI(let snap) = action { return snap }
            return nil
        }.last
        XCTAssertEqual(page1Snapshot?.pageNo, 0)
        XCTAssertEqual(page1Snapshot?.candidates.first?.text, "什么")

        // 按 "=" 翻到第 2 页
        let page2Actions = sm.handle(NormalizedKeyEvent(kind: .character("=", keyCode: 24)))
        let page2Snapshot = page2Actions.compactMap { action -> CandidatePanelSnapshot? in
            if case .updateUI(let snap) = action { return snap }
            return nil
        }.last
        let requestedNeuralOnPage2 = page2Actions.contains { action in
            if case .requestNeuralEnhancement = action { return true }
            return false
        }

        XCTAssertEqual(page2Snapshot?.pageNo, 1)
        XCTAssertFalse(requestedNeuralOnPage2, "Page 2+ should not trigger redundant L2 neural rerank")
        XCTAssertEqual(
            page2Snapshot?.candidates.map(\.text),
            ["生母", "声母", "深谋", "申明", "圣母", "身梦", "神木"],
            "Page 2 should preserve pure Rime pagination without re-injecting Page 1 memory words"
        )
    }

    // P0-2: 低覆盖前缀不得触发独立合成注入，避免误吞多段拼音
    func testPartialPrefixDoesNotInjectSyntheticCandidateThatWipesLongPinyin() {
        let normalizer = PinyinNormalizer()
        let keys = normalizer.keys(forChineseTerm: "系统问题")

        // 2 字母 "xt" 只覆盖 4 字母简拼 "xtwt" 的 50%，允许增强已有 Rime 候选但不得 coversFullQuery 独立注入
        let shortInitMatch = PinyinNormalizer.matchChinese(query: "xt", keys: keys)
        XCTAssertGreaterThan(shortInitMatch.strength, 0)
        XCTAssertFalse(shortInitMatch.coversFullQuery)

        // 完整简拼 "xtwt" 与 3 字母简拼 "xtw"（75% 覆盖）允许作为整段匹配
        XCTAssertTrue(PinyinNormalizer.matchChinese(query: "xtwt", keys: keys).coversFullQuery)
        XCTAssertTrue(PinyinNormalizer.matchChinese(query: "xtw", keys: keys).coversFullQuery)

        // 极短 2 字母 "xi" 面对 12 字母全拼 "xitongwenti"（覆盖 16.7%）直接不匹配
        XCTAssertEqual(PinyinNormalizer.matchChinese(query: "xi", keys: keys).strength, 0)

        // 验证 CandidateFusionRanker 不会把 coversFullQuery == false 的长词硬注入到 "xt" 候选列表
        let wm = SessionWorkingMemory()
        wm.finalizeCurrentSentence(explicitText: "排查系统问题", appBundleID: "com.apple.Notes", isSecureInput: false)
        let ranker = CandidateFusionRanker()
        let ranked = ranker.rank(
            rimeCandidates: [
                PinyinCandidate(index: 0, text: "系统"),
                PinyinCandidate(index: 1, text: "心态")
            ],
            rawPinyin: "xt",
            leftContext: "排查",
            appBundleID: "com.apple.Notes",
            memoryStore: nil,
            documentIndex: nil,
            workingMemory: wm,
            preferences: .default,
            pageLimit: 7
        )
        XCTAssertEqual(ranked.first?.candidate.text, "系统")
        XCTAssertFalse(
            ranked.contains(where: { $0.candidate.text == "系统问题" && !$0.isRimeBacked }),
            "Partial prefix xt must not inject synthetic 4-char phrase 系统问题"
        )
    }

    // P0-3: 文档索引与工作记忆双命中时走去重包络（不再双倍爆炸）且保证至少 50% 槽位留给原生 Rime 候选
    func testContextEnvelopePreventsDoubleCountingExplosionAndRespectsSyntheticSlotBudget() {
        let doc = DocumentContextIndex()
        let wm = SessionWorkingMemory()
        let sentence = "排查系统问题出现在什么地方"
        doc.updateDocument(text: sentence, cursorOffset: sentence.count)
        wm.finalizeCurrentSentence(explicitText: sentence, appBundleID: "com.apple.Notes", isSecureInput: false)

        let ranker = CandidateFusionRanker()
        let ranked = ranker.rank(
            rimeCandidates: [
                PinyinCandidate(index: 0, text: "审美"),
                PinyinCandidate(index: 1, text: "什么"),
                PinyinCandidate(index: 2, text: "神秘"),
                PinyinCandidate(index: 3, text: "神庙"),
                PinyinCandidate(index: 4, text: "神明"),
                PinyinCandidate(index: 5, text: "神魔"),
                PinyinCandidate(index: 6, text: "参谋")
            ],
            rawPinyin: "shenm",
            leftContext: "系统问题出现在",
            appBundleID: "com.apple.Notes",
            memoryStore: nil,
            documentIndex: doc,
            workingMemory: wm,
            preferences: .default,
            pageLimit: 7
        )
        let top = try! XCTUnwrap(ranked.first(where: { $0.candidate.text == "什么" }))
        // 去重包络后，若 doc 和 work 同时命中，较弱方应折减至 0.20x，总分远低于未去重时的 14+ 爆炸值
        XCTAssertLessThan(top.score, 10.5, "Deduplicated context envelope should prevent >10.5 double-counting explosion, got \(top.score)")

        // 槽位预算：即使内存中有大量可注入词，7 项页中合成注入最多占 3 槽，至少 4 槽保留给 Rime 原生候选
        let docMany = DocumentContextIndex()
        docMany.updateDocument(
            text: "AlphaCode BetaCore GammaSync DeltaNode EchoFlow",
            cursorOffset: 47
        )
        let rimeSeven = (0..<7).map { PinyinCandidate(index: $0, text: "词\($0)") }
        let dbURL = makeTempDBURL(tag: "slot-budget")
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let mem = UserMemoryStore(databaseURL: dbURL)
        for extra in ["自造甲", "自造乙", "自造丙"] {
            for _ in 0..<3 {
                mem.recordSelection(
                    pinyin: "alp",
                    chosenWord: extra,
                    selectedRank: 0,
                    skippedTopWord: nil,
                    chosenFeatures: nil,
                    skippedTopFeatures: nil,
                    leftContext: "",
                    appBundleID: "com.apple.Notes",
                    isSecureInput: false
                )
            }
        }
        let capped = ranker.rank(
            rimeCandidates: rimeSeven,
            rawPinyin: "alp",
            leftContext: "",
            appBundleID: "com.apple.Notes",
            memoryStore: mem,
            documentIndex: docMany,
            workingMemory: nil,
            preferences: .default,
            pageLimit: 7
        )
        let syntheticCount = capped.filter { !$0.isRimeBacked }.count
        let rimeCount = capped.filter(\.isRimeBacked).count
        XCTAssertLessThanOrEqual(syntheticCount, 3, "Synthetic injections should be capped at 3 on a 7-item page")
        XCTAssertGreaterThanOrEqual(rimeCount, 4, "At least 4 native Rime slots must remain on a 7-item page")
    }

    // P1-1: 用户按方向键移动高亮后，异步到达的 L2 重排必须冻结，不得抢光标
    func testAsyncNeuralRerankFrozenWhenUserNavigatesManually() {
        let engine = DeepPoolMockEngine()
        let sm = InputStateMachine(engine: engine)
        sm.updateRuntimeContext(leftContext: "这个问题出现在", appBundleID: "com.apple.Notes", isSecureInput: false)

        var token: UInt64 = 0
        for ch in "shenm" {
            let acts = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
            for a in acts {
                if case .requestNeuralEnhancement(let t, _, _, _, _) = a {
                    token = t
                }
            }
        }
        XCTAssertGreaterThan(token, 0)

        // 用户手动按 ↓ 选中第 2 项（highlightedIndex = 1）
        _ = sm.handle(NormalizedKeyEvent(kind: .arrowDown))

        // 此时 40ms 前发出的 L2 回调到达，必须返回 nil 冻结排序
        let lateMerge = sm.applyRerankedScores([
            ScoredCandidate(text: "神秘", score: -0.5),
            ScoredCandidate(text: "审美", score: -9.0)
        ], forToken: token)
        XCTAssertNil(lateMerge, "Async L2 rerank must be frozen once user moves highlight manually")
    }

    // P1-1 防抖滞后 + P1-2 尾部锚定、低方差衰减与 10 维 neuralContext 闭环自学习
    func testMergeNeuralScoresFixesUnscoredTailBiasDampensFlatSpreadAppliesHysteresisAndClosesLearningLoop() {
        let ranker = CandidateFusionRanker()
        let base = [
            RankedCandidateItem(candidate: PinyinCandidate(index: 0, text: "甲"), originalRimeIndex: 0, features: CandidateFeatureVector(rimePrior: 2.40), score: 2.40),
            RankedCandidateItem(candidate: PinyinCandidate(index: 1, text: "乙"), originalRimeIndex: 1, features: CandidateFeatureVector(rimePrior: 1.85), score: 1.85),
            RankedCandidateItem(candidate: PinyinCandidate(index: 2, text: "丙"), originalRimeIndex: 2, features: CandidateFeatureVector(rimePrior: 1.52), score: 1.52),
            RankedCandidateItem(candidate: PinyinCandidate(index: 3, text: "丁"), originalRimeIndex: 3, features: CandidateFeatureVector(rimePrior: 1.30), score: 1.30)
        ]

        // 1. 超时截断仅算完前 2 项（甲、乙），未打分的「丙」「丁」不得拿到 0.0 反超被评负分的「乙」
        let partialScored = [
            ScoredCandidate(text: "甲", score: -2.0),
            ScoredCandidate(text: "乙", score: -3.2)
        ]
        let partialMerged = ranker.mergeNeuralScores(base: base, scoredCandidates: partialScored, neuralWeight: 0.85)
        let yiPos = partialMerged.firstIndex(where: { $0.candidate.text == "乙" })!
        let bingPos = partialMerged.firstIndex(where: { $0.candidate.text == "丙" })!
        XCTAssertLessThan(yiPos, bingPos, "Unscored tail candidate 丙 must not leapfrog scored candidate 乙")
        // 且写回了 neuralContextScore 特征
        XCTAssertGreaterThan(partialMerged[0].features.neuralContextScore, 0)
        XCTAssertLessThan(partialMerged[bingPos].features.neuralContextScore, partialMerged[yiPos].features.neuralContextScore)

        // 2. 低区分度（所有分数几乎一样，spread = 0.08）叠加防抖滞后阈值 0.35，不应轻易把第 1 位换掉
        let flatScored = [
            ScoredCandidate(text: "甲", score: -4.08),
            ScoredCandidate(text: "乙", score: -4.00)
        ]
        let flatMerged = ranker.mergeNeuralScores(base: base, scoredCandidates: flatScored, neuralWeight: 0.85)
        XCTAssertEqual(flatMerged.first?.candidate.text, "甲", "Flat spread neural scores must not flip top candidate")

        // 3. 10 维闭环 Pairwise 学习：当 L2 把错词顶到第 1 位并被用户跳过，neuralContext 权重应下降并持久化进 SQLite
        let dbURL = makeTempDBURL(tag: "neural-weight")
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let store = UserMemoryStore(databaseURL: dbURL)
        let initialNeuralW = store.currentWeights().neuralContext
        store.recordSelection(
            pinyin: "cs",
            chosenWord: "乙",
            selectedRank: 1,
            skippedTopWord: "甲",
            chosenFeatures: CandidateFeatureVector(rimePrior: 1.85, neuralContextScore: -0.9),
            skippedTopFeatures: CandidateFeatureVector(rimePrior: 2.40, neuralContextScore: 1.2),
            leftContext: "测试",
            appBundleID: "com.apple.Notes",
            isSecureInput: false
        )
        store.flush()
        let updatedNeuralW = store.currentWeights().neuralContext
        XCTAssertLessThan(updatedNeuralW, initialNeuralW, "Skipping L2-boosted top candidate should decrease neuralContext weight")

        let reopened = UserMemoryStore(databaseURL: dbURL)
        XCTAssertEqual(reopened.currentWeights().neuralContext, updatedNeuralW, accuracy: 1e-6)
    }

    // P1-3: 4 秒内连续退格删词应同步降权 UserMemoryStore、learned_phrases 与 SessionWorkingMemory
    func testUndoRegretPropagatesToWorkingMemoryAndLearnedPhrases() {
        let dbURL = makeTempDBURL(tag: "undo-sync")
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let store = UserMemoryStore(databaseURL: dbURL)
        let wm = SessionWorkingMemory()
        var fakeNow: TimeInterval = 1_700_000_000

        let engine = DeepPoolMockEngine()
        engine.pages = [["审美", "什么"], ["生母"]]
        let sm = InputStateMachine(
            engine: engine,
            memoryStore: store,
            workingMemory: wm,
            clock: { fakeNow }
        )
        sm.updateRuntimeContext(leftContext: "问题出现在", appBundleID: "com.apple.Notes", isSecureInput: false)

        // 先手动模拟一个已沉淀的误造短语
        store.recordLearnedPhrase(phrase: "审美", fullPinyin: "shenmei", initials: "sm", isSecureInput: false, now: fakeNow)
        XCTAssertEqual(store.stats().learnedPhrases, 1)

        // 打 shenm 并空格误上屏第 1 项「审美」
        for ch in "shenm" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        _ = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertGreaterThan(wm.stats().chineseTermCount, 0)

        // 1 秒后连按 2 次 Backspace 删掉「审美」触发退格撤销联动
        fakeNow += 1.0
        _ = sm.handle(NormalizedKeyEvent(kind: .backspace))
        _ = sm.handle(NormalizedKeyEvent(kind: .backspace))
        store.flush()

        // 验证工作记忆中的「审美」已被清除，且长期 learned_phrases 同步降权删除
        let wmAfter = wm.match(
            rawPinyin: "shenm",
            leftContext: "问题出现在",
            appBundleID: "com.apple.Notes",
            includeEnglish: true,
            shareAcrossApps: true,
            now: fakeNow + 1
        )
        XCTAssertFalse(wmAfter.contains(where: { $0.text == "审美" }), "Undo regret must evict wrong word from SessionWorkingMemory")
        XCTAssertEqual(store.stats().learnedPhrases, 0, "Undo regret must demote/delete undone learned phrase")
    }

    // P1-4: Top-16 深层召回池无损捞起第 2 页词到第 1 页，选中走 selectCandidate(globalIndex:)，翻到第 2 页自动去重
    func testDeepPoolTop16RescuesSecondPageCandidateLosslesslyAndDeduplicatesPage2() {
        let dbURL = makeTempDBURL(tag: "deep-pool")
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let store = UserMemoryStore(databaseURL: dbURL)

        // 让原本在第 2 页第 2 位（globalIndex = 8）的「声母」具备高个人偏好
        for i in 0..<4 {
            store.recordSelection(
                pinyin: "shenm",
                chosenWord: "声母",
                selectedRank: 0,
                skippedTopWord: nil,
                chosenFeatures: nil,
                skippedTopFeatures: nil,
                leftContext: "拼音",
                appBundleID: "com.apple.Notes",
                isSecureInput: false,
                now: 1_700_000_000 + Double(i)
            )
        }

        let engine = DeepPoolMockEngine()
        let sm = InputStateMachine(engine: engine, memoryStore: store)
        sm.updateRuntimeContext(leftContext: "拼音", appBundleID: "com.apple.Notes", isSecureInput: false)

        var lastSnap: CandidatePanelSnapshot?
        for ch in "shenm" {
            let acts = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
            if let s = acts.compactMap({ act -> CandidatePanelSnapshot? in
                if case .updateUI(let p) = act { return p }
                return nil
            }).last {
                lastSnap = s
            }
        }

        // 「声母」应被从 Top-16 深层池捞上第 1 页首位
        XCTAssertEqual(lastSnap?.candidates.first?.text, "声母")

        // 翻到第 2 页时，「声母」已被首页捞起展示过，第 2 页应自动去重不重复显示
        let page2Acts = sm.handle(NormalizedKeyEvent(kind: .character("=", keyCode: 24)))
        let page2Snap = page2Acts.compactMap({ act -> CandidatePanelSnapshot? in
            if case .updateUI(let p) = act { return p }
            return nil
        }).last
        XCTAssertFalse(page2Snap?.candidates.contains(where: { $0.text == "声母" }) ?? true)

        // 翻回第 1 页并按 1 选中「声母」，应调用 engine.selectCandidate(globalIndex: 8) 无损选词！
        _ = sm.handle(NormalizedKeyEvent(kind: .character("-", keyCode: 27)))
        let commitActs = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        XCTAssertEqual(engine.lastSelectedGlobalIndex, 8)
        XCTAssertTrue(commitActs.contains(where: {
            if case .commitText(let text, _) = $0 { return text == "声母" }
            return false
        }))
    }

    // P2-1: RerankLRUCache 命中、拒绝缓存不完整截断结果、LRU 淘汰
    func testRerankLRUCacheStoresCompleteScoresSkipsPartialAndEvictsLRU() {
        let cache = RerankLRUCache(capacity: 16)
        let cands = ["什么", "审美", "神秘"]
        let partial = [ScoredCandidate(text: "什么", score: -1.0)]
        cache.set(contextPrefix: "出现在", candidates: cands, scored: partial)
        XCTAssertNil(cache.get(contextPrefix: "出现在", candidates: cands), "Incomplete timeout scores must not be cached")

        let complete = [
            ScoredCandidate(text: "什么", score: -1.2),
            ScoredCandidate(text: "审美", score: -5.4),
            ScoredCandidate(text: "神秘", score: -4.0)
        ]
        cache.set(contextPrefix: "出现在", candidates: cands, scored: complete)
        XCTAssertEqual(cache.get(contextPrefix: "出现在", candidates: cands), complete)

        // 填满超过 16 项验证最久未使用的条目被淘汰
        for i in 0..<20 {
            cache.set(
                contextPrefix: "语境\(i)",
                candidates: ["甲", "乙"],
                scored: [ScoredCandidate(text: "甲", score: -1), ScoredCandidate(text: "乙", score: -2)]
            )
        }
        XCTAssertEqual(cache.count, 16)
        XCTAssertNil(cache.get(contextPrefix: "出现在", candidates: cands))
    }

    // P2-2: recentTopicContext 跨应用时效收紧（3 分钟）与无关长左文防污染门控
    func testRecentTopicContextCrossAppRecencyAndRelevanceGating() {
        let wm = SessionWorkingMemory()
        var now: TimeInterval = 1_700_000_000

        wm.finalizeCurrentSentence(
            explicitText: "我们需要修复本地缓存污染和索引重建问题",
            appBundleID: "com.t3tools.t3code",
            isSecureInput: false,
            now: now
        )

        // 2 分钟后切到微信聊完全无关的新话题（左文 >= 8 字，无词面重叠）-> 应被拦截，不污染 Qwen3
        now += 120
        let unrelatedTopic = wm.recentTopicContext(
            forApp: "com.tencent.xinWeChat",
            shareAcrossApps: true,
            currentLeftContext: "今晚下班后一起去吃火锅吧",
            maxChars: 36,
            now: now
        )
        XCTAssertTrue(unrelatedTopic.isEmpty, "Unrelated cross-app topic after 90s must be gated out, got: \(unrelatedTopic)")

        // 但若左文包含相关词面（「缓存污染」），仍在 3 分钟窗口内则允许召回
        let relatedTopic = wm.recentTopicContext(
            forApp: "com.tencent.xinWeChat",
            shareAcrossApps: true,
            currentLeftContext: "刚才讨论的缓存污染怎么处理",
            maxChars: 36,
            now: now
        )
        XCTAssertFalse(relatedTopic.isEmpty, "Lexically related cross-app topic within 3 min should be preserved")

        // 超过 3 分钟后跨应用过期，但同应用 10 分钟内仍有效
        now += 120 // 共 4 分钟
        XCTAssertTrue(
            wm.recentTopicContext(
                forApp: "com.tencent.xinWeChat",
                shareAcrossApps: true,
                currentLeftContext: "缓存污染",
                maxChars: 36,
                now: now
            ).isEmpty
        )
        XCTAssertFalse(
            wm.recentTopicContext(
                forApp: "com.t3tools.t3code",
                shareAcrossApps: true,
                currentLeftContext: "继续排查",
                maxChars: 36,
                now: now
            ).isEmpty
        )
    }
}
