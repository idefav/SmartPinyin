import PinyinEngineCore
import SharedIPC
import SmartPinyinCore
import XCTest

/// 轻量假拼音引擎，用于快速、确定性地测试状态机的所有按键语义与防竞态逻辑
private final class MockPinyinEngine: PinyinEngineProtocol {
    var buffer = ""
    var dictionary: [String: [String]] = [
        "nh": ["你好", "女孩", "农行"],
        "zgr": ["中国人", "主干人"],
        "wsm": ["为什么", "微商买"],
        "wo": ["我", "握"],
        "quchifan": ["去吃饭", "去吃晚饭"],
        "woxiangquchifan": ["我想去吃饭", "我想去吃晚饭"]
    ]
    var highlightedIndex = 0
    var selectedIndicesHistory: [Int] = []

    func processKey(keyval: Int32, mask: Int32) -> (handled: Bool, snapshot: PinyinEngineSnapshot) {
        if keyval == 0xff08 { // BackSpace
            guard !buffer.isEmpty else { return (false, .idle) }
            buffer.removeLast()
            highlightedIndex = 0
            return (true, currentSnapshot())
        }
        guard let scalar = UnicodeScalar(UInt32(keyval)) else {
            return (false, currentSnapshot())
        }
        let ch = Character(scalar)
        if ch.isLetter {
            buffer.append(ch.lowercased())
            highlightedIndex = 0
            return (true, currentSnapshot())
        }
        return (false, currentSnapshot())
    }

    func selectCandidateOnCurrentPage(index: Int) -> PinyinEngineSnapshot {
        selectedIndicesHistory.append(index)
        let snap = currentSnapshot()
        guard snap.candidates.indices.contains(index) else { return snap }
        let chosen = snap.candidates[index].text
        buffer = ""
        highlightedIndex = 0
        return PinyinEngineSnapshot(isComposing: false, committedText: chosen)
    }

    func changePage(forward: Bool) -> PinyinEngineSnapshot {
        currentSnapshot()
    }

    func moveHighlight(delta: Int) -> PinyinEngineSnapshot {
        let count = currentSnapshot().candidates.count
        guard count > 0 else { return currentSnapshot() }
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
        highlightedIndex = 0
    }

    func currentSnapshot() -> PinyinEngineSnapshot {
        guard !buffer.isEmpty else { return .idle }
        let texts = dictionary[buffer] ?? [buffer]
        let candidates = texts.enumerated().map { idx, t in
            PinyinCandidate(index: idx, text: t)
        }
        return PinyinEngineSnapshot(
            isComposing: true,
            preedit: buffer,
            rawInput: buffer,
            candidates: candidates,
            highlightedIndex: highlightedIndex
        )
    }
}

final class InputStateMachineTests: XCTestCase {
    func testFixedTranslateHotkeysDisabledByDefaultAndOptInWorks() {
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine)
        XCTAssertFalse(sm.preferences.enableTranslateHotkeys)

        // 默认关闭固定快捷键，Option+T / Option+L 必须完全放行给宿主 App
        let optT = sm.handle(NormalizedKeyEvent(kind: .character("t", keyCode: 17), modifiers: [.option]))
        XCTAssertEqual(optT, [.passThrough])
        XCTAssertEqual(sm.mode, .chinesePinyin)

        let optL = sm.handle(NormalizedKeyEvent(kind: .character("l", keyCode: 37), modifiers: [.option]))
        XCTAssertEqual(optL, [.passThrough])
        XCTAssertEqual(sm.preferredTargetLanguage, .english)

        // 在设置中显式开启可选快捷键后，Option+T / Option+L 才生效
        var prefs = SmartPinyinPreferences.default
        prefs.enableTranslateHotkeys = true
        sm.applyPreferences(prefs)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("t", keyCode: 17), modifiers: [.option]))
        XCTAssertEqual(sm.mode, .translateOnCommit(.english))
        _ = sm.handle(NormalizedKeyEvent(kind: .character("l", keyCode: 37), modifiers: [.option]))
        XCTAssertEqual(sm.mode, .translateOnCommit(.japanese))
    }

    func testPlanBTranslateModeShowsTranslationBarAndCommitsTranslationOnSpace() {
        let engine = MockPinyinEngine()
        var prefs = SmartPinyinPreferences.default
        prefs.defaultTranslateMode = true
        let sm = InputStateMachine(engine: engine, preferences: prefs)
        XCTAssertEqual(sm.mode, .translateOnCommit(.english))

        // 输入拼音 "woxiangquchifan"
        var lastToken: UInt64 = 0
        var lastPanel: CandidatePanelSnapshot?
        for ch in "woxiangquchifan" {
            let actions = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
            for act in actions {
                if case .updateUI(let panel) = act { lastPanel = panel }
                if case .requestNeuralEnhancement(let token, _, _, _, let target) = act {
                    lastToken = token
                    XCTAssertEqual(target, .english)
                }
            }
        }
        // 弹窗必须自动展示独立翻译栏与待译中文原文
        XCTAssertEqual(lastPanel?.showTranslationBar, true)
        XCTAssertEqual(lastPanel?.translationSourcePreview, "我想去吃饭")

        // 模拟后台实时译文返回并展示在翻译栏中
        let previewAction = sm.applyTranslationPreview(
            .ready(
                sourceText: "我想去吃饭",
                translatedText: "I want to go eat.",
                target: .english,
                latencyMs: 92
            ),
            modelLabel: "HY-MT1.5-1.8B",
            forToken: lastToken
        )
        guard case .updateUI(let readyPanel) = previewAction else {
            return XCTFail("Expected translation bar UI update")
        }
        XCTAssertTrue(readyPanel.showTranslationBar)
        XCTAssertEqual(readyPanel.translationPreview, .ready(
            sourceText: "我想去吃饭",
            translatedText: "I want to go eat.",
            target: .english,
            latencyMs: 92
        ))

        // 方案 B：按空格直接命中缓存 0ms 上屏译文！
        let spaceActions = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(spaceActions.contains(.commitTranslation(
            sourceText: "我想去吃饭",
            target: .english,
            cachedTranslation: "I want to go eat."
        )))
    }

    func testPlanBNumberKeyCorrectsChineseWithoutPrematureCommit() {
        let engine = MockPinyinEngine()
        var prefs = SmartPinyinPreferences.default
        prefs.defaultTranslateMode = true
        let sm = InputStateMachine(engine: engine, preferences: prefs)

        // 输入 "woxiangquchifan"，按数字键 2 纠正为「我想去吃晚饭」
        for ch in "woxiangquchifan" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        let pickActions = sm.handle(NormalizedKeyEvent(kind: .character("2", keyCode: 0)))
        // 绝不提前上屏中文，而是写入待译中文缓冲并立即触发更新后的实时译文
        XCTAssertFalse(pickActions.contains(where: { if case .commitText = $0 { return true }; return false }))

        var updatedToken: UInt64 = 0
        var updatedPanel: CandidatePanelSnapshot?
        for act in pickActions {
            if case .updateUI(let panel) = act { updatedPanel = panel }
            if case .requestNeuralEnhancement(let token, _, let sentence, _, let target) = act {
                updatedToken = token
                XCTAssertEqual(sentence, "我想去吃晚饭")
                XCTAssertEqual(target, .english)
            }
        }
        XCTAssertEqual(updatedPanel?.showTranslationBar, true)
        XCTAssertEqual(updatedPanel?.translationSourcePreview, "我想去吃晚饭")

        // 译文展示出来后，按空格直接上屏修正后的英文译文
        _ = sm.applyTranslationPreview(
            .ready(sourceText: "我想去吃晚饭", translatedText: "I want to go have dinner.", target: .english, latencyMs: 85),
            forToken: updatedToken
        )
        let commitActions = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(commitActions.contains(.commitTranslation(
            sourceText: "我想去吃晚饭",
            target: .english,
            cachedTranslation: "I want to go have dinner."
        )))
    }

    func testTranslateModeShiftReturnCommitsOriginalChinese() {
        let engine = MockPinyinEngine()
        var prefs = SmartPinyinPreferences.default
        prefs.defaultTranslateMode = true
        let sm = InputStateMachine(engine: engine, preferences: prefs)

        for ch in "nh" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        let actions = sm.handle(NormalizedKeyEvent(kind: .returnKey, modifiers: [.shift]))
        XCTAssertTrue(actions.contains(.commitText(text: "你好", requestPredictions: true)))
    }

    func testRerankedSelectionSyncsOriginalRimeIndexBackToEngine() {
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine)
        for ch in "nh" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        // Rime 原顺序为 [0: 你好, 1: 女孩, 2: 农行]，重排后把「农行」置顶到显示位 0
        _ = sm.applyRerankedCandidates(["农行", "你好", "女孩"], forToken: sm.sessionToken)

        // 用户按空格选中显示位 0（农行） -> 传给 Rime 的必须是原始索引 2，确保 wanxiang.userdb 正确学习！
        let actions = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertEqual(engine.selectedIndicesHistory.last, 2)
        XCTAssertTrue(actions.contains(.commitText(text: "农行", requestPredictions: true)))
    }

    func testFourSecondBackspaceUndoRecordsRegretIntoMemoryStore() {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smartpinyin-undo-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("user_memory.sqlite3")
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        var fakeNow: TimeInterval = 1_700_000_000
        let store = UserMemoryStore(databaseURL: dbURL)
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine, memoryStore: store, clock: { fakeNow })

        // 输入 nh 并按空格误上屏 2 字词「你好」
        for ch in "nh" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        _ = sm.handle(NormalizedKeyEvent(kind: .space))

        // 1.5 秒内连按 2 次退格删光「你好」
        fakeNow += 1.0
        XCTAssertEqual(sm.handle(NormalizedKeyEvent(kind: .backspace)), [.passThrough])
        fakeNow += 0.5
        XCTAssertEqual(sm.handle(NormalizedKeyEvent(kind: .backspace)), [.passThrough])

        let sig = store.lookupSignals(pinyin: "nh", word: "你好", leftContext: "", appBundleID: "", now: fakeNow)
        XCTAssertGreaterThan(sig.regretPenalty, 0.5, "Expected backspace undo regret penalty > 0.5")
    }

    func testStaleTokenRerankIsDropped() {
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine)

        _ = sm.handle(NormalizedKeyEvent(kind: .character("n", keyCode: 0)))
        let staleToken = sm.sessionToken
        _ = sm.handle(NormalizedKeyEvent(kind: .character("h", keyCode: 0)))

        let ignored = sm.applyRerankedCandidates(["农行", "你好"], forToken: staleToken)
        XCTAssertNil(ignored)

        let applied = sm.applyRerankedCandidates(["农行", "你好", "女孩"], forToken: sm.sessionToken)
        guard case .updateUI(let snap) = applied else {
            return XCTFail("Expected UI update")
        }
        XCTAssertEqual(snap.candidates.first?.text, "农行")
        XCTAssertEqual(snap.candidates.first?.source, .neuralReranked)
    }

    func testShiftReturnTranslatesInNormalChineseMode() {
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine)
        for ch in "nh" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        let actions = sm.handle(NormalizedKeyEvent(kind: .returnKey, modifiers: [.shift]))
        XCTAssertTrue(actions.contains(.commitTranslation(
            sourceText: "你好",
            target: .english,
            cachedTranslation: nil
        )))
    }

    func testInlineLanguagePrefixSwitchesTargetForSingleSentence() {
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine)

        _ = sm.handle(NormalizedKeyEvent(kind: .character("/", keyCode: 0)))
        _ = sm.handle(NormalizedKeyEvent(kind: .character("j", keyCode: 0)))
        _ = sm.handle(NormalizedKeyEvent(kind: .character("a", keyCode: 0)))
        _ = sm.handle(NormalizedKeyEvent(kind: .space))
        for ch in "nh" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        let actions = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(actions.contains(.commitTranslation(
            sourceText: "你好",
            target: .japanese,
            cachedTranslation: nil
        )))
    }

    func testTabAcceptsNeuralPredictionAfterCommit() {
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine)

        for ch in "nh" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        _ = sm.handle(NormalizedKeyEvent(kind: .space))

        let token = sm.sessionToken
        let uiUpdate = sm.applyPredictions(["，请问有什么可以帮您？", "，最近怎么样？"], forToken: token)
        XCTAssertNotNil(uiUpdate)

        let tabActions = sm.handle(NormalizedKeyEvent(kind: .tab))
        XCTAssertTrue(tabActions.contains(.commitText(text: "，请问有什么可以帮您？", requestPredictions: true)))
    }

    func testPassThroughKeysDismissPredictionPanel() {
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine)

        for ch in "nh" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        _ = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertNotNil(sm.applyPredictions(["，没问题。"], forToken: sm.sessionToken))

        let bsActions = sm.handle(NormalizedKeyEvent(kind: .backspace))
        XCTAssertEqual(bsActions, [.updateUI(.empty), .passThrough])

        XCTAssertNotNil(sm.applyPredictions(["，好的。"], forToken: sm.sessionToken))
        let cmdActions = sm.handle(NormalizedKeyEvent(kind: .character("a", keyCode: 0), modifiers: [.command]))
        XCTAssertEqual(cmdActions, [.updateUI(.empty), .passThrough])

        XCTAssertNotNil(sm.applyPredictions(["，马上到。"], forToken: sm.sessionToken))
        let escActions = sm.handle(NormalizedKeyEvent(kind: .escape))
        XCTAssertEqual(escActions, [.updateUI(.empty)])
    }

    func testContextTrackerRespectsSecureInput() {
        let tracker = ContextTracker(maxLength: 32)
        tracker.switchClient(identifier: "com.apple.Safari")
        tracker.recordCommitted("今天下午三点", isSecureInput: false)
        XCTAssertEqual(tracker.resolveLeftContext(isSecureInput: false), "今天下午三点")

        tracker.recordCommitted("my-secret-password", isSecureInput: true)
        XCTAssertEqual(tracker.resolveLeftContext(isSecureInput: true), "")
        XCTAssertEqual(tracker.resolveLeftContext(isSecureInput: false), "今天下午三点")
    }

    func testPreferencesPersistenceAndLiveStateMachineBehavior() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smartpinyin-prefs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var prefs = SmartPinyinPreferences.default
        prefs.candidatePageSize = 9
        prefs.candidateFontSize = 17
        prefs.returnKeyBehavior = .commitFirstCandidate
        prefs.enableContinuationPrediction = false
        prefs.shiftReturnQuickTranslate = false
        prefs.inlineLanguagePrefixEnabled = false
        prefs.defaultTargetLanguage = .japanese
        prefs.enablePersonalMemory = false
        prefs.enableDocumentContextAssist = false
        prefs.enableDocumentEnglishTokens = false
        prefs.enableTranslateHotkeys = true

        SmartPinyinPreferencesStore.save(prefs, baseDirectory: tmpDir, postNotification: false)
        let loaded = SmartPinyinPreferencesStore.load(baseDirectory: tmpDir)
        XCTAssertEqual(loaded, prefs)

        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine, preferences: loaded)
        XCTAssertEqual(sm.preferredTargetLanguage, .japanese)

        let slashActions = sm.handle(NormalizedKeyEvent(kind: .character("/", keyCode: 0)))
        XCTAssertEqual(slashActions, [.passThrough])

        for ch in "nh" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        let returnActions = sm.handle(NormalizedKeyEvent(kind: .returnKey, modifiers: [.shift]))
        XCTAssertTrue(returnActions.contains(.commitText(text: "你好", requestPredictions: false)))
    }

    func testUppercaseInlineEnglishWordAndIdentifierCommitsAndReturnsToChinese() {
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine)

        // 中文模式下直接打 T3 -> 空格上屏 T3 并无缝回到中文模式
        _ = sm.handle(NormalizedKeyEvent(kind: .character("T", keyCode: 0), modifiers: [.shift]))
        _ = sm.handle(NormalizedKeyEvent(kind: .character("3", keyCode: 0)))
        let commitT3 = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(commitT3.contains(.commitText(text: "T3", requestPredictions: false)))
        XCTAssertEqual(sm.mode, .chinesePinyin)
        XCTAssertFalse(sm.hasActiveComposition)

        // 继续打 App.tsx + 标点 ( -> 直接上屏 "App.tsx(" 并保持中文模式
        for ch in "App.tsx" {
            let mods: NormalizedKeyEvent.Modifiers = ch.isUppercase ? [.shift] : []
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0), modifiers: mods))
        }
        let commitWithParen = sm.handle(NormalizedKeyEvent(kind: .character("(", keyCode: 0), modifiers: [.shift]))
        XCTAssertTrue(commitWithParen.contains(.commitText(text: "App.tsx(", requestPredictions: false)))
        XCTAssertEqual(sm.mode, .chinesePinyin)

        // 紧接着直接打中文拼音 nh + Space -> 正常上屏中文「你好」
        for ch in "nh" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        let commitZh = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(commitZh.contains(.commitText(text: "你好", requestPredictions: true)))
    }

    func testCamelCaseAndSnakeCasePromotePinyinToInlineEnglish() {
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine)

        // 驼峰：useState（敲到 S 自动从拼音转为临时英文）
        for ch in "use" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        _ = sm.handle(NormalizedKeyEvent(kind: .character("S", keyCode: 0), modifiers: [.shift]))
        for ch in "tate" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        let camelCommit = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(camelCommit.contains(.commitText(text: "useState", requestPredictions: false)))
        XCTAssertEqual(sm.mode, .chinesePinyin)

        // 下划线：user_id（敲到 _ 自动转为临时英文）
        for ch in "user" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        _ = sm.handle(NormalizedKeyEvent(kind: .character("_", keyCode: 0), modifiers: [.shift]))
        for ch in "id" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        let snakeCommit = sm.handle(NormalizedKeyEvent(kind: .returnKey))
        XCTAssertTrue(snakeCommit.contains(.commitText(text: "user_id", requestPredictions: false)))
        XCTAssertEqual(sm.mode, .chinesePinyin)
    }

    func testShiftSpaceInlineEnglishPhraseAllowsSpacesAndReturnsToChineseOnReturn() {
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine)

        // 按 Shift+Space 进入临时英文短句模式，输入 "t3 code" 后回车上屏并自动回中文
        let openActions = sm.handle(NormalizedKeyEvent(kind: .space, modifiers: [.shift]))
        XCTAssertTrue(sm.hasActiveComposition)
        XCTAssertTrue(openActions.contains(where: { if case .updateUI = $0 { return true }; return false }))

        for ch in "t3 code" {
            if ch == " " {
                _ = sm.handle(NormalizedKeyEvent(kind: .space))
            } else {
                _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
            }
        }
        let commitActions = sm.handle(NormalizedKeyEvent(kind: .returnKey))
        XCTAssertTrue(commitActions.contains(.commitText(text: "t3 code", requestPredictions: false)))
        XCTAssertFalse(sm.hasActiveComposition)
        XCTAssertEqual(sm.mode, .chinesePinyin)

        // 也支持在拼写小写英文中途按 Shift+Space 续接空格（如 git + Shift+Space + status + Return）
        for ch in "git" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        _ = sm.handle(NormalizedKeyEvent(kind: .space, modifiers: [.shift]))
        for ch in "status" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        let gitCommit = sm.handle(NormalizedKeyEvent(kind: .returnKey))
        XCTAssertTrue(gitCommit.contains(.commitText(text: "git status", requestPredictions: false)))
    }

    func testInlineEnglishDocumentCompletionWithTabAndTargetLanguageSync() {
        let docIndex = DocumentContextIndex()
        docIndex.updateDocument(text: "我们正在优化 SmartPinyinInputController 和 CandidatePanel 的响应速度")
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine, documentIndex: docIndex)

        for ch in "Smart" {
            let mods: NormalizedKeyEvent.Modifiers = ch.isUppercase ? [.shift] : []
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0), modifiers: mods))
        }
        let completions = docIndex.matchEnglishCompletions(prefix: "Smart", maxResults: 4)
        XCTAssertEqual(completions, ["SmartPinyinInputController"])
        let tabCommit = sm.handle(NormalizedKeyEvent(kind: .tab))
        XCTAssertEqual(tabCommit, [.updateUI(.empty), .commitText(text: "SmartPinyinInputController", requestPredictions: false)])

        // 验证切换目标语言 + applyPreferences 同步生效（EN -> JA -> KO）
        var prefs = SmartPinyinPreferences.default
        prefs.defaultTranslateMode = true
        sm.applyPreferences(prefs)
        XCTAssertEqual(sm.mode, .translateOnCommit(.english))

        prefs.defaultTargetLanguage = .japanese
        sm.applyPreferences(prefs)
        XCTAssertEqual(sm.preferredTargetLanguage, .japanese)
        XCTAssertEqual(sm.mode, .translateOnCommit(.japanese))

        _ = sm.setTargetLanguage(.korean)
        XCTAssertEqual(sm.preferredTargetLanguage, .korean)
        XCTAssertEqual(sm.mode, .translateOnCommit(.korean))
    }

    func testComposingTabTogglesSingleSentenceTranslateAndShiftTabCyclesLanguage() {
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine)
        XCTAssertEqual(sm.mode, .chinesePinyin)

        // 普通中文模式下先敲 "nh"，再按 Tab -> 原地展开本句临时翻译栏（不改全局开关）
        for ch in "nh" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        let tabOpen = sm.handle(NormalizedKeyEvent(kind: .tab))
        XCTAssertTrue(tabOpen.contains(where: {
            if case .requestNeuralEnhancement(_, _, let sentence, _, let target) = $0 {
                return sentence == "你好" && target == .english
            }
            return false
        }))
        XCTAssertEqual(sm.mode, .chinesePinyin)

        // 拼写态按 Shift+Tab -> 原地切到日语 JA 并产出持久化指令 + 日语翻译请求
        let shiftTab = sm.handle(NormalizedKeyEvent(kind: .tab, modifiers: [.shift]))
        XCTAssertTrue(shiftTab.contains(.persistPreferencesChange(
            translateMode: nil,
            targetLanguage: .japanese,
            codingMode: nil,
            chinesePunctuation: nil
        )))
        XCTAssertTrue(shiftTab.contains(where: {
            if case .requestNeuralEnhancement(_, _, let sentence, _, let target) = $0 {
                return sentence == "你好" && target == .japanese
            }
            return false
        }))

        // 再按一次 Tab -> 收起本句临时翻译栏回到普通中文
        let tabClose = sm.handle(NormalizedKeyEvent(kind: .tab))
        XCTAssertTrue(tabClose.contains(.cancelPendingInference))
        let spaceCommit = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(spaceCommit.contains(.commitText(text: "你好", requestPredictions: true)))
    }

    func testLanguagePickerDirectNumberSelectAndEscCancel() {
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine)

        // 打开 1–6 语种直选条，按数字 3 直选韩语 KO
        let openActions = sm.openLanguagePicker()
        XCTAssertTrue(sm.isLanguagePickerVisible)
        XCTAssertTrue(openActions.contains(where: {
            if case .updateUI(let snap) = $0 { return snap.showLanguagePicker }
            return false
        }))

        let pick3 = sm.handle(NormalizedKeyEvent(kind: .character("3", keyCode: 0)))
        XCTAssertFalse(sm.isLanguagePickerVisible)
        XCTAssertEqual(sm.preferredTargetLanguage, .korean)
        XCTAssertTrue(pick3.contains(.persistPreferencesChange(
            translateMode: nil,
            targetLanguage: .korean,
            codingMode: nil,
            chinesePunctuation: nil
        )))

        // 再次打开后按 Esc 取消
        _ = sm.openLanguagePicker()
        XCTAssertTrue(sm.isLanguagePickerVisible)
        _ = sm.handle(NormalizedKeyEvent(kind: .escape))
        XCTAssertFalse(sm.isLanguagePickerVisible)
    }

    func testInlineSlashCommandsAndCodePathSafety() {
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine)

        // `/t ` 开关持久翻译模式
        _ = sm.handle(NormalizedKeyEvent(kind: .character("/", keyCode: 0)))
        _ = sm.handle(NormalizedKeyEvent(kind: .character("t", keyCode: 0)))
        let toggleTranslate = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertEqual(sm.mode, .translateOnCommit(.english))
        XCTAssertTrue(toggleTranslate.contains(.persistPreferencesChange(
            translateMode: true,
            targetLanguage: nil,
            codingMode: nil,
            chinesePunctuation: nil
        )))

        // `/code ` 开关全局 Coding 模式
        _ = sm.handle(NormalizedKeyEvent(kind: .character("/", keyCode: 0)))
        for ch in "code" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        let toggleCode = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(toggleCode.contains(.persistPreferencesChange(
            translateMode: nil,
            targetLanguage: nil,
            codingMode: true,
            chinesePunctuation: nil
        )))

        // 写代码注释 `//` 或大写路径 `/U` 不拦截，立刻原样提交
        _ = sm.handle(NormalizedKeyEvent(kind: .character("/", keyCode: 0)))
        let comment = sm.handle(NormalizedKeyEvent(kind: .character("/", keyCode: 0)))
        XCTAssertTrue(comment.contains(.commitText(text: "//", requestPredictions: false)))

        _ = sm.handle(NormalizedKeyEvent(kind: .character("/", keyCode: 0)))
        let macPath = sm.handle(NormalizedKeyEvent(kind: .character("U", keyCode: 0), modifiers: [.shift]))
        XCTAssertTrue(macPath.contains(.commitText(text: "/U", requestPredictions: false)))
    }

    func testSmartPunctuationInWeChatVsCodingModeInT3Code() {
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine)

        // 1. 微信（非 Coding App）：中英混输 "重启了" + T3 + "," -> "T3，"，空态 "!" -> "！"
        sm.updateRuntimeContext(leftContext: "重启了", appBundleID: "com.tencent.xinWeChat", isSecureInput: false)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("T", keyCode: 0), modifiers: [.shift]))
        _ = sm.handle(NormalizedKeyEvent(kind: .character("3", keyCode: 0)))
        let mixedComma = sm.handle(NormalizedKeyEvent(kind: .character(",", keyCode: 0)))
        XCTAssertTrue(mixedComma.contains(.commitText(text: "T3，", requestPredictions: false)))

        let idleBang = sm.handle(NormalizedKeyEvent(kind: .character("!", keyCode: 0), modifiers: [.shift]))
        XCTAssertEqual(idleBang, [.commitText(text: "！", requestPredictions: false)])

        // 2. T3 Code（自动 Coding App）：同样打 T3 + "," -> 半角 "T3,"，空态 "," -> passThrough 半角！
        sm.updateRuntimeContext(leftContext: "重启了", appBundleID: "com.t3tools.t3code", isSecureInput: false)
        XCTAssertTrue(sm.isEffectiveCodingMode)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("T", keyCode: 0), modifiers: [.shift]))
        _ = sm.handle(NormalizedKeyEvent(kind: .character("3", keyCode: 0)))
        let codingComma = sm.handle(NormalizedKeyEvent(kind: .character(",", keyCode: 0)))
        XCTAssertTrue(codingComma.contains(.commitText(text: "T3,", requestPredictions: false)))

        let codingIdleComma = sm.handle(NormalizedKeyEvent(kind: .character(",", keyCode: 0)))
        XCTAssertEqual(codingIdleComma, [.passThrough])
    }

    func testGlobalDisableTranslateShortcutTurnsOffPersistentTranslateInAnyMode() {
        let engine = MockPinyinEngine()
        var prefs = SmartPinyinPreferences.default
        prefs.defaultTranslateMode = true
        let sm = InputStateMachine(engine: engine, preferences: prefs)
        XCTAssertEqual(sm.mode, .translateOnCommit(.english))

        // 1. 拼写中途按 默认 ⌃⌥T：立即全局关闭翻译、持久化为 false，但保留正在敲的拼音！
        for ch in "nh" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        let disableMidType = sm.handle(NormalizedKeyEvent(
            kind: .character("t", keyCode: 17),
            modifiers: [.control, .option]
        ))
        XCTAssertEqual(sm.mode, .chinesePinyin)
        XCTAssertFalse(sm.preferences.defaultTranslateMode)
        XCTAssertTrue(disableMidType.contains(.persistPreferencesChange(
            translateMode: false,
            targetLanguage: nil,
            codingMode: nil,
            chinesePunctuation: nil
        )))
        XCTAssertTrue(sm.hasActiveComposition)
        // 按空格此时应直接上屏中文「你好」而非译文
        let spaceZh = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(spaceZh.contains(.commitText(text: "你好", requestPredictions: true)))

        // 2. 再次按 ⌃⌥T 绝不误开启翻译模式（始终保证全局关闭）
        let disableAgain = sm.handle(NormalizedKeyEvent(
            kind: .character("t", keyCode: 17),
            modifiers: [.control, .option]
        ))
        XCTAssertEqual(sm.mode, .chinesePinyin)
        XCTAssertFalse(sm.preferences.defaultTranslateMode)
        XCTAssertTrue(disableAgain.contains(.persistPreferencesChange(
            translateMode: false,
            targetLanguage: nil,
            codingMode: nil,
            chinesePunctuation: nil
        )))

        // 3. 即使在英文直出模式下，按 ⌃⌥T 也能全局关闭 defaultTranslateMode（切回中文时回到纯中文而非翻译模式）
        prefs.defaultTranslateMode = true
        sm.applyPreferences(prefs)
        _ = sm.handle(NormalizedKeyEvent(kind: .shiftTapToggle))
        XCTAssertEqual(sm.mode, .directEnglish)
        _ = sm.handle(NormalizedKeyEvent(
            kind: .character("t", keyCode: 17),
            modifiers: [.control, .option]
        ))
        XCTAssertFalse(sm.preferences.defaultTranslateMode)
        XCTAssertEqual(sm.mode, .directEnglish)
        _ = sm.handle(NormalizedKeyEvent(kind: .shiftTapToggle))
        XCTAssertEqual(sm.mode, .chinesePinyin)
    }

    func testComposingOptionTabAndDoubleTabToggleGlobalTranslate() {
        var fakeNow: TimeInterval = 1_700_000_000
        let engine = MockPinyinEngine()
        let sm = InputStateMachine(engine: engine, clock: { fakeNow })

        // 1. 空态按 Option+Tab 必须完全放行给宿主 App（零冲突）
        let idleOptTab = sm.handle(NormalizedKeyEvent(kind: .tab, modifiers: [.option]))
        XCTAssertEqual(idleOptTab, [.passThrough])
        XCTAssertEqual(sm.mode, .chinesePinyin)

        // 2. 拼写态慢按两次 Tab（间隔 0.6s > 0.32s）-> 仅本句展开再收起，不修改全局开关
        for ch in "nh" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        let firstTab = sm.handle(NormalizedKeyEvent(kind: .tab))
        XCTAssertTrue(firstTab.contains(where: {
            if case .updateUI(let snap) = $0 { return snap.showTranslationBar && !snap.isGlobalTranslateMode }
            return false
        }))
        fakeNow += 0.60
        _ = sm.handle(NormalizedKeyEvent(kind: .tab))
        XCTAssertEqual(sm.mode, .chinesePinyin)
        XCTAssertFalse(sm.preferences.defaultTranslateMode)

        // 3. 拼写态快速双击 Tab（间隔 0.18s <= 0.32s）-> 升格锁定为全局翻译开启！
        fakeNow += 1.0
        _ = sm.handle(NormalizedKeyEvent(kind: .tab))
        fakeNow += 0.18
        let doubleTabOn = sm.handle(NormalizedKeyEvent(kind: .tab))
        XCTAssertEqual(sm.mode, .translateOnCommit(.english))
        XCTAssertTrue(sm.preferences.defaultTranslateMode)
        XCTAssertTrue(doubleTabOn.contains(.persistPreferencesChange(
            translateMode: true,
            targetLanguage: nil,
            codingMode: nil,
            chinesePunctuation: nil
        )))
        XCTAssertTrue(doubleTabOn.contains(where: {
            if case .updateUI(let snap) = $0 { return snap.showTranslationBar && snap.isGlobalTranslateMode }
            return false
        }))

        // 4. 拼写态按 Option+Tab -> 确定性关闭全局翻译并保留拼音！
        let optTabOff = sm.handle(NormalizedKeyEvent(kind: .tab, modifiers: [.option]))
        XCTAssertEqual(sm.mode, .chinesePinyin)
        XCTAssertFalse(sm.preferences.defaultTranslateMode)
        XCTAssertTrue(optTabOff.contains(.persistPreferencesChange(
            translateMode: false,
            targetLanguage: nil,
            codingMode: nil,
            chinesePunctuation: nil
        )))
        XCTAssertTrue(sm.hasActiveComposition)

        // 5. 翻译栏「本句 / 全局」胶囊点击 toggleGlobalTranslateFromBar() 正常切换全局态
        let lockFromBar = sm.toggleGlobalTranslateFromBar()
        XCTAssertEqual(sm.mode, .translateOnCommit(.english))
        XCTAssertTrue(lockFromBar.contains(.persistPreferencesChange(
            translateMode: true,
            targetLanguage: nil,
            codingMode: nil,
            chinesePunctuation: nil
        )))
        let unlockFromBar = sm.toggleGlobalTranslateFromBar()
        XCTAssertEqual(sm.mode, .chinesePinyin)
        XCTAssertTrue(unlockFromBar.contains(.persistPreferencesChange(
            translateMode: false,
            targetLanguage: nil,
            codingMode: nil,
            chinesePunctuation: nil
        )))
    }
}
