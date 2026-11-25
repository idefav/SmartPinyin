import Foundation
import SharedIPC

/// L1 极速确定性拼音引擎的当前组合态快照
public struct PinyinEngineSnapshot: Equatable, Sendable {
    public let isComposing: Bool
    public let preedit: String
    public let rawInput: String
    public let selectedPrefix: String
    public let candidates: [PinyinCandidate]
    /// 第 1 页（pageNo == 0）额外的深层召回池（第 pageSize..<16 位，index 保存真实全局索引）
    public let extendedCandidates: [PinyinCandidate]
    public let highlightedIndex: Int
    public let pageNo: Int
    public let hasNextPage: Bool
    public let committedText: String?

    public init(
        isComposing: Bool = false,
        preedit: String = "",
        rawInput: String = "",
        selectedPrefix: String = "",
        candidates: [PinyinCandidate] = [],
        extendedCandidates: [PinyinCandidate] = [],
        highlightedIndex: Int = 0,
        pageNo: Int = 0,
        hasNextPage: Bool = false,
        committedText: String? = nil
    ) {
        self.isComposing = isComposing
        self.preedit = preedit
        self.rawInput = rawInput
        self.selectedPrefix = selectedPrefix
        self.candidates = candidates
        self.extendedCandidates = extendedCandidates
        self.highlightedIndex = highlightedIndex
        self.pageNo = pageNo
        self.hasNextPage = hasNextPage
        self.committedText = committedText
    }

    public static let idle = PinyinEngineSnapshot()

    /// 当前待上屏的完整中文句（已锁定前缀 + 当前高亮候选）
    public var bestSentence: String {
        if let committed = committedText, !committed.isEmpty {
            return committed
        }
        let highlighted = candidates.indices.contains(highlightedIndex)
            ? candidates[highlightedIndex].text
            : (candidates.first?.text ?? "")
        if selectedPrefix.isEmpty {
            return highlighted.isEmpty ? preedit : highlighted
        }
        if highlighted.hasPrefix(selectedPrefix) {
            return highlighted
        }
        return selectedPrefix + highlighted
    }
}

/// L1 确定性拼音引擎抽象契约（面向用例反转依赖，隔离 librime / 自研内核）
public protocol PinyinEngineProtocol: AnyObject {
    /// 处理单个按键事件，返回是否被引擎消费以及最新状态快照
    func processKey(keyval: Int32, mask: Int32) -> (handled: Bool, snapshot: PinyinEngineSnapshot)

    /// 直接选中当前页第 index 个候选词（0-based）
    func selectCandidateOnCurrentPage(index: Int) -> PinyinEngineSnapshot

    /// 直接按全局索引选中候选词（0-based，支持从第 1 页无损选中深层 Top-16 召回池中的词）
    func selectCandidate(globalIndex: Int) -> PinyinEngineSnapshot

    /// 翻页（forward = true 下一页，false 上一页）
    func changePage(forward: Bool) -> PinyinEngineSnapshot

    /// 移动高亮候选索引
    func moveHighlight(delta: Int) -> PinyinEngineSnapshot

    /// 强制提交当前组合并清空缓冲区
    func commitComposition() -> String?

    /// 清空当前未提交组合
    func clearComposition()

    /// 读取当前快照
    func currentSnapshot() -> PinyinEngineSnapshot

    /// 动态设置底层拼音引擎开关（如标点、繁简、Emoji、简拼）
    func setOption(_ name: String, value: Bool)

    /// 便捷方法：依次输入一串 ASCII 拼音字符（供单测与 Benchmark 使用）
    func feedASCII(_ text: String) -> PinyinEngineSnapshot

    /// 无副作用只读探针：查询纠偏拼音对应的 Top-N 候选词（绝不修改当前主会话组合状态）
    func probeCandidates(forPinyin pinyin: String, limit: Int) -> [PinyinCandidate]
}

public extension PinyinEngineProtocol {
    func selectCandidate(globalIndex: Int) -> PinyinEngineSnapshot {
        selectCandidateOnCurrentPage(index: globalIndex)
    }

    func setOption(_ name: String, value: Bool) {}

    func probeCandidates(forPinyin pinyin: String, limit: Int) -> [PinyinCandidate] {
        []
    }

    func feedASCII(_ text: String) -> PinyinEngineSnapshot {
        var latest = currentSnapshot()
        for scalar in text.unicodeScalars {
            let result = processKey(keyval: Int32(scalar.value), mask: 0)
            latest = result.snapshot
        }
        return latest
    }
}
