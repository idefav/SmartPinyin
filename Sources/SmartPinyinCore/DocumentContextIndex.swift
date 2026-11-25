import Foundation
import NaturalLanguage

/// 文本框内文档上下文检索命中结果
public struct DocumentCandidateMatch: Equatable, Sendable {
    public let text: String
    /// 拼音/简拼匹配度（0.0 ~ 2.0）
    public let lexiconMatchScore: Double
    /// 锚点上下文接续度（0.0 ~ 2.5，命中文档中「前文锚点 -> 该词」时显著高分）
    public let continuationScore: Double
    /// 是否为英文/代码标识符
    public let isEnglishToken: Bool
    /// 是否合理覆盖当前整段查询拼音（为 false 时仅用于增强 Rime 候选，不单独合成注入以免误吞长拼音）
    public let coversFullQuery: Bool

    public init(
        text: String,
        lexiconMatchScore: Double,
        continuationScore: Double,
        isEnglishToken: Bool,
        coversFullQuery: Bool = true
    ) {
        self.text = text
        self.lexiconMatchScore = lexiconMatchScore
        self.continuationScore = continuationScore
        self.isEnglishToken = isEnglishToken
        self.coversFullQuery = coversFullQuery
    }
}

/// 当前焦点文本框的离线实时词汇与上下文接续索引：
/// - 从当前文本框文本（±4000 字）提取中文词组/双词短语、英文代码标识符以及「前文锚点 → 后续词」接续表
/// - 结合用户正在敲击的拼音/简拼字母在 < 0.2ms 内精准召回文档中下一个最可能要输入的内容
public final class DocumentContextIndex: @unchecked Sendable {
    private struct IndexedChineseTerm {
        let text: String
        let keys: PinyinNormalizer.TermPinyinKeys
        let frequency: Int
        let minDistanceToCursor: Int
    }

    private struct IndexedEnglishTerm {
        let text: String
        let lower: String
        let initials: String
        let frequency: Int
    }

    private let normalizer: PinyinNormalizer
    private let lock = NSLock()

    private var lastDocumentHash: Int = 0
    private var chineseTerms: [IndexedChineseTerm] = []
    private var englishTerms: [IndexedEnglishTerm] = []
    /// 前文锚点（2~4 字） -> 紧随其后出现过的词组及其频次
    private var anchorContinuations: [String: [String: Int]] = [:]

    public init(normalizer: PinyinNormalizer = PinyinNormalizer()) {
        self.normalizer = normalizer
    }

    /// 刷新当前文本框内容索引（按文本内容哈希去重，避免重复分词）
    public func updateDocument(text: String, cursorOffset: Int? = nil) {
        let clipped = String(text.prefix(8000))
        let hash = clipped.hashValue
        lock.lock()
        if hash == lastDocumentHash {
            lock.unlock()
            return
        }
        lock.unlock()

        guard clipped.count >= 2 else {
            clear()
            return
        }

        let cursorPos = cursorOffset ?? clipped.count
        var zhFreq: [String: Int] = [:]
        var zhDist: [String: Int] = [:]
        var enFreq: [String: Int] = [:]
        var anchors: [String: [String: Int]] = [:]

        // 1. 使用系统 NaturalLanguage 分词提取中文词条、相邻双词短语与锚点接续
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = clipped
        var wordTokens: [(text: String, startOffset: Int, isChinese: Bool)] = []
        wordTokens.reserveCapacity(256)

        tokenizer.enumerateTokens(in: clipped.startIndex..<clipped.endIndex) { range, _ in
            let token = String(clipped[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return true }
            let offset = clipped.distance(from: clipped.startIndex, to: range.lowerBound)
            let isZh = Self.isPureChinese(token)
            if isZh {
                wordTokens.append((token, offset, true))
                if token.count >= 2 && token.count <= 8 {
                    zhFreq[token, default: 0] += 1
                    let d = abs(cursorPos - offset)
                    zhDist[token] = min(zhDist[token] ?? Int.max, d)
                }
            } else if Self.isEnglishIdentifier(token) {
                wordTokens.append((token, offset, false))
            }
            return true
        }

        // 用词边界正则完整提取英文与代码标识符（避免 NLTokenizer 按下划线拆断或在 25 字符处截断长驼峰类名）
        let idPattern = #"(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9_]{1,47}(?![A-Za-z0-9_])"#
        if let regex = try? NSRegularExpression(pattern: idPattern) {
            let ns = clipped as NSString
            let matches = regex.matches(in: clipped, range: NSRange(location: 0, length: ns.length))
            for m in matches.prefix(300) {
                let tok = ns.substring(with: m.range)
                // 3 字符及以上标识符全量收录；2 字符仅收录含大写或数字的专有简称（如 T3 / AI / UI / Go）
                if tok.count >= 3 || tok.contains(where: { $0.isUppercase || $0.isNumber }) {
                    enFreq[tok, default: 0] += 1
                }
            }
        }

        // 2. 构建相邻中文短语（2-gram 拼接，2~8 字）与锚点后续映射（prev -> next）
        for i in 0..<wordTokens.count {
            let cur = wordTokens[i]
            if i + 1 < wordTokens.count {
                let next = wordTokens[i + 1]
                // 仅对紧邻词（间隔 <= 2 字符）构建组合短语与接续锚点
                let gap = next.startOffset - (cur.startOffset + cur.text.count)
                if gap >= 0 && gap <= 2 {
                    if cur.isChinese && next.isChinese {
                        let combined = cur.text + next.text
                        if combined.count >= 2 && combined.count <= 8 {
                            zhFreq[combined, default: 0] += 1
                            let d = abs(cursorPos - cur.startOffset)
                            zhDist[combined] = min(zhDist[combined] ?? Int.max, d)
                        }
                    }
                    // 锚点：用前词末 2 字（或完整前词）预测下一词（或下一词+再下一词的 2~6 字短语）
                    if cur.isChinese && cur.text.count >= 2 {
                        let anchorKeys = [String(cur.text.suffix(2)), cur.text]
                        for ak in Set(anchorKeys) where ak.count >= 2 {
                            anchors[ak, default: [:]][next.text, default: 0] += 1
                            if i + 2 < wordTokens.count, next.isChinese, wordTokens[i + 2].isChinese {
                                let gap2 = wordTokens[i + 2].startOffset - (next.startOffset + next.text.count)
                                if gap2 >= 0 && gap2 <= 1 {
                                    let nextPhrase = next.text + wordTokens[i + 2].text
                                    if nextPhrase.count <= 7 {
                                        anchors[ak, default: [:]][nextPhrase, default: 0] += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // 3. 预构建拼音与简拼键（只保留前 350 个高价值中文词 + 160 个英文标识符，建索引 < 15ms）
        let topZh = zhFreq.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return (zhDist[lhs.key] ?? Int.max) < (zhDist[rhs.key] ?? Int.max)
        }.prefix(350)

        var builtZh: [IndexedChineseTerm] = []
        builtZh.reserveCapacity(topZh.count)
        for (term, freq) in topZh {
            let keys = normalizer.keys(forChineseTerm: term)
            if !keys.fullVariants.isEmpty {
                builtZh.append(IndexedChineseTerm(
                    text: term,
                    keys: keys,
                    frequency: freq,
                    minDistanceToCursor: zhDist[term] ?? 9999
                ))
            }
        }

        let topEn = enFreq.sorted { $0.value > $1.value }.prefix(160)
        var builtEn: [IndexedEnglishTerm] = []
        builtEn.reserveCapacity(topEn.count)
        for (term, freq) in topEn {
            let k = normalizer.keys(forEnglishIdentifier: term)
            builtEn.append(IndexedEnglishTerm(text: term, lower: k.lower, initials: k.initials, frequency: freq))
        }

        lock.lock()
        lastDocumentHash = hash
        chineseTerms = builtZh
        englishTerms = builtEn
        anchorContinuations = anchors
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        lastDocumentHash = 0
        chineseTerms = []
        englishTerms = []
        anchorContinuations = [:]
        lock.unlock()
    }

    /// 结合用户正在输入的拼音/简拼与光标前上文，同步召回当前文本框中最相关的词条与下一个待输短语（< 0.2ms）
    public func match(
        rawPinyin: String,
        leftContext: String,
        includeEnglish: Bool,
        maxResults: Int = 4
    ) -> [DocumentCandidateMatch] {
        let query = rawPinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
        guard !query.isEmpty else { return [] }

        let trimmedLeft = leftContext
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "，。！？、；：,.!?;: "))

        lock.lock()
        let zhSnapshot = chineseTerms
        let enSnapshot = englishTerms
        var continuationBoosts: [String: Int] = [:]
        if trimmedLeft.count >= 2 {
            for len in [4, 3, 2] where trimmedLeft.count >= len {
                let anchor = String(trimmedLeft.suffix(len))
                if let followups = anchorContinuations[anchor] {
                    for (word, cnt) in followups {
                        continuationBoosts[word, default: 0] += cnt * (len == 2 ? 1 : 2)
                    }
                }
            }
        }
        lock.unlock()

        var results: [DocumentCandidateMatch] = []

        // 1. 匹配中文文档词条（全拼 / 简拼 / 音节前缀 + 锚点接续）
        for item in zhSnapshot {
            let match = PinyinNormalizer.matchChinese(query: query, keys: item.keys)
            guard match.strength > 0 else { continue }

            let freqFactor = min(0.45, log1p(Double(item.frequency)) * 0.20)
            let proxFactor = item.minDistanceToCursor < 120 ? 0.18 : (item.minDistanceToCursor < 500 ? 0.08 : 0.0)
            let lexScore = match.strength + freqFactor + proxFactor

            let contCount = continuationBoosts[item.text] ?? 0
            let contScore = contCount > 0 ? min(2.4, 1.35 + log1p(Double(contCount)) * 0.55) : 0.0

            // 若无锚点接续且仅输入 1 个字母，不盲目注入单字母噪声词
            if query.count == 1 && contScore == 0 {
                continue
            }

            results.append(DocumentCandidateMatch(
                text: item.text,
                lexiconMatchScore: lexScore,
                continuationScore: contScore,
                isEnglishToken: false,
                coversFullQuery: match.coversFullQuery
            ))
        }

        // 2. 匹配英文/代码标识符（至少输入 2 个字母，避免单字母抢占中文常用字）
        if includeEnglish && query.count >= 2 {
            for item in enSnapshot {
                var strength = 0.0
                var covers = false
                if item.lower == query {
                    strength = 1.95
                    covers = true
                } else if item.initials.count >= 2 && item.initials == query {
                    strength = 1.55
                    covers = true
                } else if query.count >= 3 && item.lower.hasPrefix(query) {
                    strength = 1.35 + 0.35 * (Double(query.count) / Double(max(query.count, item.lower.count)))
                    covers = true
                } else if query.count >= 3 && item.initials.hasPrefix(query) {
                    let coverage = Double(query.count) / Double(max(query.count, item.initials.count))
                    strength = 1.10
                    covers = coverage >= 0.65
                }
                guard strength > 0 else { continue }

                let freqFactor = min(0.35, log1p(Double(item.frequency)) * 0.16)
                let contCount = continuationBoosts[item.text] ?? 0
                let contScore = contCount > 0 ? min(2.0, 1.15 + log1p(Double(contCount)) * 0.45) : 0.0

                results.append(DocumentCandidateMatch(
                    text: item.text,
                    lexiconMatchScore: strength + freqFactor,
                    continuationScore: contScore,
                    isEnglishToken: true,
                    coversFullQuery: covers
                ))
            }
        }

        // 按综合相关性去重排序
        var dedup: [String: DocumentCandidateMatch] = [:]
        for item in results {
            if let existing = dedup[item.text] {
                if (item.lexiconMatchScore + item.continuationScore) > (existing.lexiconMatchScore + existing.continuationScore) {
                    dedup[item.text] = item
                }
            } else {
                dedup[item.text] = item
            }
        }

        return dedup.values
            .sorted { ($0.lexiconMatchScore + $0.continuationScore) > ($1.lexiconMatchScore + $1.continuationScore) }
            .prefix(maxResults)
            .map { $0 }
    }

    /// 无拼音输入时的纯锚点续写建议（0ms 即时召回文档内紧随前文的重复表达）
    public func immediateContinuations(forLeftContext leftContext: String, limit: Int = 2) -> [String] {
        let trimmedLeft = leftContext
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "，。！？、；：,.!?;: "))
        guard trimmedLeft.count >= 2 else { return [] }

        lock.lock()
        var scores: [String: Int] = [:]
        for len in [4, 3, 2] where trimmedLeft.count >= len {
            let anchor = String(trimmedLeft.suffix(len))
            if let followups = anchorContinuations[anchor] {
                for (word, cnt) in followups {
                    scores[word, default: 0] += cnt * len
                }
            }
        }
        lock.unlock()

        return scores
            .filter { $0.key.count >= 2 && $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    /// 临时英文模式下的文档标识符前缀/驼峰首字母补全（< 0.1ms，保留原始大小写）
    public func matchEnglishCompletions(prefix: String, maxResults: Int = 4) -> [String] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lowerPrefix = trimmed.lowercased()
        let lettersOnly = lowerPrefix.filter { $0 >= "a" && $0 <= "z" }

        lock.lock()
        let snapshot = englishTerms
        lock.unlock()

        var scored: [(text: String, score: Double)] = []
        for item in snapshot {
            if item.text == trimmed { continue }
            var score = 0.0
            if item.text.hasPrefix(trimmed) {
                score = 3.0 + Double(trimmed.count) / Double(max(trimmed.count, item.text.count))
            } else if item.lower.hasPrefix(lowerPrefix) {
                score = 2.4 + Double(lowerPrefix.count) / Double(max(lowerPrefix.count, item.lower.count))
            } else if lettersOnly.count >= 2 && item.initials.hasPrefix(lettersOnly) {
                score = 1.8 + Double(lettersOnly.count) / Double(max(lettersOnly.count, item.initials.count))
            }
            guard score > 0 else { continue }
            score += min(0.4, log1p(Double(item.frequency)) * 0.15)
            scored.append((item.text, score))
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(maxResults)
            .map(\.text)
    }

    private static func isPureChinese(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    private static func isEnglishIdentifier(_ s: String) -> Bool {
        guard s.count >= 3 && s.count <= 32, let first = s.first, first.isASCII && first.isLetter else {
            return false
        }
        return s.unicodeScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122)
                || ($0.value >= 48 && $0.value <= 57)
                || $0.value == 95
        }
    }
}
