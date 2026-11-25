import Foundation
import PinyinEngineCore
import SharedIPC
import SmartPinyinCore
import XCTest

final class SingleCharProgressiveTests: XCTestCase {
    /// 模拟「主会话长串返回空候选或触发长度上限，但单字探针可查单字」的引擎
    private final class LongBrokenMockEngine: PinyinEngineProtocol {
        var failWithEmptyCandidatesAtLength = 10
        var simulateLengthLimitPrompt = false
        private var buffer = ""

        let singleCharDict: [String: [String]] = [
            "shang": ["上", "商", "尚", "伤", "赏", "晌", "裳", "熵", "墒", "殇"],
            "hai": ["海", "还", "害", "孩", "骇", "骸"],
            "xi": ["西", "希", "喜", "系", "细", "戏", "洗", "息"],
            "an": ["安", "按", "暗", "案", "岸"],
            "xian": ["先", "现", "线", "显", "限", "鲜", "险", "献"],
            "wo": ["我", "握", "卧", "窝"],
            "men": ["们", "门", "闷"],
            "sh": ["是", "时", "十", "上", "手", "说"],
            "g": ["个", "国", "过", "工"]
        ]

        func processKey(keyval: Int32, mask: Int32) -> (handled: Bool, snapshot: PinyinEngineSnapshot) {
            if keyval == 0xff08 {
                if !buffer.isEmpty { buffer.removeLast() }
                return (true, currentSnapshot())
            }
            guard let scalar = UnicodeScalar(Int(keyval)) else {
                return (false, currentSnapshot())
            }
            buffer.append(Character(scalar))
            return (true, currentSnapshot())
        }

        func selectCandidateOnCurrentPage(index: Int) -> PinyinEngineSnapshot {
            let text = buffer
            buffer = ""
            return PinyinEngineSnapshot(isComposing: false, committedText: text)
        }

        func changePage(forward: Bool) -> PinyinEngineSnapshot { currentSnapshot() }
        func moveHighlight(delta: Int) -> PinyinEngineSnapshot { currentSnapshot() }
        func commitComposition() -> String? { defer { buffer = "" }; return buffer.isEmpty ? nil : buffer }
        func clearComposition() { buffer = "" }

        func currentSnapshot() -> PinyinEngineSnapshot {
            guard !buffer.isEmpty else { return .idle }
            if simulateLengthLimitPrompt && buffer.count >= failWithEmptyCandidatesAtLength {
                return PinyinEngineSnapshot(
                    isComposing: true,
                    preedit: "\(buffer) 〔已超最大输入长度〕",
                    rawInput: buffer,
                    candidates: [PinyinCandidate(index: 0, text: "残缺")]
                )
            }
            if buffer.count >= failWithEmptyCandidatesAtLength {
                // 模拟长串/生僻组合导致 Rime 候选为空
                return PinyinEngineSnapshot(
                    isComposing: true,
                    preedit: buffer,
                    rawInput: buffer,
                    candidates: []
                )
            }
            return PinyinEngineSnapshot(
                isComposing: true,
                preedit: buffer,
                rawInput: buffer,
                candidates: [PinyinCandidate(index: 0, text: "词组候选")]
            )
        }

        func probeSingleChars(forSyllable syllable: String, limit: Int) -> [PinyinCandidate] {
            let list = singleCharDict[syllable] ?? []
            return list.prefix(limit).enumerated().map {
                PinyinCandidate(index: $0.offset, text: $0.element, source: .rime)
            }
        }
    }

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func latestPanel(in actions: [InputAction]) -> CandidatePanelSnapshot? {
        for act in actions.reversed() {
            if case .updateUI(let snap) = act { return snap }
        }
        return nil
    }

    private func committedTexts(in actions: [InputAction]) -> [String] {
        actions.compactMap { act in
            if case .commitText(let text, _) = act { return text }
            return nil
        }
    }

    func testRimeSingleCharProbeReturnsPureSingleHanziAndSupportsMultiPage() throws {
        let dataDir = projectRoot().appendingPathComponent("Resources/RimeData", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("wanxiang.schema.yaml").path) else {
            throw XCTSkip("Bundled RimeData not present")
        }
        let tmpUser = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-single-char-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpUser) }

        let adapter = RimeEngineAdapter(bundledDataDirectory: dataDir, userDataDirectory: tmpUser)
        let yiChars = adapter.probeSingleChars(forSyllable: "yi", limit: 63)
        XCTAssertGreaterThanOrEqual(yiChars.count, 20, "常用音节 yi 应返回充足单字以支持多页翻找生僻字")
        for cand in yiChars {
            XCTAssertEqual(cand.text.count, 1, "单字探针不得混入多字词：\(cand.text)")
        }
        let shangChars = adapter.probeSingleChars(forSyllable: "shang", limit: 40)
        XCTAssertTrue(shangChars.contains { $0.text == "上" })
        XCTAssertTrue(shangChars.contains { $0.text == "商" })
        // 确认探针绝不污染主会话
        XCTAssertFalse(adapter.currentSnapshot().isComposing)
    }

    func testSyllableBoundaryAdjustmentUndoAndPaging() {
        let engine = LongBrokenMockEngine()
        let session = SingleCharProgressiveSession(
            rawPinyin: "xian",
            pageSize: 5,
            engine: engine
        )

        // 默认贪婪切分出完整音节 xian（8 候选，支持翻页）
        XCTAssertEqual(session.currentSyllable, "xian")
        XCTAssertEqual(session.currentPageCandidates.count, 5)
        XCTAssertTrue(session.hasNextPage)

        // 翻到第 2 页
        session.changePage(forward: true)
        XCTAssertEqual(session.pageNo, 1)
        XCTAssertEqual(session.currentPageCandidates.first?.text, "鲜")

        // Shift+Left 缩短音节边界：xian -> [xi] + an
        XCTAssertTrue(session.adjustSyllableBoundary(delta: -2))
        XCTAssertEqual(session.currentSyllable, "xi")
        XCTAssertEqual(session.trailingPinyin, "an")
        XCTAssertEqual(session.currentPageCandidates.first?.text, "西")

        // 选「西」后自动推进到 [an]
        let step1 = session.pickCandidateOnCurrentPage(index: 0)
        XCTAssertEqual(step1, .advanced)
        XCTAssertEqual(session.selectedText, "西")
        XCTAssertEqual(session.currentSyllable, "an")
        XCTAssertEqual(session.formattedPreedit, "西 [an]")

        // 按退格撤销「西」，恢复 [xi] an 重新挑！
        XCTAssertTrue(session.handleBackspace())
        XCTAssertEqual(session.selectedText, "")
        XCTAssertEqual(session.currentSyllable, "xi")
        XCTAssertEqual(session.trailingPinyin, "an")

        // 重选「喜」+「安」完成整段
        XCTAssertEqual(session.pickCandidateOnCurrentPage(index: 2), .advanced) // 喜
        XCTAssertEqual(session.pickCandidateOnCurrentPage(index: 0), .completed(fullText: "喜安"))
    }

    func testAutoSingleCharFallbackWhenEngineReturnsEmptyCandidatesOrHitsLengthCap() {
        let engine = LongBrokenMockEngine()
        engine.failWithEmptyCandidatesAtLength = 8
        var prefs = SmartPinyinPreferences.default
        prefs.enableAutoSingleCharFallback = true
        prefs.enableAutoCorrection = false
        let sm = InputStateMachine(engine: engine, preferences: prefs)

        // 连续输入 "shanghai"（达到 8 字母时 MockEngine 返回空候选 -> 自动无缝切入单字逐选模式）
        var lastActions: [InputAction] = []
        for ch in "shanghai" {
            lastActions = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }

        XCTAssertTrue(sm.isSingleCharModeActive, "Rime 返回空候选时应自动兜底进入单字逐选模式")
        let snap = latestPanel(in: lastActions)
        XCTAssertEqual(snap?.isSingleCharMode, true)
        XCTAssertEqual(snap?.preedit, "[shang] hai")
        XCTAssertEqual(snap?.candidates.first?.text, "上")

        // 逐个选完「上」「海」，一次性完整上屏
        let after1 = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        XCTAssertEqual(latestPanel(in: after1)?.preedit, "上 [hai]")
        let after2 = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        XCTAssertEqual(committedTexts(in: after2), ["上海"])
        XCTAssertFalse(sm.isSingleCharModeActive)
    }

    func testManualOptionCSingleCharFlowsSeamlesslyIntoDraftProofreadBuffer() {
        let engine = LongBrokenMockEngine()
        engine.failWithEmptyCandidatesAtLength = 99
        var prefs = SmartPinyinPreferences.default
        prefs.defaultDraftProofreadMode = true
        prefs.enableAIDraftProofread = false
        prefs.enableAutoCorrection = false
        let sm = InputStateMachine(engine: engine, preferences: prefs)

        // 输入 "womengo" 并手动按 Option+C 切入单字逐选
        for ch in "women" {
            _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        let entered = sm.handle(NormalizedKeyEvent(kind: .character("c", keyCode: 8), modifiers: [.option]))
        XCTAssertTrue(sm.isSingleCharModeActive)
        XCTAssertEqual(latestPanel(in: entered)?.preedit, "[wo] men")

        // 故意选「我」+「门」组成错词「我门」，完成后自动落入整句暂存区而非直接上屏！
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18))) // 我
        let afterSecond = sm.handle(NormalizedKeyEvent(kind: .character("2", keyCode: 19))) // 门
        XCTAssertFalse(sm.isSingleCharModeActive)
        XCTAssertTrue(committedTexts(in: afterSecond).isEmpty, "暂存模式下逐字选完应进入底部草稿区而不是直接上屏")

        let draftSnap = latestPanel(in: afterSecond)
        XCTAssertEqual(draftSnap?.showDraftBar, true)
        if case .suggested(let src, let corrected, _, _, _, _)? = draftSnap?.draftProofreadState {
            XCTAssertEqual(src, "我门")
            XCTAssertEqual(corrected, "我们")
        } else {
            XCTFail("期望逐字选完并入草稿区后自动触发整句校对纠偏")
        }

        // 最后按回车上屏纠偏后的「我们」
        let committed = sm.handle(NormalizedKeyEvent(kind: .returnKey))
        XCTAssertEqual(committedTexts(in: committed), ["我们"])
    }
}
