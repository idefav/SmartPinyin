import Foundation
import PinyinEngineCore
import SharedIPC
import SmartPinyinCore
import SmartPinyinInstallerCore
import XCTest

private final class LiteraryMockEngine: PinyinEngineProtocol {
    var buffer = ""
    var candidates: [String] = []
    var extended: [String] = []

    func processKey(keyval: Int32, mask: Int32) -> (handled: Bool, snapshot: PinyinEngineSnapshot) {
        if keyval == 0xff08 {
            if !buffer.isEmpty { buffer.removeLast() }
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
        let text = snap.candidates[index].text
        buffer = ""
        return PinyinEngineSnapshot(isComposing: false, committedText: text)
    }

    func selectCandidate(globalIndex: Int) -> PinyinEngineSnapshot {
        let all = candidates + extended
        guard all.indices.contains(globalIndex) else { return currentSnapshot() }
        let text = all[globalIndex]
        buffer = ""
        return PinyinEngineSnapshot(isComposing: false, committedText: text)
    }

    func changePage(forward: Bool) -> PinyinEngineSnapshot { currentSnapshot() }
    func moveHighlight(delta: Int) -> PinyinEngineSnapshot { currentSnapshot() }
    func commitComposition() -> String? {
        let first = candidates.first
        buffer = ""
        return first
    }

    func clearComposition() { buffer = "" }

    func currentSnapshot() -> PinyinEngineSnapshot {
        guard !buffer.isEmpty else { return .idle }
        let cands = candidates.enumerated().map { PinyinCandidate(index: $0.offset, text: $0.element) }
        let ext = extended.enumerated().map {
            PinyinCandidate(index: candidates.count + $0.offset, text: $0.element)
        }
        return PinyinEngineSnapshot(
            isComposing: true,
            preedit: buffer,
            rawInput: buffer,
            candidates: cands,
            extendedCandidates: ext
        )
    }
}

final class LiteraryLexiconAndSceneTests: XCTestCase {
    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testBundledLiteraryAndDomainBinaryTagStoreAccuracyAndSpeed() throws {
        let lexDir = projectRoot().appendingPathComponent("Resources/Lexicon", isDirectory: true)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: lexDir.appendingPathComponent("literary_tags.bin").path),
            "Bundled literary_tags.bin not present"
        )

        let store = DomainAndLiteraryTagStore.loadBundled(lexiconDirectory: lexDir, userTagsDirectory: nil)
        XCTAssertGreaterThan(store.idiomCount, 28_000)
        XCTAssertGreaterThan(store.poetryCount, 15_000)
        XCTAssertGreaterThan(store.domainEntryCount, 40_000)

        // 1. 经典古诗词精准命中
        for poem in ["锄禾日当午", "床前明月光", "春眠不觉晓", "海内存知己", "落霞与孤鹜齐飞", "明月几时有", "白日依山尽"] {
            XCTAssertEqual(store.literaryCategory(for: poem), .poetry, "Expected .poetry for \(poem)")
        }

        // 2. 权威成语精准命中
        for idiom in ["画蛇添足", "一心一意", "超然物外", "置之度外", "实事求是", "水落石出"] {
            XCTAssertEqual(store.literaryCategory(for: idiom), .idiom, "Expected .idiom for \(idiom)")
        }

        // 3. 普通日常四/五字词零误标（含用户截图中的非成语/非诗词词）
        for normal in ["成人读物", "吃肉动物", "成人的问题", "上海植物园", "今天天气", "人工智能"] {
            XCTAssertNil(store.literaryCategory(for: normal), "Must not misclassify \(normal)")
        }

        // 4. 繁体回退支持
        XCTAssertEqual(store.literaryCategory(for: "鋤禾日當午", allowTraditionalFallback: true), .poetry)
        XCTAssertEqual(store.literaryCategory(for: "畫蛇添足", allowTraditionalFallback: true), .idiom)

        // 5. 多领域位掩码精准覆盖（含一词多领域）
        XCTAssertNotEqual(store.domainMask(for: "特征值") & InputSceneDomain.mathematics.bitMask, 0)
        let rayMask = store.domainMask(for: "光追")
        XCTAssertNotEqual(rayMask & InputSceneDomain.gaming.bitMask, 0)
        XCTAssertNotEqual(rayMask & InputSceneDomain.artDesign.bitMask, 0)
        XCTAssertNotEqual(store.domainMask(for: "红黑树") & InputSceneDomain.computerScience.bitMask, 0)
        XCTAssertNotEqual(store.domainMask(for: "明暗交界线") & InputSceneDomain.artDesign.bitMask, 0)
        XCTAssertNotEqual(store.domainMask(for: "薛定谔方程") & InputSceneDomain.science.bitMask, 0)
        XCTAssertNotEqual(store.domainMask(for: "心电图") & InputSceneDomain.medicine.bitMask, 0)
        XCTAssertNotEqual(store.domainMask(for: "市盈率") & InputSceneDomain.financeLaw.bitMask, 0)

        // 6. 性能校验：10,000 次查表 < 60ms
        let probes = ["锄禾日当午", "成人读物", "画蛇添足", "吃肉动物", "特征值", "光追", "红黑树", "明暗交界线", "今天", "海内存知己"]
        let t0 = CFAbsoluteTimeGetCurrent()
        for i in 0..<10_000 {
            let word = probes[i % probes.count]
            _ = store.literaryCategory(for: word)
            _ = store.domainMask(for: word)
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        XCTAssertLessThan(elapsedMs, 120.0, "Tag lookup too slow: \(elapsedMs) ms")
    }

    func testStateMachineAnnotatesLiteraryBadgesWithoutAlteringSourceAndRespectsToggle() {
        let store = DomainAndLiteraryTagStore(
            idioms: ["超然物外", "画蛇添足"],
            poetry: ["锄禾日当午", "床前明月光"],
            domainTerms: [:]
        )
        let engine = LiteraryMockEngine()
        engine.candidates = ["成人读物", "吃肉动物", "超然物外", "锄禾日当午", "成人的问题"]

        var prefs = SmartPinyinPreferences.default
        prefs.showLiteraryBadges = true
        let sm = InputStateMachine(engine: engine, preferences: prefs, tagStore: store)

        func typeAndReadPanel() -> CandidatePanelSnapshot? {
            let acts = sm.handle(NormalizedKeyEvent(kind: .character("c", keyCode: 0)))
            return acts.compactMap { act -> CandidatePanelSnapshot? in
                if case .updateUI(let p) = act { return p }
                return nil
            }.last
        }

        let panelOn = typeAndReadPanel()
        XCTAssertEqual(panelOn?.candidates[0].category, nil)
        XCTAssertEqual(panelOn?.candidates[1].category, nil)
        XCTAssertEqual(panelOn?.candidates[2].category, .idiom)
        XCTAssertEqual(panelOn?.candidates[2].source, .rime)
        XCTAssertEqual(panelOn?.candidates[3].category, .poetry)
        XCTAssertEqual(panelOn?.candidates[3].source, .rime)
        XCTAssertEqual(panelOn?.candidates[4].category, nil)

        // 关闭诗词/成语开关后实时消失
        prefs.showLiteraryBadges = false
        sm.applyPreferences(prefs)
        let panelOff = typeAndReadPanel()
        XCTAssertTrue(panelOff?.candidates.allSatisfy { $0.category == nil } == true)
    }

    func testSceneContextDetectorAdaptsToMultipleDomainsAndRescuesTop16DeepPool() {
        let store = DomainAndLiteraryTagStore(
            idioms: ["画蛇添足"],
            poetry: ["锄禾日当午"],
            domainTerms: [
                "排位": InputSceneDomain.gaming.bitMask,
                "打野": InputSceneDomain.gaming.bitMask,
                "控龙": InputSceneDomain.gaming.bitMask,
                "弹反": InputSceneDomain.gaming.bitMask,
                "矩阵": InputSceneDomain.mathematics.bitMask,
                "特征值": InputSceneDomain.mathematics.bitMask,
                "正定矩阵": InputSceneDomain.mathematics.bitMask,
                "素描": InputSceneDomain.artDesign.bitMask,
                "明暗交界线": InputSceneDomain.artDesign.bitMask,
                "冷暖对比": InputSceneDomain.artDesign.bitMask,
                "化学平衡": InputSceneDomain.science.bitMask,
                "催化剂": InputSceneDomain.science.bitMask,
                "氧化还原": InputSceneDomain.science.bitMask,
            ]
        )
        let detector = SceneContextDetector()
        let prefs = SmartPinyinPreferences.default

        // 1. 游戏语境识别
        let gameState = detector.evaluate(
            appBundleID: "com.tencent.xinWeChat",
            leftContext: "这把排位打野抓人控龙太关键了，注意",
            isSecureInput: false,
            preferences: prefs,
            tagStore: store
        )
        XCTAssertEqual(gameState.primaryScene, .gaming)
        XCTAssertGreaterThanOrEqual(gameState.confidence, 0.52)

        // 2. 数学语境识别（即使在通用浏览器中也准确压过默认通用先验）
        detector.reset()
        let mathState = detector.evaluate(
            appBundleID: "com.google.Chrome",
            leftContext: "设对称正定矩阵求其特征值与",
            isSecureInput: false,
            preferences: prefs,
            tagStore: store
        )
        XCTAssertEqual(mathState.primaryScene, .mathematics)

        // 3. 美术语境 + 设计软件先验
        detector.reset()
        let artState = detector.evaluate(
            appBundleID: "com.figma.Desktop",
            leftContext: "这张素描的明暗交界线和冷暖对比",
            isSecureInput: false,
            preferences: prefs,
            tagStore: store
        )
        XCTAssertEqual(artState.primaryScene, .artDesign)

        // 4. 科学语境
        detector.reset()
        let sciState = detector.evaluate(
            appBundleID: "com.apple.Notes",
            leftContext: "该氧化还原反应在催化剂下达到化学平衡",
            isSecureInput: false,
            preferences: prefs,
            tagStore: store
        )
        XCTAssertEqual(sciState.primaryScene, .science)

        // 5. 密码框安全硬阻断：绝不激活场景
        let secureState = detector.evaluate(
            appBundleID: "com.figma.Desktop",
            leftContext: "素描明暗交界线冷暖对比",
            isSecureInput: true,
            preferences: prefs,
            tagStore: store
        )
        XCTAssertEqual(secureState.primaryScene, .general)

        // 6. CandidateFusionRanker：游戏场景激活时，从 Top-16 深层池无损捞起「弹反」并抬升至首位；通用场景下保持默认排序
        let ranker = CandidateFusionRanker()
        let page0 = [
            PinyinCandidate(index: 0, text: "单反"),
            PinyinCandidate(index: 1, text: "淡饭"),
            PinyinCandidate(index: 2, text: "蛋饭"),
            PinyinCandidate(index: 3, text: "但凡"),
            PinyinCandidate(index: 4, text: "丹凤")
        ]
        let deepPool = [
            PinyinCandidate(index: 9, text: "弹反")
        ]

        let generalRanked = ranker.rank(
            rimeCandidates: page0,
            extendedRimeCandidates: deepPool,
            rawPinyin: "danfan",
            leftContext: "",
            appBundleID: "com.apple.Notes",
            memoryStore: nil,
            documentIndex: nil,
            sceneState: .general,
            tagStore: store,
            preferences: prefs,
            pageLimit: 5
        )
        XCTAssertEqual(generalRanked.first?.candidate.text, "单反")
        XCTAssertFalse(generalRanked.map(\.candidate.text).contains("弹反"))

        let gameRanked = ranker.rank(
            rimeCandidates: page0,
            extendedRimeCandidates: deepPool,
            rawPinyin: "danfan",
            leftContext: "这把排位打野抓人控龙",
            appBundleID: "com.valvesoftware.steam",
            memoryStore: nil,
            documentIndex: nil,
            sceneState: gameState,
            tagStore: store,
            preferences: prefs,
            pageLimit: 5
        )
        XCTAssertTrue(gameRanked.prefix(2).map(\.candidate.text).contains("弹反"), "Expected gaming scene to rescue 弹反 from Top-16 deep pool, got \(gameRanked.map(\.candidate.text))")
        let rescuedItem = gameRanked.first { $0.candidate.text == "弹反" }
        XCTAssertEqual(rescuedItem?.globalRimeIndex, 9)
        XCTAssertGreaterThan(rescuedItem?.features.domainSceneBoost ?? 0, 0.5)

        // 7. 用户将游戏场景倍率调为 0.0 时，不再提权
        var mutedPrefs = prefs
        mutedPrefs.scenePriorityMultipliers[InputSceneDomain.gaming.rawValue] = 0.0
        let mutedRanked = ranker.rank(
            rimeCandidates: page0,
            extendedRimeCandidates: deepPool,
            rawPinyin: "danfan",
            leftContext: "",
            appBundleID: "com.valvesoftware.steam",
            memoryStore: nil,
            documentIndex: nil,
            sceneState: gameState,
            tagStore: store,
            preferences: mutedPrefs,
            pageLimit: 5
        )
        XCTAssertEqual(mutedRanked.first?.candidate.text, "单反")
    }

    func testLexiconManagerCustomImportSidecarTagsAndRealRimeReload() throws {
        let dataDir = projectRoot().appendingPathComponent("Resources/RimeData", isDirectory: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dataDir.path), "RimeData not present")

        let tempSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartPinyinLexMgr_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempSupport) }
        try FileManager.default.createDirectory(at: tempSupport, withIntermediateDirectories: true)

        let manager = LexiconManager(appSupportDirectory: tempSupport, postNotifications: false)

        // 构造一个包含独特自定义术语的纯文本词表（不带拼音，验证自动注音 + SMDM 侧车索引 + wanxiang.dict.yaml 动态合成）
        let txtURL = tempSupport.appendingPathComponent("my_gaming_terms.txt")
        try "星穹秘境词\t500\n光追矩阵体\t400\n".write(to: txtURL, atomically: true, encoding: .utf8)

        let rec = try manager.importCustomDictionary(from: txtURL, displayName: "我的游戏词库", domain: .gaming)
        XCTAssertEqual(rec.entryCount, 2)
        XCTAssertEqual(rec.domain, .gaming)
        XCTAssertTrue(rec.isEnabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.wanxiangDictOverrideURL.path))

        let dictOverride = try String(contentsOf: manager.wanxiangDictOverrideURL, encoding: .utf8)
        XCTAssertTrue(dictOverride.contains("dicts/\(rec.tableName)"))

        // 验证 DomainAndLiteraryTagStore 0ms 热加载用户侧车 .bin 标签
        let tagStore = DomainAndLiteraryTagStore(userTagsDirectory: manager.userTagsDirectory)
        XCTAssertNotEqual(tagStore.domainMask(for: "星穹秘境词") & InputSceneDomain.gaming.bitMask, 0)

        // 验证真实 RimeEngineAdapter 从 RimeUserData 挂载该动态词库并成功打出自定义词条
        let engine = RimeEngineAdapter(
            bundledDataDirectory: dataDir,
            userDataDirectory: manager.rimeUserDataDirectory,
            preferredSchemaID: "wanxiang"
        )
        let snap = engine.feedASCII("xingqiongmijingci")
        let allTexts = (snap.candidates + snap.extendedCandidates).map(\.text)
        XCTAssertTrue(allTexts.contains("星穹秘境词"), "Expected real Rime to recall dynamically imported term, got \(allTexts)")

        // 验证移除词库后清理覆盖文件与侧车索引
        try manager.removePack(id: rec.id)
        tagStore.reloadUserSidecarTags()
        XCTAssertEqual(tagStore.domainMask(for: "星穹秘境词"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.wanxiangDictOverrideURL.path))
    }
}
