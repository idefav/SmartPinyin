import Foundation
import PinyinEngineCore
import XCTest

final class PinyinEngineIntegrationTests: XCTestCase {
    func testWanxiangPinyinAndAbbreviation() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dataDir = projectRoot.appendingPathComponent("Resources/RimeData")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dataDir.path), "RimeData not present")

        let tempUser = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartPinyinTest_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempUser) }

        let engine = RimeEngineAdapter(
            bundledDataDirectory: dataDir,
            userDataDirectory: tempUser,
            preferredSchemaID: "wanxiang"
        )

        // 全拼整句
        let fullSnap = engine.feedASCII("nihaoshijie")
        XCTAssertTrue(fullSnap.isComposing)
        XCTAssertFalse(fullSnap.candidates.isEmpty)

        // 简拼 zgr -> 中国人
        engine.clearComposition()
        let abbrSnap = engine.feedASCII("zgr")
        XCTAssertTrue(abbrSnap.candidates.prefix(5).map(\.text).contains("中国人"))

        // 简拼 wsm -> 为什么
        engine.clearComposition()
        let wsmSnap = engine.feedASCII("wsm")
        XCTAssertTrue(wsmSnap.candidates.prefix(5).map(\.text).contains("为什么"))

        // P1-4: 验证真实 librime 1.17.0 在首页填充 Top-16 深层候选池且支持按 globalIndex 无损选词
        engine.clearComposition()
        let deepSnap = engine.feedASCII("shenm")
        XCTAssertEqual(deepSnap.pageNo, 0)
        XCTAssertFalse(deepSnap.extendedCandidates.isEmpty, "Expected librime Top-16 deep candidate pool on Page 0")
        let firstDeep = try XCTUnwrap(deepSnap.extendedCandidates.first)
        XCTAssertGreaterThanOrEqual(firstDeep.index, deepSnap.candidates.count)
        XCTAssertLessThan(firstDeep.index, 16)
        let afterGlobalSelect = engine.selectCandidate(globalIndex: firstDeep.index)
        XCTAssertEqual(afterGlobalSelect.committedText, firstDeep.text)
    }
}
