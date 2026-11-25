import SharedIPC
import SmartPinyinCore
import XCTest

final class SessionWorkingMemoryTests: XCTestCase {
    func testCrossNewlineAndCrossAppWorkingMemoryRecallAndContinuation() {
        var fakeNow: TimeInterval = 1_700_000_000
        let wm = SessionWorkingMemory()

        // 1. 在 T3 Code 输入完整一句并回车
        wm.finalizeCurrentSentence(
            explicitText: "系统问题出现在什么地方，需要排查缓存污染",
            appBundleID: "com.t3tools.t3code",
            isSecureInput: false,
            now: fakeNow
        )

        // 2. 30 秒后切到 Chrome 搜索框输入 "系统问题出现在" + 不完整拼音 "shenm"
        fakeNow += 30
        let crossMatches = wm.match(
            rawPinyin: "shenm",
            leftContext: "系统问题出现在",
            appBundleID: "com.google.Chrome",
            includeEnglish: true,
            shareAcrossApps: true,
            maxResults: 4,
            now: fakeNow
        )
        XCTAssertTrue(
            crossMatches.contains(where: { $0.text.contains("什么") }),
            "Expected cross-app working memory recall for shenm, got \(crossMatches)"
        )

        // 关闭跨应用共享时，Chrome 不应召回 T3 Code 的近期记忆
        let isolatedMatches = wm.match(
            rawPinyin: "shenm",
            leftContext: "系统问题出现在",
            appBundleID: "com.google.Chrome",
            includeEnglish: true,
            shareAcrossApps: false,
            maxResults: 4,
            now: fakeNow
        )
        XCTAssertTrue(isolatedMatches.isEmpty)

        // 3. 0ms 句末续写应能直接根据前文 "系统问题出现在" 推荐后续表达
        let continuations = wm.immediateContinuations(
            forLeftContext: "系统问题出现在",
            appBundleID: "com.google.Chrome",
            shareAcrossApps: true,
            limit: 3,
            now: fakeNow
        )
        XCTAssertTrue(
            continuations.contains(where: { $0.hasPrefix("什么") }),
            "Expected working memory continuation starting with 什么, got \(continuations)"
        )
    }

    func testAutoPhraseChainingAndPromotionToLongTermSQLite() {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smartpinyin-phrase-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("user_memory.sqlite3")
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        var fakeNow: TimeInterval = 1_700_000_000
        let store = UserMemoryStore(databaseURL: dbURL)
        let wm = SessionWorkingMemory()

        // 第 1 次连续选词：系统 + 问题 -> 仅进短期记忆，暂不沉淀长期库
        let firstA = wm.recordCommitted(text: "系统", pinyin: "xitong", leftContext: "", appBundleID: "com.t3tools.t3code", isSecureInput: false, now: fakeNow)
        XCTAssertNil(firstA)
        fakeNow += 2.0
        let firstB = wm.recordCommitted(text: "问题", pinyin: "wenti", leftContext: "系统", appBundleID: "com.t3tools.t3code", isSecureInput: false, now: fakeNow)
        XCTAssertNil(firstB)

        // 短期记忆立刻能用简拼 xtwt 召回「系统问题」
        let immediateHit = wm.match(
            rawPinyin: "xtwt",
            leftContext: "",
            appBundleID: "com.t3tools.t3code",
            includeEnglish: true,
            shareAcrossApps: true,
            now: fakeNow + 5
        )
        XCTAssertTrue(immediateHit.contains(where: { $0.text == "系统问题" }), "Expected 系统问题 in \(immediateHit)")

        // 第 2 次连续选词：累计达到 2 次 -> 自动沉淀进长期 SQLite 个人短语库！
        fakeNow += 30
        _ = wm.recordCommitted(text: "系统", pinyin: "xitong", leftContext: "", appBundleID: "com.t3tools.t3code", isSecureInput: false, now: fakeNow)
        fakeNow += 2.0
        let promoted = wm.recordCommitted(text: "问题", pinyin: "wenti", leftContext: "系统", appBundleID: "com.t3tools.t3code", isSecureInput: false, now: fakeNow)
        XCTAssertEqual(promoted?.phrase, "系统问题")

        if let p = promoted {
            store.recordLearnedPhrase(phrase: p.phrase, fullPinyin: p.fullPinyin, initials: p.initials, isSecureInput: false, now: fakeNow)
            store.flush()
        }

        // 重开 SQLite 验证长期沉淀持久生效，且支持简拼 xtwt 召回
        let reopened = UserMemoryStore(databaseURL: dbURL)
        XCTAssertGreaterThanOrEqual(reopened.stats().learnedPhrases, 1)
        let recalled = reopened.topPreferredWords(forPinyin: "xtwt", limit: 3, now: fakeNow + 60)
        XCTAssertTrue(recalled.contains("系统问题"), "Expected 系统问题 in long-term store, got \(recalled)")
    }

    func testIncompletePinyinPrefixMatchesLongTermMemoryAndTopContinuations() {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smartpinyin-prefix-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("user_memory.sqlite3")
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        var fakeNow: TimeInterval = 1_700_000_000
        let store = UserMemoryStore(databaseURL: dbURL)

        // 用户多次以完整拼音 shenme 选「什么」，并且常接在「出现在」之后
        for _ in 0..<3 {
            fakeNow += 10
            store.recordSelection(
                pinyin: "shenme",
                chosenWord: "什么",
                selectedRank: 0,
                skippedTopWord: nil,
                chosenFeatures: nil,
                skippedTopFeatures: nil,
                leftContext: "系统问题出现在",
                appBundleID: "com.google.Chrome",
                isSecureInput: false,
                now: fakeNow
            )
        }

        // 复现截图场景：只敲到不完整拼音 "shenm" 时，仍应准确命中「什么」的个人偏好与 3-gram 搭配！
        let sig = store.lookupSignals(
            pinyin: "shenm",
            word: "什么",
            leftContext: "系统问题出现在",
            appBundleID: "com.google.Chrome",
            now: fakeNow + 5
        )
        XCTAssertGreaterThan(sig.exactPref, 0.5, "Expected prefix pinyin match for shenm -> shenme")
        XCTAssertGreaterThan(sig.contextBigram, 1.0, "Expected 3-char context tail match for 出现在 -> 什么")

        let preferred = store.topPreferredWords(forPinyin: "shenm", limit: 3, now: fakeNow + 5)
        XCTAssertTrue(preferred.contains("什么"), "Expected prefix topPreferredWords to include 什么, got \(preferred)")

        // 0ms 个人长期搭配续写推荐
        let conts = store.topContinuations(forLeftContext: "系统问题出现在", limit: 2, now: fakeNow + 5)
        XCTAssertTrue(conts.contains("什么"), "Expected 0ms personal continuation 什么, got \(conts)")
    }

    func testContinuousNeuralScoreFusionPreservesWorkingMemoryAndReranksRest() {
        let wm = SessionWorkingMemory()
        let now: TimeInterval = 1_700_000_000
        wm.finalizeCurrentSentence(
            explicitText: "系统问题出现在什么模块",
            appBundleID: "com.t3tools.t3code",
            isSecureInput: false,
            now: now
        )

        let ranker = CandidateFusionRanker()
        let rimeCands = [
            PinyinCandidate(index: 0, text: "审美"),
            PinyinCandidate(index: 1, text: "什么"),
            PinyinCandidate(index: 2, text: "神秘"),
            PinyinCandidate(index: 3, text: "神庙")
        ]

        let base = ranker.rank(
            rimeCandidates: rimeCands,
            rawPinyin: "shenm",
            leftContext: "系统问题出现在",
            appBundleID: "com.google.Chrome",
            memoryStore: nil,
            documentIndex: nil,
            workingMemory: wm,
            preferences: .default,
            pageLimit: 7
        )

        // 模拟 Qwen3-0.6B 连续打分：给「什么」最高语境分，「神秘」次之，「审美/神庙」最低
        let neuralScores = [
            ScoredCandidate(text: "什么", score: -1.8),
            ScoredCandidate(text: "神秘", score: -4.2),
            ScoredCandidate(text: "审美", score: -6.9),
            ScoredCandidate(text: "神庙", score: -8.1)
        ]
        let merged = ranker.mergeNeuralScores(base: base, scoredCandidates: neuralScores)
        XCTAssertEqual(merged.first?.candidate.text, "什么")
        let shenmiIdx = merged.firstIndex(where: { $0.candidate.text == "神秘" }) ?? 99
        let shenmiaoIdx = merged.firstIndex(where: { $0.candidate.text == "神庙" }) ?? 0
        XCTAssertLessThan(shenmiIdx, shenmiaoIdx)
    }

    func testSensitiveTextFilterBlocksSecretsDigitsAndEmailsButAllowsCodeIdentifiers() {
        XCTAssertTrue(SensitiveTextFilter.containsSensitiveData("sk-proj-abc1234567890xyz"))
        XCTAssertTrue(SensitiveTextFilter.containsSensitiveData("ghp_1234567890abcdef1234567890"))
        XCTAssertTrue(SensitiveTextFilter.containsSensitiveData("验证码是 482910"))
        XCTAssertTrue(SensitiveTextFilter.containsSensitiveData("联系 test.user@example.com"))
        XCTAssertTrue(SensitiveTextFilter.containsSensitiveData("api_key=mysecretvalue123"))

        // 正常中文技术句与长驼峰类名绝不误杀
        XCTAssertFalse(SensitiveTextFilter.containsSensitiveData("系统问题出现在 SmartPinyinInputController 排序模块"))
        XCTAssertTrue(SensitiveTextFilter.isSafeMemoryToken("SmartPinyinInputController"))
        XCTAssertTrue(SensitiveTextFilter.isSafeMemoryToken("系统问题"))

        // 工作记忆自动丢弃敏感句子
        let wm = SessionWorkingMemory()
        wm.finalizeCurrentSentence(
            explicitText: "我的密码是 sk-secret-123456789",
            appBundleID: "com.t3tools.t3code",
            isSecureInput: false
        )
        XCTAssertEqual(wm.stats().sentenceCount, 0)
    }
}
