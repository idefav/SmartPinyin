import SharedIPC
import SmartPinyinCore
import XCTest

final class DocumentContextIndexTests: XCTestCase {
    func testChinesePinyinAbbrevAndPolyphoneRecallFromDocument() {
        let index = DocumentContextIndex()
        let doc = """
        本次优化重点解决智能排序与重排策略问题，通过本地偏好记忆实现越用越懂你。
        在银行系统和音乐播放器里也能保持稳定响应。
        """
        index.updateDocument(text: doc, cursorOffset: doc.count)

        // 简拼 phjy -> 偏好记忆
        let phjy = index.match(rawPinyin: "phjy", leftContext: "", includeEnglish: true)
        XCTAssertTrue(phjy.contains(where: { $0.text.contains("偏好记忆") }), "Expected 偏好记忆 in \(phjy)")

        // 多音字简拼 cp -> 重排（CFStringTransform 默认会给 zhongpai，验证多音字表兜底生效）
        let cp = index.match(rawPinyin: "cp", leftContext: "", includeEnglish: true)
        XCTAssertTrue(cp.contains(where: { $0.text == "重排" }), "Expected 重排 via polyphone cp in \(cp)")

        // 多音字 yh -> 银行，yy -> 音乐
        let yh = index.match(rawPinyin: "yh", leftContext: "", includeEnglish: true)
        XCTAssertTrue(yh.contains(where: { $0.text == "银行" }), "Expected 银行 via polyphone yh in \(yh)")

        let yy = index.match(rawPinyin: "yy", leftContext: "", includeEnglish: true)
        XCTAssertTrue(yy.contains(where: { $0.text == "音乐" }), "Expected 音乐 via polyphone yy in \(yy)")
    }

    func testAnchorContinuationPredictsNextPhraseWithSingleOrMultiLetterPinyin() {
        let index = DocumentContextIndex()
        let doc = """
        项目架构由本地推理服务负责调度。我们正在重构本地推理服务和候选排序模块。
        下次升级还会继续增强本地推理服务。
        """
        index.updateDocument(text: doc, cursorOffset: doc.count)

        // 当用户光标前刚打完「本地」，再敲一个 t 或 tlfw 简拼即可高分召回「推理」或「推理服务」
        let hits = index.match(rawPinyin: "tl", leftContext: "正在调试本地", includeEnglish: true)
        XCTAssertTrue(
            hits.contains(where: { ($0.text == "推理" || $0.text == "推理服务") && $0.continuationScore > 0 }),
            "Expected anchor continuation for 本地 -> 推理/推理服务, got \(hits)"
        )

        // 无拼音时也能 0ms 给出高置信锚点续写
        let immediate = index.immediateContinuations(forLeftContext: "正在调试本地")
        XCTAssertTrue(
            immediate.contains(where: { $0.hasPrefix("推理") }),
            "Expected immediate continuation starting with 推理, got \(immediate)"
        )
    }

    func testEnglishCodeIdentifierRecallRespectsToggle() {
        let index = DocumentContextIndex()
        let doc = """
        我们在 SmartPinyinInputController 中接入了 DocumentContextIndex 和 user_memory_store。
        """
        index.updateDocument(text: doc, cursorOffset: doc.count)

        // 开启英文/代码召回时，输入 smart 或 dci 均能召回对应标识符
        let smartHits = index.match(rawPinyin: "smart", leftContext: "", includeEnglish: true)
        XCTAssertTrue(smartHits.contains(where: { $0.text == "SmartPinyinInputController" && $0.isEnglishToken }))

        let dciHits = index.match(rawPinyin: "dci", leftContext: "", includeEnglish: true)
        XCTAssertTrue(dciHits.contains(where: { $0.text == "DocumentContextIndex" && $0.isEnglishToken }))

        let umsHits = index.match(rawPinyin: "ums", leftContext: "", includeEnglish: true)
        XCTAssertTrue(umsHits.contains(where: { $0.text == "user_memory_store" && $0.isEnglishToken }))

        // 关闭英文/代码召回开关后，不得返回英文标识符
        let disabledHits = index.match(rawPinyin: "smart", leftContext: "", includeEnglish: false)
        XCTAssertFalse(disabledHits.contains(where: { $0.isEnglishToken }))
    }

    func testFusionRankerBoostsDocumentMatchIntoCandidates() {
        let index = DocumentContextIndex()
        let doc = "请优先检查本地偏好记忆模块的写入性能，确保本地偏好记忆无阻塞。"
        index.updateDocument(text: doc, cursorOffset: doc.count)

        let ranker = CandidateFusionRanker()
        let rimeCands = [
            PinyinCandidate(index: 0, text: "配好机遇"),
            PinyinCandidate(index: 1, text: "偏好记忆")
        ]
        let ranked = ranker.rank(
            rimeCandidates: rimeCands,
            rawPinyin: "phjy",
            leftContext: "优化本地",
            appBundleID: "com.apple.Notes",
            memoryStore: nil,
            documentIndex: index,
            preferences: .default,
            pageLimit: 7
        )
        XCTAssertEqual(ranked.first?.candidate.text, "偏好记忆")
        XCTAssertEqual(ranked.first?.candidate.source, .documentContext)
        XCTAssertEqual(ranked.first?.originalRimeIndex, 1)
    }
}
