import Foundation

/// 联想续写分支原始候选（来自 C++ 共享前缀多分支续写或记忆召回）
public struct RawContinuationBranch: Equatable, Sendable {
    public let text: String
    public let avgLogProb: Double
    public let isFromMemory: Bool

    public init(text: String, avgLogProb: Double, isFromMemory: Bool = false) {
        self.text = text
        self.avgLogProb = avgLogProb
        self.isFromMemory = isFromMemory
    }
}

/// 联想词句精炼后处理器（纯函数，SharedIPC 共享给 XPC 推理服务与 IME 宿主）：
/// 1. 最长尾首重叠剥离（如「今天天气」+「天气预报好了」->「预报好了」）
/// 2. 标点、编号、孤立虚词尾与残片清洗
/// 3. 置信度下限过滤（宁缺毋滥，淘汰低概率胡言乱语）
/// 4. 前缀包含与同质表达多样性去重（如同时有「怎么样」与「怎么样呀」保留更干练高分条）
public enum PredictionPostProcessor {
    private static let trailingTrimSet = CharacterSet(charactersIn: " \t\n\r\"“”'‘’`·•-*，。！？；：、,.!?;:()（）[]【】《》「」『』")
    private static let leadingTrimSetNoComma = CharacterSet(charactersIn: " \t\n\r\"“”'‘’`·•-*。！？；：、.!?;:()（）[]【】《》「」『』")
    private static let leadingTrimSetWithComma = CharacterSet(charactersIn: " \t\n\r\"“”'‘’`·•-*，。！？；：、,.!?;:()（）[]【】《》「」『』")
    private static let leftPunctTailSet = CharacterSet(charactersIn: "，。！？；：、,.!?;:")
    /// 不宜作为独立联想结尾的孤立连接虚词（往往表示短语被截断在半截）
    private static let danglingEndingChars: Set<Character> = ["的", "地", "得", "和", "与", "或", "及", "把", "被", "向", "从", "对", "将"]
    /// 孤立单字或极低信息量噪声词
    private static let blockedStandalone: Set<String> = [
        "的", "了", "吗", "呢", "啊", "吧", "呀", "哦", "嗯", "和", "与", "在", "是", "有", "也", "就", "都", "而", "但"
    ]
    /// 显式数字/时间线索（无此类线索时过滤小模型凭空编造的年份/日期数字，如「在2023」「是2月25」）
    private static let numericCueSubstrings: [String] = ["几点", "几号", "几月", "多少", "几个", "第", "编号", "版本", "端口", "价格", "金额"]

    /// 剥离候选头部与 leftContext 尾部的最长公共重叠子串（1...6 字符）
    /// 例如 leftContext = "今天天气", candidate = "天气预报好了" -> "预报好了"
    public static func stripSuffixPrefixOverlap(leftContext: String, candidate: String) -> String {
        let cleanLeft = leftContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLeft.isEmpty, !candidate.isEmpty else { return candidate }

        if candidate.hasPrefix(cleanLeft) {
            return String(candidate.dropFirst(cleanLeft.count))
        }

        let leftChars = Array(cleanLeft)
        let candChars = Array(candidate)
        let maxOverlap = min(6, min(leftChars.count, candChars.count))

        // 从最长重叠往短找，优先剥离 2~6 字完整词重叠
        if maxOverlap >= 2 {
            for len in stride(from: maxOverlap, through: 2, by: -1) {
                let leftTail = leftChars[(leftChars.count - len)..<leftChars.count]
                let candHead = candChars[0..<len]
                if leftTail.elementsEqual(candHead) {
                    return String(candChars.dropFirst(len))
                }
            }
        }

        // 单字重叠保护：当上文尾字与候选首字完全相同且候选较长（如「今天天气」+「气候」容易拼出「今天天气气候」），
        // 仅在不是自然叠词（如「看看」「试试」「走走」「想想」「等等」）时剔除异常复读
        if let lastLeft = leftChars.last, let firstCand = candChars.first, lastLeft == firstCand {
            let naturalRedup: Set<Character> = ["看", "试", "走", "想", "等", "听", "聊", "逛", "玩", "写", "说", "问", "查", "改"]
            if !naturalRedup.contains(lastLeft) && candChars.count >= 2 {
                return String(candChars.dropFirst(1))
            }
        }

        return candidate
    }

    /// 清洗单条联想候选并判定其合法性
    public static func sanitize(
        rawText: String,
        leftContext: String,
        allowSingleChar: Bool = false
    ) -> String? {
        let trimmedLeft = leftContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let leftEndsWithPunct: Bool = {
            guard let lastScalar = trimmedLeft.unicodeScalars.last else { return false }
            return leftPunctTailSet.contains(lastScalar)
        }()

        var s = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: #"^(\d+[\.、\)]\s*|[-•\*]\s*)"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        // 若左文未以标点结尾且分支以中文逗号起头（如「不好意思」->「，打扰一下」），保留起头逗号以便一键自然成句
        let keepLeadingComma = !leftEndsWithPunct && s.hasPrefix("，")
        s = s.trimmingCharacters(in: keepLeadingComma ? leadingTrimSetNoComma : leadingTrimSetWithComma)
        if keepLeadingComma && s.hasPrefix("，") {
            let body = stripSuffixPrefixOverlap(leftContext: trimmedLeft, candidate: String(s.dropFirst()))
                .trimmingCharacters(in: trailingTrimSet)
            s = body.isEmpty ? "" : ("，" + body)
        } else {
            s = stripSuffixPrefixOverlap(leftContext: trimmedLeft, candidate: s)
            s = s.trimmingCharacters(in: trailingTrimSet)
        }

        // 剥离尾部残缺虚词（如「问题的」->「问题」）
        while s.count >= 3, let last = s.last, danglingEndingChars.contains(last) {
            s.removeLast()
        }

        let bodyForChecks = s.hasPrefix("，") ? String(s.dropFirst()) : s
        guard !bodyForChecks.isEmpty else { return nil }
        if !allowSingleChar && bodyForChecks.count < 2 { return nil }
        if bodyForChecks.count > 10 { return nil }
        if blockedStandalone.contains(bodyForChecks) { return nil }
        if s.contains("<") || s.contains(">") || s.contains("|") { return nil }

        // 拒绝与左文末尾完全相同的复读，或起头复读左文中已出现的 >= 3 字片段（如「产品评审会，」再吐「评审会的主持人」）
        if trimmedLeft.hasSuffix(bodyForChecks) { return nil }
        if bodyForChecks.count >= 3 && (trimmedLeft.contains(bodyForChecks) || trimmedLeft.contains(String(bodyForChecks.prefix(3)))) {
            return nil
        }

        // 过滤无数字线索时模型凭空编造的年份/日期数字（如「今天天气」->「是2月25」，「请问一下」->「在2023」）
        let candHasDigits = bodyForChecks.unicodeScalars.contains { $0.value >= 48 && $0.value <= 57 }
        if candHasDigits {
            let leftHasDigits = trimmedLeft.unicodeScalars.contains { $0.value >= 48 && $0.value <= 57 }
            let leftHasNumericCue = numericCueSubstrings.contains { trimmedLeft.contains($0) }
            if !leftHasDigits && !leftHasNumericCue {
                return nil
            }
        }

        // 若上文含中文，拒绝纯 ASCII 碎片或包含控制字符的异常输出
        let leftHasChinese = trimmedLeft.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        if leftHasChinese {
            let hasChinese = bodyForChecks.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            let isCleanEnglishIdentifier = bodyForChecks.unicodeScalars.allSatisfy {
                ($0.value >= 65 && $0.value <= 90)
                    || ($0.value >= 97 && $0.value <= 122)
                    || ($0.value >= 48 && $0.value <= 57)
                    || $0.value == 95
            } && bodyForChecks.count >= 3
            guard hasChinese || isCleanEnglishIdentifier else { return nil }
        }

        return s
    }

    /// 对原生多分支候选做置信度门控、清洗与多样性去重
    public static func refineBranches(
        _ branches: [RawContinuationBranch],
        leftContext: String,
        maxSuggestions: Int = 3,
        minAvgLogProb: Double = -3.8
    ) -> [String] {
        guard maxSuggestions > 0 else { return [] }
        let sorted = branches.sorted { lhs, rhs in
            if lhs.isFromMemory != rhs.isFromMemory {
                return lhs.isFromMemory && !rhs.isFromMemory
            }
            return lhs.avgLogProb > rhs.avgLogProb
        }

        var accepted: [String] = []
        for branch in sorted {
            if !branch.isFromMemory && branch.avgLogProb < minAvgLogProb {
                continue
            }
            guard let clean = sanitize(rawText: branch.text, leftContext: leftContext) else {
                continue
            }
            if isRedundant(clean, against: accepted) {
                continue
            }
            accepted.append(clean)
            if accepted.count >= maxSuggestions { break }
        }
        return accepted
    }

    /// 融合 0ms 个人/文档/工作记忆续写与 L2 神经多分支续写（统一去重、剥离重叠、保持多样性）
    public static func mergeAndRefine(
        leftContext: String,
        instantMemory: [String],
        neuralSuggestions: [String],
        maxSuggestions: Int = 3
    ) -> [String] {
        guard maxSuggestions > 0 else { return [] }
        var result: [String] = []

        for raw in instantMemory {
            guard let clean = sanitize(rawText: raw, leftContext: leftContext) else { continue }
            if !isRedundant(clean, against: result) {
                result.append(clean)
                if result.count >= maxSuggestions { return result }
            }
        }
        for raw in neuralSuggestions {
            guard let clean = sanitize(rawText: raw, leftContext: leftContext) else { continue }
            if !isRedundant(clean, against: result) {
                result.append(clean)
                if result.count >= maxSuggestions { return result }
            }
        }
        return result
    }

    /// 多样性去重：覆盖完全重复、前缀包含、>= 3 字后缀包含（如「会是星期几」vs「是星期几」）及高二元组重叠（如「的可能原因是什么」vs「可能是什么原因」）
    private static func isRedundant(_ candidate: String, against existing: [String]) -> Bool {
        let normCand = candidate.hasPrefix("，") ? String(candidate.dropFirst()) : candidate
        let candBigrams = charBigrams(normCand)

        for rawItem in existing {
            let normItem = rawItem.hasPrefix("，") ? String(rawItem.dropFirst()) : rawItem
            if normItem == normCand { return true }
            if normItem.hasPrefix(normCand) || normCand.hasPrefix(normItem) { return true }
            if normItem.count >= 2 && normCand.count >= 2 && normItem.prefix(2) == normCand.prefix(2) {
                return true
            }
            if normItem.count >= 3 && normCand.count >= 3 && normItem.suffix(3) == normCand.suffix(3) {
                return true
            }
            if !candBigrams.isEmpty {
                let itemBigrams = charBigrams(normItem)
                if !itemBigrams.isEmpty {
                    let inter = candBigrams.intersection(itemBigrams).count
                    let minCount = min(candBigrams.count, itemBigrams.count)
                    if minCount > 0 && Double(inter) / Double(minCount) >= 0.50 {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func charBigrams(_ text: String) -> Set<String> {
        let chars = Array(text)
        guard chars.count >= 2 else { return [] }
        var out = Set<String>()
        out.reserveCapacity(chars.count - 1)
        for i in 0..<(chars.count - 1) {
            out.insert(String(chars[i...(i + 1)]))
        }
        return out
    }
}
