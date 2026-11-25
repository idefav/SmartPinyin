import Foundation
import SharedIPC
import SmartPinyinCore
import XCTest

final class UserMemoryStoreTests: XCTestCase {
    private func makeTempDBURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("smartpinyin-mem-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("user_memory.sqlite3")
    }

    func testSelectionLearningAndPersistenceAcrossReopen() {
        let dbURL = makeTempDBURL()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let store = UserMemoryStore(databaseURL: dbURL)
        let baseRanker = CandidateFusionRanker()
        let rimeCandidates = [
            PinyinCandidate(index: 0, text: "程序"),
            PinyinCandidate(index: 1, text: "成序"),
            PinyinCandidate(index: 2, text: "承绪")
        ]

        // 模拟用户连续两次跳选「承绪」并跳过首位「程序」
        for step in 0..<2 {
            let ranked = baseRanker.rank(
                rimeCandidates: rimeCandidates,
                rawPinyin: "cx",
                leftContext: "修改",
                appBundleID: "com.microsoft.VSCode",
                memoryStore: store,
                documentIndex: nil,
                preferences: .default,
                pageLimit: 7
            )
            let chosen = ranked.first(where: { $0.candidate.text == "承绪" })!
            let top = ranked[0]
            store.recordSelection(
                pinyin: "cx",
                chosenWord: "承绪",
                selectedRank: chosen.candidate.index,
                skippedTopWord: top.candidate.text,
                chosenFeatures: chosen.features,
                skippedTopFeatures: top.features,
                leftContext: "修改",
                appBundleID: "com.microsoft.VSCode",
                isSecureInput: false,
                now: 1_700_000_000 + Double(step * 10)
            )
        }
        store.flush()

        let stats = store.stats()
        XCTAssertGreaterThanOrEqual(stats.pinyinEntries, 2)
        XCTAssertGreaterThanOrEqual(stats.contextBigrams, 2)
        XCTAssertGreaterThanOrEqual(stats.appEntries, 1)
        XCTAssertGreaterThanOrEqual(stats.weightUpdates, 1)

        // 重新从磁盘 SQLite 加载，验证跨重启记忆与首位进化
        let reopened = UserMemoryStore(databaseURL: dbURL)
        let afterRanked = baseRanker.rank(
            rimeCandidates: rimeCandidates,
            rawPinyin: "cx",
            leftContext: "修改",
            appBundleID: "com.microsoft.VSCode",
            memoryStore: reopened,
            documentIndex: nil,
            preferences: .default,
            pageLimit: 7
        )
        XCTAssertEqual(afterRanked.first?.candidate.text, "承绪")
        XCTAssertEqual(afterRanked.first?.originalRimeIndex, 2)
        XCTAssertEqual(afterRanked.first?.candidate.source, .userMemory)
    }

    func testUndoRegretDemotesWrongTopCandidate() {
        let dbURL = makeTempDBURL()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let store = UserMemoryStore(databaseURL: dbURL)
        let ranker = CandidateFusionRanker()
        let rimeCandidates = [
            PinyinCandidate(index: 0, text: "不聊"),
            PinyinCandidate(index: 1, text: "不了")
        ]

        // 用户误选首位「不聊」后立即退格撤销两次
        store.recordUndoRegret(pinyin: "bl", undoneWord: "不聊", isSecureInput: false, now: 1_700_000_000)
        store.recordUndoRegret(pinyin: "bl", undoneWord: "不聊", isSecureInput: false, now: 1_700_000_005)

        let ranked = ranker.rank(
            rimeCandidates: rimeCandidates,
            rawPinyin: "bl",
            leftContext: "",
            appBundleID: "com.apple.Notes",
            memoryStore: store,
            documentIndex: nil,
            preferences: .default,
            pageLimit: 7
        )
        XCTAssertEqual(ranked.first?.candidate.text, "不了")
    }

    func testSecureInputIsNeverRecordedAndResetClearsEverything() {
        let dbURL = makeTempDBURL()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let store = UserMemoryStore(databaseURL: dbURL)
        store.recordSelection(
            pinyin: "mima",
            chosenWord: "机密密码",
            selectedRank: 0,
            skippedTopWord: nil,
            chosenFeatures: nil,
            skippedTopFeatures: nil,
            leftContext: "输入",
            appBundleID: "com.apple.Safari",
            isSecureInput: true
        )
        store.flush()
        XCTAssertEqual(store.stats().pinyinEntries, 0)
        XCTAssertEqual(store.stats().contextBigrams, 0)

        // 写入普通记录后调用 resetAll 应彻底清零
        store.recordSelection(
            pinyin: "cs",
            chosenWord: "测试",
            selectedRank: 1,
            skippedTopWord: "城市",
            chosenFeatures: CandidateFeatureVector(exactPinyinPref: 1.0),
            skippedTopFeatures: CandidateFeatureVector(rimePrior: 2.0),
            leftContext: "运行",
            appBundleID: "com.apple.Terminal",
            isSecureInput: false
        )
        store.flush()
        XCTAssertGreaterThan(store.stats().pinyinEntries, 0)

        store.resetAll(postNotification: false)
        XCTAssertEqual(store.stats(), UserMemoryStats(pinyinEntries: 0, contextBigrams: 0, appEntries: 0, weightUpdates: 0))
    }

    func testPerAppSceneDifferentiation() {
        let dbURL = makeTempDBURL()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let store = UserMemoryStore(databaseURL: dbURL)
        let ranker = CandidateFusionRanker()
        let cands = [
            PinyinCandidate(index: 0, text: "线程"),
            PinyinCandidate(index: 1, text: "县城")
        ]

        // 在 VS Code 里多次输入「线程」，在微信里多次输入「县城」
        for i in 0..<3 {
            store.recordSelection(
                pinyin: "xc", chosenWord: "线程", selectedRank: 0, skippedTopWord: nil,
                chosenFeatures: nil, skippedTopFeatures: nil, leftContext: "",
                appBundleID: "com.microsoft.VSCode", isSecureInput: false,
                now: 1_700_000_000 + Double(i)
            )
            store.recordSelection(
                pinyin: "xc", chosenWord: "县城", selectedRank: 1, skippedTopWord: nil,
                chosenFeatures: nil, skippedTopFeatures: nil, leftContext: "",
                appBundleID: "com.tencent.xinWeChat", isSecureInput: false,
                now: 1_700_000_010 + Double(i)
            )
        }

        let inVSCode = ranker.rank(
            rimeCandidates: cands, rawPinyin: "xc", leftContext: "",
            appBundleID: "com.microsoft.VSCode", memoryStore: store,
            documentIndex: nil, preferences: .default, pageLimit: 7
        )
        let inWeChat = ranker.rank(
            rimeCandidates: cands, rawPinyin: "xc", leftContext: "",
            appBundleID: "com.tencent.xinWeChat", memoryStore: store,
            documentIndex: nil, preferences: .default, pageLimit: 7
        )
        XCTAssertEqual(inVSCode.first?.candidate.text, "线程")
        XCTAssertEqual(inWeChat.first?.candidate.text, "县城")
    }
}
