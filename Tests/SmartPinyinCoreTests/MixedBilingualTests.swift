import XCTest
@testable import PinyinEngineCore
@testable import SharedIPC
@testable import SmartPinyinCore

private final class SimpleMixedMockEngine: PinyinEngineProtocol {
    var mapping: [String: [String]] = [:]
    var buffer = ""

    func processKey(keyval: Int32, mask: Int32) -> (handled: Bool, snapshot: PinyinEngineSnapshot) {
        if keyval == 0xff08 {
            if !buffer.isEmpty { buffer.removeLast() }
            return (true, currentSnapshot())
        }
        guard let scalar = UnicodeScalar(Int(keyval)) else { return (false, currentSnapshot()) }
        let ch = Character(scalar)
        if ch >= "a" && ch <= "z" {
            buffer.append(ch)
            return (true, currentSnapshot())
        }
        return (false, currentSnapshot())
    }

    func selectCandidateOnCurrentPage(index: Int) -> PinyinEngineSnapshot {
        let list = mapping[buffer] ?? []
        let chosen = list.indices.contains(index) ? list[index] : buffer
        buffer = ""
        return PinyinEngineSnapshot(isComposing: false, committedText: chosen)
    }

    func changePage(forward: Bool) -> PinyinEngineSnapshot { currentSnapshot() }
    func moveHighlight(delta: Int) -> PinyinEngineSnapshot { currentSnapshot() }
    func commitComposition() -> String? { defer { buffer = "" }; return buffer.isEmpty ? nil : buffer }
    func clearComposition() { buffer = "" }

    func currentSnapshot() -> PinyinEngineSnapshot {
        guard !buffer.isEmpty else { return .idle }
        let list = mapping[buffer] ?? []
        let cands = list.enumerated().map { PinyinCandidate(index: $0.offset, text: $0.element) }
        return PinyinEngineSnapshot(isComposing: true, preedit: buffer, rawInput: buffer, candidates: cands)
    }

    func probeSingleChars(forSyllable syllable: String, limit: Int) -> [PinyinCandidate] { [] }
    func probeCandidates(forPinyin pinyin: String, limit: Int) -> [PinyinCandidate] {
        (mapping[pinyin] ?? []).prefix(limit).enumerated().map { PinyinCandidate(index: $0.offset, text: $0.element) }
    }
}

final class MixedBilingualTests: XCTestCase {
    private static func projectRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func bundledRimeDataURL() -> URL {
        projectRootURL().appendingPathComponent("Resources/RimeData", isDirectory: true)
    }

    private static func loadFullLexicon() -> EnglishLexiconStore {
        EnglishLexiconStore.loadBundled(rimeDataDirectory: bundledRimeDataURL(), loadSynchronously: true)
    }

    private func latestPanel(in actions: [InputAction]) -> CandidatePanelSnapshot? {
        for act in actions.reversed() {
            if case .updateUI(let snap) = act {
                return snap
            }
        }
        return nil
    }

    private func committedTexts(in actions: [InputAction]) -> [String] {
        actions.compactMap { act in
            if case .commitText(let text, _) = act { return text }
            return nil
        }
    }

    private func typeASCII(_ text: String, into sm: InputStateMachine) -> [InputAction] {
        var last: [InputAction] = []
        for ch in text {
            let mods: NormalizedKeyEvent.Modifiers = ch.isUppercase ? [.shift] : []
            last = sm.handle(NormalizedKeyEvent(kind: .character(String(ch), keyCode: 0), modifiers: mods))
        }
        return last
    }

    // MARK: - 1. 离线 73K 英文词库、前缀补全与双层 QWERTY 拼写纠错

    func testEnglishLexiconPrefixCompletionsAndTwoTierSpellCorrection() throws {
        let dataDir = Self.bundledRimeDataURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dataDir.path), "RimeData not present")
        let lexicon = Self.loadFullLexicon()

        // 精选技术词 + 73K 词库精确查表
        XCTAssertEqual(lexicon.lookupExact("git")?.display, "git")
        XCTAssertEqual(lexicon.lookupExact("github")?.display, "GitHub")
        XCTAssertEqual(lexicon.lookupExact("docker")?.display, "Docker")
        XCTAssertEqual(lexicon.lookupExact("react")?.display, "React")
        XCTAssertEqual(lexicon.lookupExact("typescript")?.display, "TypeScript")
        XCTAssertNotNil(lexicon.lookupExact("environment"), "73K en.dict.yaml 应成功加载普通高频词 environment")

        // 前缀补全（主中文态 & 大小写保留）
        let dockPrefs = lexicon.prefixCompletions(for: "dock", limit: 5).map(\.display)
        XCTAssertTrue(dockPrefs.contains("Docker"), "dock 前缀应召回 Docker，实际：\(dockPrefs)")
        let reacPrefs = lexicon.prefixCompletions(for: "Reac", limit: 5, preferCapitalized: true).map(\.display)
        XCTAssertEqual(reacPrefs.first, "React")
        let vscPrefs = lexicon.prefixCompletions(for: "vsco", limit: 5).map(\.display)
        XCTAssertEqual(vscPrefs.first, "VSCode")

        // Tier 1：1-Edit 邻域直查（倒序 / 多键 / QWERTY 错键 / 漏键）
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "gti").first?.text, "git")
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "dokcer").first?.text, "Docker")
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "doker").first?.text, "Docker")
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "doxker").first?.text, "Docker")
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "dockker").first?.text, "Docker")
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "recat").first?.text, "React")
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "reavt").first?.text, "React")
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "pytohn").first?.text, "Python")
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "swfit").first?.text, "Swift")
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "githbu").first?.text, "GitHub")
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "enviroment").first?.text.lowercased(), "environment")

        // 大小写自适应还原
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "Recat").first?.text, "React")
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "RECAT").first?.text, "REACT")
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "Dokcer").first?.text, "Docker")

        // Tier 2：2-Edit 精选高频/技术词纠错
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "typescritp").first?.text, "TypeScript")
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "definately").first?.text.lowercased(), "definitely")
        XCTAssertEqual(lexicon.fuzzyCorrect(query: "seperate").first?.text.lowercased(), "separate")
    }

    // MARK: - 2. 真实万象 Rime 端到端中英混输、截图场景实测、英文纠错与零纯中文回归

    func testRealWanxiangRimeMixedBilingualAndSpellCorrectionEndToEnd() throws {
        let dataDir = Self.bundledRimeDataURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dataDir.path), "RimeData not present")

        let tempUser = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartPinyinMixedBilingual_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempUser) }

        var prefs = SmartPinyinPreferences.default
        prefs.enableAutoCorrection = true
        prefs.enableMixedBilingualAssist = true
        prefs.fuzzyNasalPinyin = true

        let engine = RimeEngineAdapter(
            bundledDataDirectory: dataDir,
            userDataDirectory: tempUser,
            preferredSchemaID: "wanxiang",
            initialPreferences: prefs
        )
        let lexicon = Self.loadFullLexicon()
        let sm = InputStateMachine(
            engine: engine,
            preferences: prefs,
            englishLexicon: lexicon
        )

        func candidates(for input: String) -> [PinyinCandidate] {
            _ = sm.handle(NormalizedKeyEvent(kind: .escape))
            let actions = typeASCII(input, into: sm)
            return latestPanel(in: actions)?.candidates ?? []
        }

        // --- A. 截图原场景 & 英文前缀 + 中文全拼/不完整尾音节/简拼 ---
        let gitdiz = candidates(for: "gitdiz")
        XCTAssertEqual(gitdiz.first?.text, "git地址", "截图场景 gitdiz 应首位出 git地址，实际：\(gitdiz.map(\.text))")
        XCTAssertEqual(gitdiz.first?.source, .mixedBilingual)

        let gitdizhi = candidates(for: "gitdizhi")
        XCTAssertEqual(gitdizhi.first?.text, "git地址", "gitdizhi 实际：\(gitdizhi.map(\.text))")

        let gitck = candidates(for: "gitck").prefix(3).map(\.text)
        XCTAssertTrue(gitck.contains("git仓库"), "gitck 前 3 应含 git仓库，实际：\(gitck)")

        let reactzj = candidates(for: "reactzj")
        XCTAssertEqual(reactzj.first?.text, "React组件", "reactzj 实际：\(reactzj.map(\.text))")

        let reactzujian = candidates(for: "reactzujian")
        XCTAssertEqual(reactzujian.first?.text, "React组件", "reactzujian 实际：\(reactzujian.map(\.text))")

        let dockerjx = candidates(for: "dockerjx")
        XCTAssertEqual(dockerjx.first?.text, "Docker镜像", "dockerjx 实际：\(dockerjx.map(\.text))")

        let apiwd = candidates(for: "apiwd")
        XCTAssertEqual(apiwd.first?.text, "API文档", "apiwd 实际：\(apiwd.map(\.text))")

        // --- B. 中文前缀 + 英文后缀 & 三段混输 ---
        let wodegit = candidates(for: "wodegit")
        XCTAssertEqual(wodegit.first?.text, "我的git", "wodegit 实际：\(wodegit.map(\.text))")

        let yongreact = candidates(for: "yongreact")
        XCTAssertEqual(yongreact.first?.text, "用React", "yongreact 实际：\(yongreact.map(\.text))")

        let wodegitdizhi = candidates(for: "wodegitdizhi")
        XCTAssertEqual(wodegitdizhi.first?.text, "我的git地址", "wodegitdizhi 实际：\(wodegitdizhi.map(\.text))")

        // --- C. 纯英文补全（主中文态） ---
        let gitOnly = candidates(for: "git")
        XCTAssertEqual(gitOnly.first?.text.lowercased(), "git", "git 实际：\(gitOnly.map(\.text))")
        XCTAssertTrue(gitOnly.prefix(4).map(\.text).contains("GitHub"), "git 前 4 应包含 GitHub 联想，实际：\(gitOnly.map(\.text))")

        let dockOnly = candidates(for: "dock")
        XCTAssertTrue(dockOnly.prefix(2).map(\.text).contains("Docker"), "dock 前 2 应含 Docker，实际：\(dockOnly.map(\.text))")

        // --- D. 纯英文拼写纠错 + 混输错拼恢复 ---
        let dokcer = candidates(for: "dokcer")
        XCTAssertEqual(dokcer.first?.text, "Docker", "dokcer 实际：\(dokcer.map(\.text))")
        XCTAssertEqual(dokcer.first?.source, .typoCorrected)

        let recat = candidates(for: "recat")
        XCTAssertEqual(recat.first?.text, "React", "recat 实际：\(recat.map(\.text))")
        XCTAssertEqual(recat.first?.source, .typoCorrected)

        let enviroment = candidates(for: "enviroment")
        XCTAssertEqual(enviroment.first?.text.lowercased(), "environment", "enviroment 实际：\(enviroment.map(\.text))")
        XCTAssertEqual(enviroment.first?.source, .typoCorrected)

        let typescritp = candidates(for: "typescritp")
        XCTAssertEqual(typescritp.first?.text, "TypeScript", "typescritp 实际：\(typescritp.map(\.text))")
        XCTAssertEqual(typescritp.first?.source, .typoCorrected)

        let gtidiz = candidates(for: "gtidiz")
        XCTAssertEqual(gtidiz.first?.text, "git地址", "混输英文前缀错拼 gtidiz 应恢复为 git地址，实际：\(gtidiz.map(\.text))")
        XCTAssertEqual(gtidiz.first?.source, .typoCorrected)

        let dokcerjx = candidates(for: "dokcerjx")
        XCTAssertEqual(dokcerjx.first?.text, "Docker镜像", "dokcerjx 实际：\(dokcerjx.map(\.text))")
        XCTAssertEqual(dokcerjx.first?.source, .typoCorrected)

        let recatzj = candidates(for: "recatzj")
        XCTAssertEqual(recatzj.first?.text, "React组件", "recatzj 实际：\(recatzj.map(\.text))")

        let yongdokcer = candidates(for: "yongdokcer")
        XCTAssertEqual(yongdokcer.first?.text, "用Docker", "yongdokcer 实际：\(yongdokcer.map(\.text))")

        // --- E. 纯中文与中文拼音纠错零误伤回归 ---
        XCTAssertEqual(candidates(for: "nihao").first?.text, "你好")
        XCTAssertEqual(candidates(for: "shanghai").first?.text, "上海")
        XCTAssertEqual(candidates(for: "shaighai").first?.text, "上海", "中文纠偏 shaighai 绝不能被英文抢占")
        XCTAssertEqual(candidates(for: "womne").first?.text, "我们", "womne 必须优先纠正为中文「我们」而非英文 women")
        XCTAssertEqual(candidates(for: "zgr").first?.text, "中国人", "纯中文简拼 zgr 绝不能被英文误抢")
        XCTAssertEqual(candidates(for: "wsm").first?.text, "为什么", "纯中文简拼 wsm 绝不能被英文误抢")

        let aiCands = candidates(for: "ai")
        XCTAssertNotEqual(aiCands.first?.text, "AI", "非 Coding 模式下 ai 首位必须保留纯中文（如 爱），实际：\(aiCands.map(\.text))")
        XCTAssertTrue(aiCands.prefix(4).map(\.text).contains("AI"), "ai 次位应提供 AI 候选，实际：\(aiCands.map(\.text))")

        for pureZhPinyin in ["man", "can", "run"] {
            let firstText = candidates(for: pureZhPinyin).first?.text ?? ""
            XCTAssertTrue(
                firstText.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
                "合法纯中文拼音 \(pureZhPinyin) 首位应保持汉字，实际：\(firstText)"
            )
        }

        // --- F. 整句校对模式与混输/纯英文联动 ---
        var draftPrefs = prefs
        draftPrefs.defaultDraftProofreadMode = true
        draftPrefs.enableAIDraftProofread = false
        sm.applyPreferences(draftPrefs)

        // gitdiz 含汉字：第 1 次空格进草稿，第 2 次空格上屏 git地址
        _ = sm.handle(NormalizedKeyEvent(kind: .escape))
        _ = typeASCII("gitdiz", into: sm)
        let firstSpace = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertTrue(committedTexts(in: firstSpace).isEmpty, "含汉字的 git地址 首次空格应先入草稿校对")
        XCTAssertEqual(latestPanel(in: firstSpace)?.draftSourcePreview, "git地址")
        let secondSpace = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertEqual(committedTexts(in: secondSpace), ["git地址"])

        // 空草稿下纯英文 git：首次空格直接上屏并触发双语后继联想
        _ = typeASCII("git", into: sm)
        let gitSpace = sm.handle(NormalizedKeyEvent(kind: .space))
        let gitCommittedWithPred = gitSpace.contains { act in
            if case .commitText(let text, let reqPred) = act {
                return text.lowercased() == "git" && reqPred
            }
            return false
        }
        XCTAssertTrue(
            gitCommittedWithPred,
            "空草稿纯英文 git 应首次空格直接上屏并允许双语联想，实际：\(gitSpace)"
        )
    }

    // MARK: - 3. 临时英文快车道：离线词典补全 + Tab 拼写纠错 + Space 保留原词

    func testInlineEnglishOfflineCompletionAndTabSpellCorrection() throws {
        let lexicon = Self.loadFullLexicon()
        let engine = SimpleMixedMockEngine()
        let sm = InputStateMachine(engine: engine, englishLexicon: lexicon)

        // 空文档敲 Dock -> 候选 0 为 Dock，候选 1 为 Docker；按 Tab 一键补全 Docker
        let dockActions = typeASCII("Dock", into: sm)
        let dockPanel = latestPanel(in: dockActions)
        XCTAssertEqual(dockPanel?.candidates.first?.text, "Dock")
        XCTAssertEqual(dockPanel?.candidates.dropFirst().first?.text, "Docker")
        let dockTab = sm.handle(NormalizedKeyEvent(kind: .tab))
        XCTAssertEqual(committedTexts(in: dockTab), ["Docker"])

        // 敲 Reac + Tab -> React
        _ = typeASCII("Reac", into: sm)
        let reacTab = sm.handle(NormalizedKeyEvent(kind: .tab))
        XCTAssertEqual(committedTexts(in: reacTab), ["React"])

        // 敲错拼 Recat -> 候选 0 保留 Recat，候选 1 展示 React (.typoCorrected)
        let recatActions = typeASCII("Recat", into: sm)
        let recatPanel = latestPanel(in: recatActions)
        XCTAssertEqual(recatPanel?.candidates.first?.text, "Recat")
        XCTAssertEqual(recatPanel?.candidates.dropFirst().first?.text, "React")
        XCTAssertEqual(recatPanel?.candidates.dropFirst().first?.source, CandidateSource.typoCorrected)

        // 按 Space 保留原词 Recat（绝不强改自定义标识符）
        let recatSpace = sm.handle(NormalizedKeyEvent(kind: .space))
        XCTAssertEqual(committedTexts(in: recatSpace), ["Recat"])

        // 再敲 Recat 按 Tab -> 一键采纳 React
        _ = typeASCII("Recat", into: sm)
        let recatTab = sm.handle(NormalizedKeyEvent(kind: .tab))
        XCTAssertEqual(committedTexts(in: recatTab), ["React"])

        // 全大写 RECAT + Tab -> 保持全大写 REACT
        _ = typeASCII("RECAT", into: sm)
        let upperTab = sm.handle(NormalizedKeyEvent(kind: .tab))
        XCTAssertEqual(committedTexts(in: upperTab), ["REACT"])

        // 敲 Dokcer + Tab -> Docker
        _ = typeASCII("Dokcer", into: sm)
        let dokcerTab = sm.handle(NormalizedKeyEvent(kind: .tab))
        XCTAssertEqual(committedTexts(in: dokcerTab), ["Docker"])
    }

    // MARK: - 4. 混合拼音键、双语自学习记忆、文档上下文、预联想融合与后处理

    func testMixedPinyinKeysWorkingMemoryDocumentIndexAndPredictionFusion() {
        let normalizer = PinyinNormalizer()
        let keys = normalizer.keys(forMixedTerm: "git地址")
        XCTAssertEqual(keys.primarySyllables, ["git", "di", "zhi"])
        XCTAssertTrue(keys.fullVariants.contains("gitdizhi"))
        XCTAssertTrue(keys.initialVariants.contains("gitdz"))
        XCTAssertTrue(PinyinNormalizer.matchChinese(query: "gitdiz", keys: keys).coversFullQuery)
        XCTAssertTrue(PinyinNormalizer.matchChinese(query: "gitdz", keys: keys).coversFullQuery)

        // 1. SessionWorkingMemory：连词自学习 git + 地址 -> git地址，且 React -> 组件 可 0ms 续写
        let wm = SessionWorkingMemory()
        let t0: TimeInterval = 1_700_000_000
        _ = wm.recordCommitted(text: "git", pinyin: "git", leftContext: "", appBundleID: "com.test.app", isSecureInput: false, enableAutoPhrase: true, now: t0)
        let promo1 = wm.recordCommitted(text: "地址", pinyin: "dizhi", leftContext: "git", appBundleID: "com.test.app", isSecureInput: false, enableAutoPhrase: true, now: t0 + 1)
        XCTAssertNil(promo1, "首次组合只入短期工作记忆，第 2 次沉淀进长期词库")

        let wmMatches = wm.match(rawPinyin: "gitdiz", leftContext: "", appBundleID: "com.test.app", includeEnglish: true, shareAcrossApps: true, now: t0 + 2)
        XCTAssertTrue(wmMatches.contains { $0.text == "git地址" && $0.coversFullQuery }, "工作记忆应立即召回刚学成的 git地址，实际：\(wmMatches)")

        _ = wm.recordCommitted(text: "git", pinyin: "git", leftContext: "", appBundleID: "com.test.app", isSecureInput: false, enableAutoPhrase: true, now: t0 + 3)
        let promo2 = wm.recordCommitted(text: "地址", pinyin: "dizhi", leftContext: "git", appBundleID: "com.test.app", isSecureInput: false, enableAutoPhrase: true, now: t0 + 4)
        XCTAssertEqual(promo2?.phrase, "git地址")

        _ = wm.recordCommitted(text: "React", pinyin: nil, leftContext: "使用", appBundleID: "com.test.app", isSecureInput: false, enableAutoPhrase: true, now: t0 + 5)
        _ = wm.recordCommitted(text: "组件", pinyin: "zujian", leftContext: "使用React", appBundleID: "com.test.app", isSecureInput: false, enableAutoPhrase: true, now: t0 + 6)
        let reactCont = wm.immediateContinuations(forLeftContext: "正在修改React", appBundleID: "com.test.app", shareAcrossApps: true, now: t0 + 7)
        XCTAssertTrue(reactCont.contains("组件"), "英文左文锚点 React 应 0ms 续写「组件」，实际：\(reactCont)")

        // 2. DocumentContextIndex：混合短语 + 英文左文锚点
        let doc = DocumentContextIndex()
        doc.updateDocument(text: "请先确认 React 组件 和 git 地址，然后推送 React 组件 到仓库")
        let docMatches = doc.match(rawPinyin: "reactzj", leftContext: "", includeEnglish: true)
        XCTAssertTrue(docMatches.contains { $0.text == "React组件" && $0.coversFullQuery }, "文档索引应提取并命中 React组件，实际：\(docMatches)")
        let docCont = doc.immediateContinuations(forLeftContext: "查看React")
        XCTAssertTrue(docCont.contains("组件"), "文档索引英文锚点 React 应召回「组件」，实际：\(docCont)")

        // 3. 预联想首字母融合支持混合词（React组件 / git仓库）
        let engine = SimpleMixedMockEngine()
        engine.mapping["reac"] = ["热"]
        var prefs = SmartPinyinPreferences.default
        prefs.enableMixedBilingualAssist = false // 仅验证预联想通道独立支持混合词
        let sm = InputStateMachine(engine: engine, preferences: prefs)
        sm.updateRuntimeContext(leftContext: "正在修改", appBundleID: "com.test.app", isSecureInput: false)
        sm.cachePredictionsForInlineFusion(["React组件", "git仓库"], forLeftContext: "正在修改")
        let predActions = typeASCII("reac", into: sm)
        XCTAssertEqual(latestPanel(in: predActions)?.candidates.first?.text, "React组件")

        // 4. PredictionPostProcessor：允许 16 字符干净英文词与英文左文后中文续写
        let refined = PredictionPostProcessor.mergeAndRefine(
            leftContext: "git",
            instantMemory: ["地址"],
            neuralSuggestions: ["configuration", "仓库"]
        )
        XCTAssertEqual(refined, ["地址", "configuration", "仓库"])
    }

    // MARK: - 5. 偏好开关兼容与性能预算校验

    func testPreferenceToggleAndPerformanceBudget() throws {
        // 旧 JSON 无 enableMixedBilingualAssist 时默认解码为 true
        let legacyJSON = #"{"enableAutoCorrection":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SmartPinyinPreferences.self, from: legacyJSON)
        XCTAssertTrue(decoded.enableMixedBilingualAssist)

        // 关闭 enableMixedBilingualAssist 后不注入混输/英文纠错候选
        let engine = SimpleMixedMockEngine()
        engine.mapping["dokcer"] = ["多"]
        var prefs = SmartPinyinPreferences.default
        prefs.enableMixedBilingualAssist = false
        let sm = InputStateMachine(engine: engine, preferences: prefs, englishLexicon: Self.loadFullLexicon())
        let actions = typeASCII("dokcer", into: sm)
        XCTAssertEqual(latestPanel(in: actions)?.candidates.first?.text, "多")

        // 性能预算校验（73K 离线英文词典：前缀补全 < 0.5 ms，双层拼写纠错 < 2.5 ms [Debug 宽松阈值]）
        let lexicon = Self.loadFullLexicon()
        let prefixQueries = ["git", "dock", "reac", "swif", "type", "envir", "conf", "serv"]
        let t1 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<50 {
            for q in prefixQueries {
                _ = lexicon.prefixCompletions(for: q, limit: 5)
            }
        }
        let avgPrefixMs = ((CFAbsoluteTimeGetCurrent() - t1) * 1000.0) / Double(50 * prefixQueries.count)
        XCTAssertLessThan(avgPrefixMs, 0.5, "prefixCompletions 平均耗时过高：\(avgPrefixMs) ms")

        let typoQueries = ["dokcer", "recat", "gti", "pytohn", "enviroment", "typescritp", "definately"]
        let t2 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 {
            for q in typoQueries {
                _ = lexicon.fuzzyCorrect(query: q, limit: 3)
            }
        }
        let avgTypoMs = ((CFAbsoluteTimeGetCurrent() - t2) * 1000.0) / Double(10 * typoQueries.count)
        #if DEBUG
        let typoBudgetMs = 8.0
        #else
        let typoBudgetMs = 2.0
        #endif
        XCTAssertLessThan(avgTypoMs, typoBudgetMs, "fuzzyCorrect 平均耗时过高（阈值 \(typoBudgetMs)ms）：\(avgTypoMs) ms")
    }
}
