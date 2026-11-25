import Foundation
import PinyinEngineCore
import SharedIPC

/// 单字逐个选择模式会话（用于超长连续输入、找不到整句候选或用户手动按 ⌥C 逐字精准选字）：
/// - 基于合法汉语全拼音节表 + 下段前瞻贪婪切分首音节，绝不卡死在生僻词或畸形长串上
/// - 借助只读 Rime 单字探针拉取最多 96 个纯净单汉字并支持多页翻页
/// - 支持 Backspace 无损撤销上一个已选单字（恢复其拼音重新挑）、Shift+←/→ 微调当前音节长度
/// - 全部选完自动交还完整中文串（可无缝并入整句暂存区、翻译区或直接上屏）
public final class SingleCharProgressiveSession {
    public struct PickStep: Equatable, Sendable {
        public let text: String
        public let syllable: String
    }

    public enum PickOutcome: Equatable, Sendable {
        case advanced
        case completed(fullText: String)
    }

    /// 进入逐字模式前主会话已锁定的前缀汉字
    public let initialPrefix: String
    /// 是否由超长/无候选自动兜底触发（用于 UI 提示文案区分）
    public let isAutoFallback: Bool
    public private(set) var pickedSteps: [PickStep] = []
    public private(set) var remainingPinyin: String
    public private(set) var currentSyllableLength: Int = 0
    public private(set) var allCandidatesForCurrentSyllable: [PinyinCandidate] = []
    public private(set) var pageNo: Int = 0
    public private(set) var highlightedIndex: Int = 0
    public private(set) var pageSize: Int

    private let engine: PinyinEngineProtocol
    private let memoryStore: UserMemoryStore?
    private let allowMemoryPromotion: Bool

    public init(
        initialPrefix: String = "",
        rawPinyin: String,
        pageSize: Int = 7,
        isAutoFallback: Bool = false,
        engine: PinyinEngineProtocol,
        memoryStore: UserMemoryStore? = nil,
        allowMemoryPromotion: Bool = true
    ) {
        self.initialPrefix = initialPrefix
        self.remainingPinyin = rawPinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
        self.pageSize = max(5, min(9, pageSize))
        self.isAutoFallback = isAutoFallback
        self.engine = engine
        self.memoryStore = memoryStore
        self.allowMemoryPromotion = allowMemoryPromotion
        recomputeCurrentSyllableAndProbe()
    }

    /// 已逐字选定的全部汉字（含进入前已锁定的前缀）
    public var selectedText: String {
        initialPrefix + pickedSteps.map(\.text).joined()
    }

    /// 当前正在挑选的单字音节（例如 "shang"）
    public var currentSyllable: String {
        guard currentSyllableLength > 0, currentSyllableLength <= remainingPinyin.count else {
            return ""
        }
        return String(remainingPinyin.prefix(currentSyllableLength))
    }

    /// 当前音节之后的未处理剩余拼音
    public var trailingPinyin: String {
        guard currentSyllableLength > 0, currentSyllableLength <= remainingPinyin.count else {
            return remainingPinyin
        }
        return String(remainingPinyin.dropFirst(currentSyllableLength))
    }

    /// 当前页展示的候选列表（带 0..<pageSize 相对索引）
    public var currentPageCandidates: [PinyinCandidate] {
        let start = pageNo * pageSize
        guard start < allCandidatesForCurrentSyllable.count else { return [] }
        let end = min(start + pageSize, allCandidatesForCurrentSyllable.count)
        return allCandidatesForCurrentSyllable[start..<end].enumerated().map { offset, cand in
            PinyinCandidate(
                index: offset,
                text: cand.text,
                comment: cand.comment,
                source: cand.source,
                category: cand.category
            )
        }
    }

    public var hasNextPage: Bool {
        (pageNo + 1) * pageSize < allCandidatesForCurrentSyllable.count
    }

    /// 当前首音节是否真正查到了至少 1 个中文汉字候选（区分真实拼音与纯跳过占位字母）
    public var hasHanziCandidatesForCurrentSyllable: Bool {
        allCandidatesForCurrentSyllable.contains { cand in
            cand.text.unicodeScalars.contains {
                (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
            }
        }
    }

    /// 预估剩余单字总数（供顶部提示显示进度）
    public var estimatedRemainingSteps: Int {
        Self.countEstimatedSyllables(in: remainingPinyin)
    }

    /// 格式化展示在候选窗顶部的进度 preedit，例如：`我们昨天去 [shang] haiwan`
    public var formattedPreedit: String {
        let prefix = selectedText
        let cur = currentSyllable
        let tail = trailingPinyin
        var parts: [String] = []
        if !prefix.isEmpty { parts.append(prefix) }
        if !cur.isEmpty { parts.append("[\(cur)]") }
        if !tail.isEmpty { parts.append(tail) }
        return parts.joined(separator: " ")
    }

    /// 顶部紧凑交互提示
    public var progressHint: String {
        let done = pickedSteps.count
        let total = max(done + 1, done + estimatedRemainingSteps)
        let prefix = isAutoFallback ? "长串单字兜底" : "单字逐选"
        return "\(prefix) \(done + 1)/\(total) · ⇧←/→调音节 · ⌥C回词组"
    }

    /// 当前预览整句（已选汉字 + 当前高亮单字）
    public var currentPreviewText: String {
        let page = currentPageCandidates
        let curChar = page.indices.contains(highlightedIndex)
            ? page[highlightedIndex].text
            : (page.first?.text ?? "")
        return selectedText + curChar
    }

    public func updatePageSize(_ newSize: Int) {
        let clamped = max(5, min(9, newSize))
        guard clamped != pageSize else { return }
        pageSize = clamped
        pageNo = 0
        highlightedIndex = 0
    }

    /// 追加新的小写拼音字母到末尾（允许用户在逐字过程中继续打字）
    public func appendLetter(_ ch: Character) {
        let lower = String(ch).lowercased()
        guard lower.count == 1, let s = lower.unicodeScalars.first, s.value >= 97 && s.value <= 122 else { return }
        let wasEmpty = remainingPinyin.isEmpty
        remainingPinyin.append(lower)
        if wasEmpty || currentSyllableLength == remainingPinyin.count - 1 {
            recomputeCurrentSyllableAndProbe()
        }
    }

    /// 移动当前页高亮索引
    public func moveHighlight(delta: Int) {
        let pageCount = currentPageCandidates.count
        guard pageCount > 0 else { return }
        highlightedIndex = max(0, min(pageCount - 1, highlightedIndex + delta))
    }

    /// 翻页（- / = / PageUp / PageDown）
    public func changePage(forward: Bool) {
        if forward {
            if hasNextPage {
                pageNo += 1
                highlightedIndex = 0
            }
        } else if pageNo > 0 {
            pageNo -= 1
            highlightedIndex = 0
        }
    }

    /// Shift + ← / → 微调当前首音节切分长度（例如 [xian] 缩为 [xi] 留 an，或 [xi] 扩回 [xian]）
    @discardableResult
    public func adjustSyllableBoundary(delta: Int) -> Bool {
        guard !remainingPinyin.isEmpty else { return false }
        let maxLen = min(6, remainingPinyin.count)
        let target = max(1, min(maxLen, currentSyllableLength + delta))
        guard target != currentSyllableLength else { return false }
        currentSyllableLength = target
        probeCurrentSyllable()
        return true
    }

    /// 选中当前页第 index 个单字并自动推进到下一音节
    public func pickCandidateOnCurrentPage(index: Int) -> PickOutcome? {
        let page = currentPageCandidates
        guard page.indices.contains(index) else { return nil }
        let chosen = page[index]
        let consumed = currentSyllable
        guard !consumed.isEmpty else { return nil }

        pickedSteps.append(PickStep(text: chosen.text, syllable: consumed))
        remainingPinyin = String(remainingPinyin.dropFirst(consumed.count))
        if remainingPinyin.isEmpty {
            currentSyllableLength = 0
            allCandidatesForCurrentSyllable = []
            pageNo = 0
            highlightedIndex = 0
            return .completed(fullText: selectedText)
        }
        recomputeCurrentSyllableAndProbe()
        return .advanced
    }

    /// Backspace：
    /// - 若已逐字选过汉字，优先撤销最后一个已选单字并恢复其拼音（便于立刻重选错字！）
    /// - 若尚未选过单字，则删除剩余拼音末尾 1 个字母；删空返回 false（由状态机退出组合态）
    public func handleBackspace() -> Bool {
        if let last = pickedSteps.popLast() {
            remainingPinyin = last.syllable + remainingPinyin
            currentSyllableLength = min(last.syllable.count, remainingPinyin.count)
            probeCurrentSyllable()
            return true
        }
        guard !remainingPinyin.isEmpty else { return false }
        remainingPinyin.removeLast()
        if remainingPinyin.isEmpty {
            currentSyllableLength = 0
            allCandidatesForCurrentSyllable = []
            return false
        }
        recomputeCurrentSyllableAndProbe()
        return true
    }

    // MARK: - 音节切分与单字探针

    private func recomputeCurrentSyllableAndProbe() {
        guard !remainingPinyin.isEmpty else {
            currentSyllableLength = 0
            allCandidatesForCurrentSyllable = []
            pageNo = 0
            highlightedIndex = 0
            return
        }
        currentSyllableLength = Self.bestLeadingSyllableLength(for: remainingPinyin)
        probeCurrentSyllable()
    }

    private func probeCurrentSyllable() {
        pageNo = 0
        highlightedIndex = 0
        let syl = currentSyllable
        guard !syl.isEmpty else {
            allCandidatesForCurrentSyllable = []
            return
        }

        var probed = engine.probeSingleChars(forSyllable: syl, limit: 96)
        if probed.isEmpty {
            // 若自定义/微调边界导致非标准音节无单字，回落 probeCandidates 取单字或提供原字母跳过项
            let fallback = engine.probeCandidates(forPinyin: syl, limit: 8)
                .filter { $0.text.count == 1 }
            probed = fallback
        }

        // 融合个人记忆中的常用单字（置顶前 2 位，方便常用人名/高频字优先出现）
        if allowMemoryPromotion, let mem = memoryStore, !probed.isEmpty {
            let memChars = mem.topPreferredWords(forPinyin: syl, limit: 3).filter { $0.count == 1 }
            if !memChars.isEmpty {
                var promoted: [PinyinCandidate] = []
                var seen = Set<String>()
                for w in memChars {
                    if let match = probed.first(where: { $0.text == w }), seen.insert(w).inserted {
                        promoted.append(PinyinCandidate(
                            index: promoted.count,
                            text: match.text,
                            comment: match.comment,
                            source: .userMemory
                        ))
                    }
                }
                for cand in probed where seen.insert(cand.text).inserted {
                    promoted.append(PinyinCandidate(
                        index: promoted.count,
                        text: cand.text,
                        comment: cand.comment,
                        source: cand.source
                    ))
                }
                probed = promoted
            }
        }

        if probed.isEmpty {
            // 极端容错：遇到非法孤立字母（如误触的 v/u/i），提供原字母直出兜底项，绝不卡死
            probed = [PinyinCandidate(index: 0, text: syl, comment: "跳过", source: .rime)]
        }

        allCandidatesForCurrentSyllable = probed
    }

    /// 贪婪最长合法全拼音节切分 + 1 步下段前瞻（避免把 shangan / fangan 拆出非法孤立后缀）
    public static func bestLeadingSyllableLength(for pinyin: String) -> Int {
        guard !pinyin.isEmpty else { return 0 }
        let chars = Array(pinyin)
        let maxLen = min(6, chars.count)

        var validLengths: [Int] = []
        for len in stride(from: maxLen, through: 1, by: -1) {
            let prefix = String(chars[0..<len])
            if PinyinTypoCorrector.validSyllables.contains(prefix) {
                validLengths.append(len)
            }
        }

        if let best = validLengths.first {
            // 前瞻：若最长切分切完后剩下内容的首段无法成合法音节/声母，尝试次长切分看能否让后续更完整
            if validLengths.count > 1, best < chars.count {
                let tailAfterBest = String(chars[best...])
                if !startsWithPlausiblePinyinUnit(tailAfterBest) {
                    for alt in validLengths.dropFirst() {
                        let tailAfterAlt = String(chars[alt...])
                        if startsWithPlausiblePinyinUnit(tailAfterAlt) {
                            return alt
                        }
                    }
                }
            }
            return best
        }

        // 无全拼匹配：尝试双字母翘舌声母 zh/ch/sh（简拼），否则单字母消费
        if chars.count >= 2 {
            let two = String(chars[0..<2])
            if two == "zh" || two == "ch" || two == "sh" {
                return 2
            }
        }
        return 1
    }

    private static func startsWithPlausiblePinyinUnit(_ tail: String) -> Bool {
        guard !tail.isEmpty else { return true }
        let chars = Array(tail)
        let maxLen = min(6, chars.count)
        for len in stride(from: maxLen, through: 1, by: -1) {
            if PinyinTypoCorrector.validSyllables.contains(String(chars[0..<len])) {
                return true
            }
        }
        // 合法声母（不含独立不能起音的 i/u/v）
        if let first = chars.first, !"iuv".contains(first) {
            return true
        }
        return false
    }

    public static func countEstimatedSyllables(in pinyin: String) -> Int {
        var rest = pinyin
        var count = 0
        while !rest.isEmpty && count < 120 {
            let step = bestLeadingSyllableLength(for: rest)
            guard step > 0 else { break }
            rest = String(rest.dropFirst(step))
            count += 1
        }
        return count
    }
}
