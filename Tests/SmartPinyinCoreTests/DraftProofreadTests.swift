import Foundation
import PinyinEngineCore
import SharedIPC
import SmartPinyinCore
import XCTest

final class DraftProofreadTests: XCTestCase {
    private final class MockPinyinEngine: PinyinEngineProtocol {
        var mapping: [String: [String]] = [
            "wmen": ["我门", "我们"],
            "women": ["我们", "我门"],
            "zuotian": ["昨天"],
            "bushu": ["部暑", "部署"],
            "le": ["了"],
            "xinbanben": ["新版本"],
            "yingai": ["因该", "应该"],
            "meiwenti": ["没问题"]
        ]
        private var buffer: String = ""

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
            let words = candidatesForCurrentBuffer()
            let chosen = words.indices.contains(index) ? words[index] : (words.first ?? buffer)
            buffer = ""
            return PinyinEngineSnapshot(isComposing: false, committedText: chosen)
        }

        func changePage(forward: Bool) -> PinyinEngineSnapshot { currentSnapshot() }
        func moveHighlight(delta: Int) -> PinyinEngineSnapshot { currentSnapshot() }

        func commitComposition() -> String? {
            let out = candidatesForCurrentBuffer().first ?? buffer
            buffer = ""
            return out.isEmpty ? nil : out
        }

        func clearComposition() {
            buffer = ""
        }

        func currentSnapshot() -> PinyinEngineSnapshot {
            guard !buffer.isEmpty else { return .idle }
            let words = candidatesForCurrentBuffer()
            let cands = words.enumerated().map { PinyinCandidate(index: $0.offset, text: $0.element) }
            return PinyinEngineSnapshot(
                isComposing: true,
                preedit: buffer,
                rawInput: buffer,
                candidates: cands,
                highlightedIndex: 0
            )
        }

        private func candidatesForCurrentBuffer() -> [String] {
            if let hit = mapping[buffer] { return hit }
            return [buffer]
        }
    }

    private func typeASCII(_ text: String, into sm: InputStateMachine) -> [InputAction] {
        var last: [InputAction] = []
        for ch in text {
            last = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
        }
        return last
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

    func testDraftModeStagesMultiSegmentsPunctuationAndMixedEnglishBeforeCommit() {
        let engine = MockPinyinEngine()
        var prefs = SmartPinyinPreferences.default
        prefs.defaultDraftProofreadMode = true
        prefs.enableAIDraftProofread = false
        prefs.enableAutoCorrection = false
        let sm = InputStateMachine(engine: engine, preferences: prefs)
        XCTAssertEqual(sm.mode, .draftProofread)
        XCTAssertEqual(sm.preferences.draftSpaceBehavior, .stageThenCommit)

        // 1. 默认两段空格下按空格选词「我们」：先进入草稿区校对，不提前上屏
        _ = typeASCII("women", into: sm)
        let afterWord1 = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(committedTexts(in: afterWord1).isEmpty, "拼写态按空格选词必须先进入草稿区而非提前上屏")
        let snap1 = latestPanel(in: afterWord1)
        XCTAssertEqual(snap1?.showDraftBar, true)
        XCTAssertEqual(snap1?.draftSpaceCommitsDraft, true)
        XCTAssertEqual(snap1?.draftSourcePreview, "我们")

        // 2. 续拼「昨天」（空格进草稿）+ 大写混输「React」（输入中保留底栏预览）+ 逗号 + 数字「202」：全部留在暂存区
        _ = typeASCII("zuotian", into: sm)
        let afterWord2 = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(committedTexts(in: afterWord2).isEmpty)

        _ = sm.handle(NormalizedKeyEvent(kind: .character("R", keyCode: 0), modifiers: [.shift]))
        let duringReact = typeASCII("eact", into: sm)
        let snapDuringReact = latestPanel(in: duringReact)
        XCTAssertEqual(snapDuringReact?.showDraftBar, true, "草稿非空时输入临时英文应持续展示前置草稿底栏")
        XCTAssertEqual(snapDuringReact?.draftSourcePreview, "我们昨天React")
        let afterReact = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(committedTexts(in: afterReact).isEmpty, "草稿非空时中英混输词应追加进草稿区而非提前上屏")

        let afterComma = sm.handle(NormalizedKeyEvent(kind: .character(",", keyCode: 0)))
        XCTAssertTrue(committedTexts(in: afterComma).isEmpty)

        _ = sm.handle(NormalizedKeyEvent(kind: .character("2", keyCode: 0)))
        _ = sm.handle(NormalizedKeyEvent(kind: .character("0", keyCode: 0)))
        let afterDigits = sm.handle(NormalizedKeyEvent(kind: .character("2", keyCode: 0)))
        let snapMid = latestPanel(in: afterDigits)
        XCTAssertEqual(snapMid?.draftSourcePreview, "我们昨天React，202")

        // 3. 按空格一次性完整上屏（与翻译模式 Plan B 对齐）
        let commitActions = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertEqual(committedTexts(in: commitActions), ["我们昨天React，202"])
        XCTAssertFalse(sm.hasActiveComposition)
    }

    func testDraftModeEditingBackspaceOptionBackspaceAndTwoStageEscape() {
        let engine = MockPinyinEngine()
        var prefs = SmartPinyinPreferences.default
        prefs.defaultDraftProofreadMode = true
        prefs.enableAIDraftProofread = false
        let sm = InputStateMachine(engine: engine, preferences: prefs)

        _ = typeASCII("women", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = typeASCII("zuotian", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = typeASCII("xinbanben", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))

        // Option+Backspace 一次撤回「新版本」整段
        let afterOptBS = sm.handle(NormalizedKeyEvent(kind: .backspace, modifiers: [.option]))
        XCTAssertEqual(latestPanel(in: afterOptBS)?.draftSourcePreview, "我们昨天")

        // 普通 Backspace 逐字删掉「天」
        let afterBS = sm.handle(NormalizedKeyEvent(kind: .backspace))
        XCTAssertEqual(latestPanel(in: afterBS)?.draftSourcePreview, "我们昨")

        // 开始敲下一段拼音时按一次 Esc：只清空当前未选拼音，保护已拼好的「我们昨」！
        _ = typeASCII("meiwenti", into: sm)
        let firstEsc = sm.handle(NormalizedKeyEvent(kind: .escape))
        let snapAfterFirstEsc = latestPanel(in: firstEsc)
        XCTAssertEqual(snapAfterFirstEsc?.showDraftBar, true)
        XCTAssertEqual(snapAfterFirstEsc?.draftSourcePreview, "我们昨")

        // 再按一次 Esc：清空整个草稿并关闭面板
        let secondEsc = sm.handle(NormalizedKeyEvent(kind: .escape))
        XCTAssertEqual(latestPanel(in: secondEsc)?.isVisible, false)
        XCTAssertFalse(sm.hasActiveComposition)
    }

    func testDraftModeRuleProofreadAndReturnVsShiftReturn() {
        let engine = MockPinyinEngine()
        var prefs = SmartPinyinPreferences.default
        prefs.defaultDraftProofreadMode = true
        prefs.enableAIDraftProofread = false
        prefs.enableAutoCorrection = false
        let sm = InputStateMachine(engine: engine, preferences: prefs)

        // 刻意选出包含多处错别字的草稿：「我门昨天部暑了新版本，因该没问题」
        _ = typeASCII("wmen", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = typeASCII("zuotian", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = typeASCII("bushu", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = typeASCII("le", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = typeASCII("xinbanben", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = sm.handle(NormalizedKeyEvent(kind: .character(",", keyCode: 0)))
        _ = typeASCII("yingai", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = typeASCII("meiwenti", into: sm)
        let staged = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))

        let panel = latestPanel(in: staged)
        guard case .suggested(let src, let corrected, let segments, let changeCount, _, _)? = panel?.draftProofreadState else {
            XCTFail("期望 L1 规则预检自动识别草稿中的错别字纠偏，实际状态：\(String(describing: panel?.draftProofreadState))")
            return
        }
        XCTAssertEqual(src, "我门昨天部暑了新版本，因该没问题")
        XCTAssertEqual(corrected, "我们昨天部署了新版本，应该没问题")
        XCTAssertEqual(changeCount, 3)
        XCTAssertTrue(segments.contains { $0.isChanged && $0.text == "们" })

        // Shift+Return 强制上屏未改动原文
        let origCommit = sm.handle(NormalizedKeyEvent(kind: .returnKey, modifiers: [.shift]))
        XCTAssertEqual(committedTexts(in: origCommit), ["我门昨天部暑了新版本，因该没问题"])

        // 再输一遍并按两段空格：第 1 次空格进草稿，确认无误再按第 2 次空格上屏纠偏整句
        _ = typeASCII("wmen", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .space))
        _ = typeASCII("zuotian", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .space))
        _ = typeASCII("bushu", into: sm)
        let stagedFinal = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(committedTexts(in: stagedFinal).isEmpty, "拼写态按空格应先进入草稿校对")
        let fixedCommit = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertEqual(committedTexts(in: fixedCommit), ["我们昨天部署"])
    }

    func testFiveLayerAntiHallucinationValidatorAndReduplicationProtection() {
        let proofreader = DraftProofreadEngine()

        // 1. 合法叠词绝不误伤，虚词连打重字准确合并
        let legalRedup = proofreader.applyRuleProofread(to: "我们慢慢看看，谢谢大家")
        XCTAssertFalse(legalRedup.hasChanges, "合法叠词不应被误删")

        let stutter = proofreader.applyRuleProofread(to: "我我今天真的的很开心，，")
        XCTAssertEqual(stutter.correctedText, "我今天真的很开心，")

        // 2. 五重护栏放行真实同音/近音纠偏
        let validAI = proofreader.validateAndBuildState(
            source: "我们昨天去上孩完，用 React 写了接口",
            candidateOutput: "我们昨天去上海玩，用 React 写了接口",
            latencyMs: 65,
            backendLabel: "AI"
        )
        if case .suggested(_, let corrected, _, let count, _, _)? = validAI {
            XCTAssertEqual(corrected, "我们昨天去上海玩，用 React 写了接口")
            XCTAssertGreaterThanOrEqual(count, 1)
        } else {
            XCTFail("应放行合法同音/近音语义纠偏")
        }

        // 3. 护栏拦截无关语义胡改（上海 -> 北京 拼音完全无关）
        let hallucinatedCity = proofreader.validateAndBuildState(
            source: "我们昨天去上海玩",
            candidateOutput: "我们昨天去北京玩",
            latencyMs: 50,
            backendLabel: "AI"
        )
        XCTAssertNil(hallucinatedCity, "拼音无关的换词必须被拼音近音护栏拦下")

        // 4. 护栏拦截篡改英文代码标识符
        let tamperedCode = proofreader.validateAndBuildState(
            source: "请检查 React 和 user_id 字段",
            candidateOutput: "请检查 Vue 和 user_id 字段",
            latencyMs: 50,
            backendLabel: "AI"
        )
        XCTAssertNil(tamperedCode, "篡改英文/代码标识符必须被护栏拦下")

        // 5. 护栏拦截长度爆炸/续写与 Prompt 泄露
        let runaway = proofreader.validateAndBuildState(
            source: "今天天气不错",
            candidateOutput: "今天天气不错，适合出门散步和朋友一起去公园野餐聊天",
            latencyMs: 80,
            backendLabel: "AI"
        )
        XCTAssertNil(runaway, "模型擅自续写必须被长度护栏拦下")

        let leak = proofreader.validateAndBuildState(
            source: "今天天气不错",
            candidateOutput: "没有错别字，原样输出：今天天气不错",
            latencyMs: 40,
            backendLabel: "AI"
        )
        XCTAssertNil(leak, "元话语/指令泄露必须被格式护栏拦下")
    }

    func testDraftModeToggleShortcutAndInlineCommandAndAIPayloadApplication() {
        let engine = MockPinyinEngine()
        var prefs = SmartPinyinPreferences.default
        prefs.defaultDraftProofreadMode = false
        prefs.enableAIDraftProofread = true
        let sm = InputStateMachine(engine: engine, preferences: prefs)
        XCTAssertEqual(sm.mode, .chinesePinyin)

        // Ctrl+Option+D 开启全局整句暂存校对模式
        let onActions = sm.handle(NormalizedKeyEvent(kind: .character("d", keyCode: 2), modifiers: [.control, .option]))
        XCTAssertEqual(sm.mode, .draftProofread)
        XCTAssertTrue(onActions.contains(.persistDraftProofreadMode(true)))

        // 输入草稿并验证会触发 .requestDraftProofread 异步校对任务
        _ = typeASCII("women", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = typeASCII("zuotian", into: sm)
        let actions = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        let reqToken: UInt64? = actions.compactMap { act in
            if case .requestDraftProofread(let tok, let txt) = act, txt == "我们昨天" {
                return tok
            }
            return nil
        }.first
        XCTAssertNotNil(reqToken, "满 4 字且启用 AI 校对时应发出异步校对请求")

        if let tok = reqToken {
            let reply = ProofreadReplyPayload(
                correctedText: "我们昨天",
                hasChanges: false,
                latencyMs: 52,
                fromCache: false,
                backendName: "Qwen3-0.6B-Q4_K_M",
                physicalFootprintMB: 510
            )
            let applied = sm.applyDraftProofreadResult(reply, forSourceText: "我们昨天", forToken: tok)
            if case .updateUI(let snap)? = applied,
               case .clean(let src, _, _) = snap.draftProofreadState {
                XCTAssertEqual(src, "我们昨天")
            } else {
                XCTFail("期望校对无误后进入 .clean 状态")
            }
        }

        // 清空后用行内指令 /d 关闭
        _ = sm.handle(NormalizedKeyEvent(kind: .escape))
        _ = sm.handle(NormalizedKeyEvent(kind: .character("/", keyCode: 0)))
        _ = sm.handle(NormalizedKeyEvent(kind: .character("d", keyCode: 0)))
        let offActions = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertEqual(sm.mode, .chinesePinyin)
        XCTAssertTrue(offActions.contains(.persistDraftProofreadMode(false)))
    }

    func testDraftModeChainsL1RuleFixesIntoL2NeuralProofreadAndMergesDiff() {
        let engine = MockPinyinEngine()
        engine.mapping["zaishanghai"] = ["再上海"]

        var prefs = SmartPinyinPreferences.default
        prefs.defaultDraftProofreadMode = true
        prefs.enableAIDraftProofread = true
        prefs.enableAutoCorrection = false
        let sm = InputStateMachine(engine: engine, preferences: prefs)

        // 构造同时含 L1 确定性错词（「我门」「部暑」）与 L2 语境易混字（「再→在」）的草稿
        _ = typeASCII("wmen", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = typeASCII("zuotian", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = typeASCII("zaishanghai", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = typeASCII("bushu", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = typeASCII("xinbanben", into: sm)
        let actions = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))

        // L1 应立即展示「我门→我们」「部暑→部署」，同时把 L1 修正后的干净上下文送交 L2 做二次语境纠偏
        let req: (token: UInt64, text: String)? = actions.compactMap { act in
            if case .requestDraftProofread(let tok, let txt) = act {
                return (tok, txt)
            }
            return nil
        }.first
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.text, "我们昨天再上海部署新版本", "应将 L1 预纠后的文本串行送交 L2，避免残余错词干扰语境判别")

        // L2 在干净语境下进一步纠正「再→在」，合并后的 diff 仍以原始草稿为源并完整涵盖 L1+L2 全部 3 处改动
        if let req {
            let reply = ProofreadReplyPayload(
                correctedText: "我们昨天在上海部署新版本",
                hasChanges: true,
                latencyMs: 36,
                fromCache: false,
                backendName: "Qwen3-0.6B-Q4_K_M",
                physicalFootprintMB: 310
            )
            let applied = sm.applyDraftProofreadResult(reply, forSourceText: req.text, forToken: req.token)
            guard case .updateUI(let snap)? = applied,
                  case .suggested(let src, let corrected, let segments, let changeCount, _, let backendLabel) = snap.draftProofreadState else {
                XCTFail("期望 L1+L2 串行合流后进入 .suggested 状态，实际：\(String(describing: applied))")
                return
            }
            XCTAssertEqual(src, "我门昨天再上海部暑新版本")
            XCTAssertEqual(corrected, "我们昨天在上海部署新版本")
            XCTAssertEqual(changeCount, 3)
            XCTAssertTrue(segments.contains { $0.isChanged && $0.originalText == "门" && $0.text == "们" })
            XCTAssertTrue(segments.contains { $0.isChanged && $0.originalText == "再" && $0.text == "在" })
            XCTAssertTrue(segments.contains { $0.isChanged && $0.originalText == "暑" && $0.text == "署" })
            XCTAssertEqual(backendLabel, "规则+AI")
        }

        // 空格直接上屏 L1+L2 合并纠偏后的完整句子
        let committed = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertEqual(committedTexts(in: committed), ["我们昨天在上海部署新版本"])
    }

    func testL1RuleDoesNotCorruptLegitimateChinesePhrases() {
        let proofreader = DraftProofreadEngine()
        let cleanPhrases = [
            "请画一条实线不要压实线",
            "讨论对与错和开关与按钮",
            "我们现在见一面，在次日继续",
            "请通知到大家默认位置已更新",
            "打开使用说明，今日只要十元",
            "楼上孩子很吵，他在做业务",
            "比如过去三年我们已经结过账了",
            "数据来自已经发布的版本，写大楷",
            "为了借书我去了一趟人文建设馆"
        ]
        for sentence in cleanPhrases {
            let res = proofreader.applyRuleProofread(to: sentence)
            XCTAssertFalse(res.hasChanges, "L1 规则绝不应误伤合法中文：\(sentence) -> \(res.correctedText)")
        }
    }

    func testDraftModeTrailingPunctuationInheritsAISuggestionAndPendingSpaceEmitsAsyncCommit() {
        let engine = MockPinyinEngine()
        engine.mapping["zaishanghai"] = ["再上海"]
        engine.mapping["keyiqu"] = ["可以去"]

        var prefs = SmartPinyinPreferences.default
        prefs.defaultDraftProofreadMode = true
        prefs.enableAIDraftProofread = true
        prefs.enableAutoCorrection = false
        let sm = InputStateMachine(engine: engine, preferences: prefs)

        // 1. 输入草稿后未等 AI 回包立即按第 2 次空格上屏：必须走 .commitDraftProofreadAsync 短超时收口，绝不直接漏纠上屏
        _ = typeASCII("zaishanghai", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .space))
        _ = typeASCII("keyiqu", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .space))
        let fastSpace = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(committedTexts(in: fastSpace).isEmpty, "待 AI 校对时按空格上屏不应直接上屏错字原稿")
        let hasAsyncCommit = fastSpace.contains { act in
            if case .commitDraftProofreadAsync(let raw, let aiSrc, let fallback, _) = act {
                return raw == "再上海可以去" && aiSrc == "再上海可以去" && fallback == "再上海可以去"
            }
            return false
        }
        XCTAssertTrue(hasAsyncCommit, "期望触发 .commitDraftProofreadAsync 短超时收口")

        // 2. 等 AI 返回「在上海可以去」后，顺手补问号「？」立即空格：应继承 AI 纠偏并 0ms 直接上屏「在上海可以去？」
        _ = typeASCII("zaishanghai", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = typeASCII("keyiqu", into: sm)
        let staged = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        let tok = staged.compactMap { act -> UInt64? in
            if case .requestDraftProofread(let t, _) = act { return t }
            return nil
        }.first
        XCTAssertNotNil(tok)
        if let tok {
            _ = sm.applyDraftProofreadResult(
                ProofreadReplyPayload(
                    correctedText: "在上海可以去",
                    hasChanges: true,
                    latencyMs: 38,
                    fromCache: false,
                    backendName: "Qwen3-0.6B-Q4_K_M",
                    physicalFootprintMB: 260
                ),
                forSourceText: "再上海可以去",
                forToken: tok
            )
        }

        let afterQuestion = sm.handle(NormalizedKeyEvent(kind: .character("?", keyCode: 0)))
        if case .suggested(let src, let corrected, _, _, _, _)? = latestPanel(in: afterQuestion)?.draftProofreadState {
            XCTAssertEqual(src, "再上海可以去？")
            XCTAssertEqual(corrected, "在上海可以去？")
        } else {
            XCTFail("补加句末标点应继承已有 AI 纠偏而非回落校对中")
        }
        let commitWithPunct = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertEqual(committedTexts(in: commitWithPunct), ["在上海可以去？"])
    }

    func testDraftModeTabTranslateMigrationLatePredictionGuardAndSlashTRestore() {
        let engine = MockPinyinEngine()
        var now: TimeInterval = 1000.0
        var prefs = SmartPinyinPreferences.default
        prefs.defaultDraftProofreadMode = true
        prefs.enableAIDraftProofread = true
        prefs.enableContinuationPrediction = true
        prefs.enableAutoCorrection = false
        let sm = InputStateMachine(engine: engine, preferences: prefs, clock: { now })

        // 1. 选词进入草稿区后，延迟到达的联想回调绝不能顶掉草稿卡片
        _ = typeASCII("women", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        let latePred = sm.applyPredictions(["一起去"], forToken: sm.sessionToken)
        XCTAssertNil(latePred, "draftChineseBuffer 非空时必须忽略延迟联想回调")

        // 2. 草稿态单按 Tab 临切翻译：草稿无损迁移进翻译栏而非变空白面板；超过 320ms 后再单按 Tab 无损切回草稿区
        let toTrans = sm.handle(NormalizedKeyEvent(kind: .tab))
        let transPanel = latestPanel(in: toTrans)
        XCTAssertEqual(transPanel?.showTranslationBar, true)
        XCTAssertEqual(transPanel?.translationSourcePreview, "我们")

        now += 1.0
        let backToDraft = sm.handle(NormalizedKeyEvent(kind: .tab))
        let draftPanel = latestPanel(in: backToDraft)
        XCTAssertEqual(draftPanel?.showDraftBar, true)
        XCTAssertEqual(draftPanel?.draftSourcePreview, "我们")

        // 3. 清空后用 /t 开关一次翻译，关闭后应恢复为 .draftProofread 而非 .chinesePinyin
        _ = sm.handle(NormalizedKeyEvent(kind: .escape))
        _ = sm.handle(NormalizedKeyEvent(kind: .character("/", keyCode: 0)))
        _ = sm.handle(NormalizedKeyEvent(kind: .character("t", keyCode: 0)))
        _ = sm.handle(NormalizedKeyEvent(kind: .space))
        if case .translateOnCommit = sm.mode { } else { XCTFail("期望 /t 开启翻译模式") }

        _ = sm.handle(NormalizedKeyEvent(kind: .character("/", keyCode: 0)))
        _ = sm.handle(NormalizedKeyEvent(kind: .character("t", keyCode: 0)))
        _ = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertEqual(sm.mode, .draftProofread, "关闭翻译后应恢复全局草稿校对模式")
    }

    func testDraftModeRerankTopChangeRefreshesProofreadRequest() {
        let engine = MockPinyinEngine()
        engine.mapping["xinfangan"] = ["新防案", "新方案"]

        var prefs = SmartPinyinPreferences.default
        prefs.defaultDraftProofreadMode = true
        prefs.enableAIDraftProofread = true
        prefs.enableNeuralRerank = true
        prefs.enableAutoCorrection = false
        let sm = InputStateMachine(engine: engine, preferences: prefs)
        sm.updateRuntimeContext(leftContext: "我们需要讨论这个", appBundleID: "com.apple.Notes", isSecureInput: false)

        _ = typeASCII("women", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = typeASCII("xinfangan", into: sm)
        let tok = sm.sessionToken

        // 模拟 L2 神经重排将「新方案」提至首位：应联动重发对应新草稿「我们新方案」的校对请求，避免原请求回包被丢弃卡死
        let rerankActions = sm.applyRerankedScoresWithActions([
            ScoredCandidate(text: "新防案", score: -12.0),
            ScoredCandidate(text: "新方案", score: -2.0)
        ], forToken: tok)

        let refreshedDraft: String? = rerankActions.compactMap { act in
            if case .requestDraftProofread(_, let txt) = act { return txt }
            return nil
        }.first
        XCTAssertEqual(refreshedDraft, "我们新方案")
    }

    func testSystemCommitCompositionFlushesDraftBufferAndPreventsGhostDraft() {
        let engine = MockPinyinEngine()
        engine.mapping["zaishanghai"] = ["再上海"]
        engine.mapping["keyiqu"] = ["可以去"]

        var prefs = SmartPinyinPreferences.default
        prefs.defaultDraftProofreadMode = true
        prefs.enableAIDraftProofread = true
        prefs.enableAutoCorrection = false
        let sm = InputStateMachine(engine: engine, preferences: prefs)

        _ = typeASCII("zaishanghai", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = typeASCII("keyiqu", into: sm)
        let staged = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        if let tok = staged.compactMap({ act -> UInt64? in
            if case .requestDraftProofread(let t, _) = act { return t }
            return nil
        }).first {
            _ = sm.applyDraftProofreadResult(
                ProofreadReplyPayload(
                    correctedText: "在上海可以去",
                    hasChanges: true,
                    latencyMs: 35,
                    fromCache: false,
                    backendName: "Qwen3-0.6B-Q4_K_M",
                    physicalFootprintMB: 260
                ),
                forSourceText: "再上海可以去",
                forToken: tok
            )
        }

        // 模拟用户鼠标点击别处触发系统 commitComposition：应立刻提交已纠偏草稿并彻底清空状态机
        let sysCommit = sm.commitActiveCompositionOnSystemRequest()
        XCTAssertEqual(committedTexts(in: sysCommit), ["在上海可以去"])
        XCTAssertFalse(sm.hasActiveComposition, "系统强制提交后绝不能残留幽灵草稿")

        // 下一次在别处重新输入时绝不能带出旧草稿
        _ = typeASCII("women", into: sm)
        let nextStaged = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        XCTAssertEqual(latestPanel(in: nextStaged)?.draftSourcePreview, "我们")
    }

    func testTrailingPunctuationInheritedSuggestionSurvivesNilBackgroundRecheck() {
        let engine = MockPinyinEngine()
        engine.mapping["zaishanghai"] = ["再上海"]
        engine.mapping["keyiqu"] = ["可以去"]

        var prefs = SmartPinyinPreferences.default
        prefs.defaultDraftProofreadMode = true
        prefs.enableAIDraftProofread = true
        prefs.enableAutoCorrection = false
        let sm = InputStateMachine(engine: engine, preferences: prefs)

        _ = typeASCII("zaishanghai", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = typeASCII("keyiqu", into: sm)
        let staged = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        let tok1 = staged.compactMap { act -> UInt64? in
            if case .requestDraftProofread(let t, _) = act { return t }
            return nil
        }.first!
        _ = sm.applyDraftProofreadResult(
            ProofreadReplyPayload(
                correctedText: "在上海可以去",
                hasChanges: true,
                latencyMs: 36,
                fromCache: false,
                backendName: "Qwen3-0.6B-Q4_K_M",
                physicalFootprintMB: 260
            ),
            forSourceText: "再上海可以去",
            forToken: tok1
        )

        // 追加句末问号继承纠偏，随后模拟后台静默复核超时返回 nil：必须保留已继承的「在上海可以去？」而非覆写为 .clean
        let afterQ = sm.handle(NormalizedKeyEvent(kind: .character("?", keyCode: 0)))
        let tok2 = afterQ.compactMap { act -> UInt64? in
            if case .requestDraftProofread(let t, _) = act { return t }
            return nil
        }.first!
        let afterNilRecheck = sm.applyDraftProofreadResult(nil, forSourceText: "再上海可以去？", forToken: tok2)
        if case .updateUI(let snap)? = afterNilRecheck,
           case .suggested(let src, let corrected, _, _, _, _) = snap.draftProofreadState {
            XCTAssertEqual(src, "再上海可以去？")
            XCTAssertEqual(corrected, "在上海可以去？")
        } else {
            XCTFail("后台复核超时返回 nil 时必须保留已继承的 AI 纠偏建议，实际：\(String(describing: afterNilRecheck))")
        }
    }

    func testDraftModeTwoStageSpaceStagesThenCommitsAndComposeModeStillAddsSpace() {
        let engine = MockPinyinEngine()
        engine.mapping["xianzai"] = ["现在"]
        engine.mapping["zaishanghai"] = ["再上海"]

        // 1. 默认两段空格 (.stageThenCommit)：第 1 次空格先进草稿校对，确认无误再按第 2 次空格上屏
        var prefs = SmartPinyinPreferences.default
        prefs.defaultDraftProofreadMode = true
        prefs.enableAIDraftProofread = false
        prefs.enableAutoCorrection = false
        let sm = InputStateMachine(engine: engine, preferences: prefs)

        _ = typeASCII("xianzai", into: sm)
        let firstSpace = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(committedTexts(in: firstSpace).isEmpty, "第 1 次空格应先进入草稿区而非跳过校对直接上屏")
        XCTAssertEqual(latestPanel(in: firstSpace)?.showDraftBar, true)
        XCTAssertEqual(latestPanel(in: firstSpace)?.draftSourcePreview, "现在")
        XCTAssertEqual(latestPanel(in: firstSpace)?.candidates.isEmpty, true)
        XCTAssertTrue(sm.hasActiveComposition)

        let secondSpace = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertEqual(committedTexts(in: secondSpace), ["现在"], "确认草稿无误后再次按空格应直接上屏整句")
        XCTAssertFalse(sm.hasActiveComposition)

        // 2. 切为 .composeChineseSegment（传统拼句模式）：第 1 次空格进草稿、第 2 次空格补空格，回车一次性上屏
        var composePrefs = prefs
        composePrefs.draftSpaceBehavior = .composeChineseSegment
        let smLegacy = InputStateMachine(engine: engine, preferences: composePrefs)

        _ = typeASCII("women", into: smLegacy)
        let staged1 = smLegacy.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(committedTexts(in: staged1).isEmpty)
        XCTAssertEqual(latestPanel(in: staged1)?.draftSpaceCommitsDraft, false)
        XCTAssertEqual(latestPanel(in: staged1)?.draftSourcePreview, "我们")

        let spaced = smLegacy.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertEqual(latestPanel(in: spaced)?.draftSourcePreview, "我们 ")

        let legacyCommit = smLegacy.handle(NormalizedKeyEvent(kind: .returnKey))
        XCTAssertEqual(committedTexts(in: legacyCommit), ["我们 "])
    }

    func testDraftModeEnglishInputSmoothnessStandaloneAndMixed() {
        let engine = MockPinyinEngine()
        engine.mapping["git"] = ["给它"]
        engine.mapping["hello"] = ["hello", "和了"]
        engine.mapping["https"] = ["合同评审"]
        engine.mapping["use"] = ["无色"]
        engine.mapping["user"] = ["无色人"]

        var prefs = SmartPinyinPreferences.default
        prefs.defaultDraftProofreadMode = true
        prefs.enableAIDraftProofread = false
        prefs.enableAutoCorrection = false
        let sm = InputStateMachine(engine: engine, preferences: prefs)

        // 1. 草稿为空时，小写英文 + 回车直出原始英文（与普通中文模式肌肉记忆 100% 一致）
        _ = typeASCII("git", into: sm)
        let gitReturn = sm.handle(NormalizedKeyEvent(kind: .returnKey))
        XCTAssertEqual(committedTexts(in: gitReturn), ["git"], "草稿为空时小写英文按回车应直出原始英文")
        XCTAssertFalse(sm.hasActiveComposition)

        // 2. 万象英文候选首位按空格直接上屏，且纯英文草稿不误报「规则校对无误」
        let duringHello = typeASCII("hello", into: sm)
        XCTAssertEqual(latestPanel(in: duringHello)?.draftProofreadState, .idle, "纯英文无汉字候选不应误标为中文规则 .clean")
        let helloSpace = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertEqual(committedTexts(in: helloSpace), ["hello"])
        XCTAssertFalse(sm.hasActiveComposition)

        // 3. 独立大写词（React / App.tsx）、驼峰（useState）、下划线（user_id）直接上屏，绝不被困入草稿盒
        _ = sm.handle(NormalizedKeyEvent(kind: .character("R", keyCode: 0), modifiers: [.shift]))
        _ = typeASCII("eact", into: sm)
        let reactCommit = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertEqual(committedTexts(in: reactCommit), ["React"])
        XCTAssertFalse(sm.hasActiveComposition)

        _ = typeASCII("use", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("S", keyCode: 0), modifiers: [.shift]))
        _ = typeASCII("tate", into: sm)
        let camelCommit = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertEqual(committedTexts(in: camelCommit), ["useState"])
        XCTAssertFalse(sm.hasActiveComposition)

        _ = typeASCII("user", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("_", keyCode: 0), modifiers: [.shift]))
        _ = typeASCII("id", into: sm)
        let snakeCommit = sm.handle(NormalizedKeyEvent(kind: .returnKey))
        XCTAssertEqual(committedTexts(in: snakeCommit), ["user_id"])
        XCTAssertFalse(sm.hasActiveComposition)

        // 4. Shift+Space 英文短句直接上屏不被困入草稿盒
        _ = sm.handle(NormalizedKeyEvent(kind: .space, modifiers: [.shift]))
        for ch in "git status" {
            if ch == " " {
                _ = sm.handle(NormalizedKeyEvent(kind: .space))
            } else {
                _ = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0)))
            }
        }
        let phraseCommit = sm.handle(NormalizedKeyEvent(kind: .returnKey))
        XCTAssertEqual(committedTexts(in: phraseCommit), ["git status"])
        XCTAssertFalse(sm.hasActiveComposition)

        // 5. URL 协议前缀（https:）自动转临时英文，避免被中文标点误转成「合同评审：」
        _ = typeASCII("https", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character(":", keyCode: 0), modifiers: [.shift]))
        _ = typeASCII("//github.com", into: sm)
        let urlCommit = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertEqual(committedTexts(in: urlCommit), ["https://github.com"])
        XCTAssertFalse(sm.hasActiveComposition)

        // 6. 非空草稿态输入 `-` 与 `=` 追加到草稿而非 passThrough 穿窗乱序，且此时按 Return 提交已纠偏草稿
        _ = typeASCII("wmen", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        let afterDash = sm.handle(NormalizedKeyEvent(kind: .character("-", keyCode: 0)))
        XCTAssertFalse(afterDash.contains(.passThrough))
        XCTAssertEqual(latestPanel(in: afterDash)?.draftSourcePreview, "我门-")
        let afterEq = sm.handle(NormalizedKeyEvent(kind: .character("=", keyCode: 0)))
        XCTAssertFalse(afterEq.contains(.passThrough))
        XCTAssertEqual(latestPanel(in: afterEq)?.draftSourcePreview, "我门-=")
        let draftReturn = sm.handle(NormalizedKeyEvent(kind: .returnKey))
        XCTAssertEqual(committedTexts(in: draftReturn), ["我们-="])

        // 7. 非空草稿 + 临时英文态短按 Shift 切英文：无损提交已纠偏草稿+英文，绝不遗留幽灵草稿
        _ = typeASCII("wmen", into: sm)
        _ = sm.handle(NormalizedKeyEvent(kind: .character("1", keyCode: 18)))
        _ = sm.handle(NormalizedKeyEvent(kind: .character("T", keyCode: 0), modifiers: [.shift]))
        _ = sm.handle(NormalizedKeyEvent(kind: .character("3", keyCode: 0)))
        let shiftOut = sm.handle(NormalizedKeyEvent(kind: .shiftTapToggle))
        XCTAssertEqual(sm.mode, .directEnglish)
        XCTAssertEqual(committedTexts(in: shiftOut), ["我们T3"])
        XCTAssertFalse(sm.hasActiveComposition)
    }

    func testDraftSpaceBehaviorPreferencePersistenceAndBackwardsCompatibility() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smartpinyin-draft-space-pref-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var prefs = SmartPinyinPreferences.default
        XCTAssertEqual(prefs.draftSpaceBehavior, .stageThenCommit)
        prefs.draftSpaceBehavior = .composeChineseSegment
        SmartPinyinPreferencesStore.save(prefs, baseDirectory: tmpDir, postNotification: false)
        let loaded = SmartPinyinPreferencesStore.load(baseDirectory: tmpDir)
        XCTAssertEqual(loaded.draftSpaceBehavior, .composeChineseSegment)

        // 旧配置 JSON 缺失 draftSpaceBehavior 字段或包含过渡值 commitDraft 时，均应兼容回落为 .stageThenCommit
        let legacyJSON = #"{"defaultDraftProofreadMode":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SmartPinyinPreferences.self, from: legacyJSON)
        XCTAssertEqual(decoded.defaultDraftProofreadMode, true)
        XCTAssertEqual(decoded.draftSpaceBehavior, .stageThenCommit)

        let prevDraftJSON = #"{"defaultDraftProofreadMode":true,"draftSpaceBehavior":"commitDraft"}"#.data(using: .utf8)!
        let migrated = try JSONDecoder().decode(SmartPinyinPreferences.self, from: prevDraftJSON)
        XCTAssertEqual(migrated.draftSpaceBehavior, .stageThenCommit)
    }

    func testAutoSingleCharFallbackDoesNotHijackUnmatchableEnglishWord() {
        final class EmptyForEnglishMockEngine: PinyinEngineProtocol {
            var buffer = ""
            func processKey(keyval: Int32, mask: Int32) -> (handled: Bool, snapshot: PinyinEngineSnapshot) {
                if keyval == 0xff08 {
                    if !buffer.isEmpty { buffer.removeLast() }
                    return (true, currentSnapshot())
                }
                guard let scalar = UnicodeScalar(Int(keyval)) else { return (false, currentSnapshot()) }
                buffer.append(Character(scalar))
                return (true, currentSnapshot())
            }
            func selectCandidateOnCurrentPage(index: Int) -> PinyinEngineSnapshot { .idle }
            func changePage(forward: Bool) -> PinyinEngineSnapshot { currentSnapshot() }
            func moveHighlight(delta: Int) -> PinyinEngineSnapshot { currentSnapshot() }
            func commitComposition() -> String? { defer { buffer = "" }; return buffer.isEmpty ? nil : buffer }
            func clearComposition() { buffer = "" }
            func currentSnapshot() -> PinyinEngineSnapshot {
                guard !buffer.isEmpty else { return .idle }
                return PinyinEngineSnapshot(isComposing: true, preedit: buffer, rawInput: buffer, candidates: [])
            }
            func probeSingleChars(forSyllable syllable: String, limit: Int) -> [PinyinCandidate] { [] }
            func probeCandidates(forPinyin pinyin: String, limit: Int) -> [PinyinCandidate] { [] }
        }

        let engine = EmptyForEnglishMockEngine()
        var prefs = SmartPinyinPreferences.default
        prefs.defaultDraftProofreadMode = true
        prefs.enableAutoSingleCharFallback = true
        prefs.enableAutoCorrection = false
        let sm = InputStateMachine(engine: engine, preferences: prefs)

        _ = typeASCII("vllm", into: sm)
        XCTAssertFalse(sm.isSingleCharModeActive, "单字探针为空的纯英文串绝不应被劫持进空单字逐选模式")
        let ret = sm.handle(NormalizedKeyEvent(kind: .returnKey))
        XCTAssertEqual(committedTexts(in: ret), ["vllm"])
    }
}
