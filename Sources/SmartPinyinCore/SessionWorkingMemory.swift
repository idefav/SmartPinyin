import Foundation
import NaturalLanguage

/// 短期工作记忆召回结果
public struct WorkingMemoryMatch: Equatable, Sendable {
    public let text: String
    /// 主题词 / 近期短语拼音匹配度（0.0 ~ 2.2）
    public let topicMatchScore: Double
    /// 跨句/近期 2-gram / 3-gram 接续度（0.0 ~ 2.6）
    public let continuationScore: Double
    public let isEnglishToken: Bool
    /// 是否合理覆盖当前整段查询拼音（为 false 时仅用于增强已有 Rime 候选，不单独合成注入以免误吞长拼音尾段）
    public let coversFullQuery: Bool

    public init(
        text: String,
        topicMatchScore: Double,
        continuationScore: Double,
        isEnglishToken: Bool,
        coversFullQuery: Bool = true
    ) {
        self.text = text
        self.topicMatchScore = topicMatchScore
        self.continuationScore = continuationScore
        self.isEnglishToken = isEnglishToken
        self.coversFullQuery = coversFullQuery
    }
}

/// 短期工作记忆统计
public struct WorkingMemoryStats: Equatable, Sendable {
    public let sentenceCount: Int
    public let chineseTermCount: Int
    public let englishTermCount: Int
    public let transitionCount: Int

    public init(sentenceCount: Int, chineseTermCount: Int, englishTermCount: Int, transitionCount: Int) {
        self.sentenceCount = sentenceCount
        self.chineseTermCount = chineseTermCount
        self.englishTermCount = englishTermCount
        self.transitionCount = transitionCount
    }
}

/// Tier 1 短期工作记忆（纯内存热索引，跨换行 & 跨应用保留最近 40 句 / 30 分钟衰减）：
/// - 自动记忆用户前面输入过的文字、主题词、连续拼句短语与跨句 2/3-gram 转移
/// - 10 秒内相邻上屏的短词自动组合为候选短语（如 系统 + 问题 -> 系统问题）；累计 >= 2 次回调沉淀进长期 SQLite
/// - 同应用权重 1.0x，跨应用共享权重 0.75x；密码框与敏感信息经 SensitiveTextFilter 硬阻断
public final class SessionWorkingMemory: @unchecked Sendable {
    public static let didClearNotification = Notification.Name(
        "com.smartpinyin.inputmethod.SmartPinyin.workingMemoryDidClear"
    )

    private struct SentenceRecord {
        let text: String
        let appBundleID: String
        let timestamp: TimeInterval
    }

    private struct ChineseTermEntry {
        let text: String
        let keys: PinyinNormalizer.TermPinyinKeys
        var count: Int
        var recencyEMA: Double
        var lastUsedTS: TimeInterval
        var lastAppBundleID: String
    }

    private struct EnglishTermEntry {
        let text: String
        let lower: String
        let initials: String
        var count: Int
        var recencyEMA: Double
        var lastUsedTS: TimeInterval
        var lastAppBundleID: String
    }

    private struct TransitionEntry {
        let nextText: String
        var count: Int
        var recencyEMA: Double
        var lastUsedTS: TimeInterval
        var lastAppBundleID: String
    }

    private struct RecentCommitChunk {
        let text: String
        let pinyin: String
        let appBundleID: String
        let timestamp: TimeInterval
    }

    private let normalizer: PinyinNormalizer
    private let lock = NSLock()

    private var sentences: [SentenceRecord] = []
    private var activeSentenceDraft: String = ""
    private var activeSentenceAppID: String = ""
    private var chineseTerms: [String: ChineseTermEntry] = [:]
    private var englishTerms: [String: EnglishTermEntry] = [:]
    /// 前文锚点（2~4 字） -> 紧随其后出现过的词/短语
    private var transitions: [String: [String: TransitionEntry]] = [:]
    /// 最近一次上屏短词（用于 10 秒内自动连词造词）
    private var lastChunk: RecentCommitChunk?
    /// 连词出现次数追踪（同一组合在不同时刻累计 >= 2 次自动沉淀进长期 SQLite）
    private var chainedPhraseCounts: [String: Int] = [:]

    private static let halfLifeSeconds: TimeInterval = 30 * 60 // 30 分钟衰减半衰期
    private static let maxSentences = 40
    private static let maxTotalSentenceChars = 6000
    private static let maxChineseTerms = 320
    private static let maxEnglishTerms = 160
    private static let chainWindowSeconds: TimeInterval = 10.0

    public init(normalizer: PinyinNormalizer = PinyinNormalizer()) {
        self.normalizer = normalizer
    }

    /// 记录用户刚上屏的一段词/短语：
    /// - 实时更新短期主题词、前文锚点接续与相邻连词短语
    /// - 返回刚达到沉淀门槛（累计 >= 2 次）的自动造词 `(phrase, fullPinyin, initials)`，供调用方写入长期 SQLite
    @discardableResult
    public func recordCommitted(
        text: String,
        pinyin: String? = nil,
        leftContext: String = "",
        appBundleID: String,
        isSecureInput: Bool,
        enableAutoPhrase: Bool = true,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> (phrase: String, fullPinyin: String, initials: String)? {
        guard !isSecureInput else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, SensitiveTextFilter.isSafeMemoryToken(trimmed) else {
            lock.lock()
            lastChunk = nil
            lock.unlock()
            return nil
        }

        var promotedPhrase: (String, String, String)?

        // 预先在锁外做拼音归一化，保证锁持有时间微秒级（支持纯中文、中英混输词与英文标识符）
        let pureZh = Self.isPureChinese(trimmed)
        let isEnId = !pureZh && Self.isEnglishIdentifier(trimmed)
        let isMixedBilingual = !pureZh && !isEnId && Self.isMixedChineseEnglish(trimmed)
        let zhKeys: PinyinNormalizer.TermPinyinKeys? = {
            if pureZh && trimmed.count >= 2 && trimmed.count <= 8 {
                return normalizer.keys(forChineseTerm: trimmed)
            }
            if isMixedBilingual && trimmed.count >= 3 && trimmed.count <= 14 {
                return normalizer.keys(forMixedTerm: trimmed)
            }
            return nil
        }()
        let enKeys = isEnId ? normalizer.keys(forEnglishIdentifier: trimmed) : nil

        // 检测相邻连词候选（支持纯中文连词 + 中英混输连词，如 git + 地址 -> git地址、React + 组件 -> React组件）
        lock.lock()
        let prev = lastChunk
        lock.unlock()

        var chainedCandidate: (phrase: String, fullPinyin: String, initials: String, keys: PinyinNormalizer.TermPinyinKeys)?
        if enableAutoPhrase,
           let prev,
           prev.appBundleID == appBundleID,
           (now - prev.timestamp) <= Self.chainWindowSeconds {
            let prevIsZh = Self.isPureChinese(prev.text)
            let prevIsEn = !prevIsZh && Self.isEnglishIdentifier(prev.text)
            let canChainZhZh = pureZh && prevIsZh && trimmed.count <= 4 && prev.text.count <= 4
            let canChainEnZh = pureZh && prevIsEn && trimmed.count >= 1 && trimmed.count <= 4 && prev.text.count <= 10
            let canChainZhEn = isEnId && prevIsZh && prev.text.count >= 1 && prev.text.count <= 4 && trimmed.count <= 10
            if canChainZhZh || canChainEnZh || canChainZhEn {
                let combined = prev.text + trimmed
                let maxCombinedLen = canChainZhZh ? 6 : 14
                if combined.count >= 2 && combined.count <= maxCombinedLen && SensitiveTextFilter.isSafeMemoryToken(combined) {
                    let cKeys = canChainZhZh
                        ? normalizer.keys(forChineseTerm: combined)
                        : normalizer.keys(forMixedTerm: combined)
                    let primaryFull = cKeys.primarySyllables.joined()
                    let primaryInit = cKeys.initialVariants.first ?? ""
                    if !primaryFull.isEmpty && !primaryInit.isEmpty {
                        let exactJoinedPinyin = (canChainZhZh && !prev.pinyin.isEmpty && !(pinyin ?? "").isEmpty)
                            ? (prev.pinyin + (pinyin ?? ""))
                            : primaryFull
                        chainedCandidate = (combined, exactJoinedPinyin, primaryInit, cKeys)
                    }
                }
            }
        }

        lock.lock()
        // 1. 维护当前草稿句（切 App 时先封存旧草稿）
        if !activeSentenceDraft.isEmpty && activeSentenceAppID != appBundleID {
            let sealed = activeSentenceDraft
            let sealedApp = activeSentenceAppID
            activeSentenceDraft = ""
            appendSentenceLocked(sealed, appBundleID: sealedApp, now: now)
        }
        activeSentenceAppID = appBundleID
        activeSentenceDraft.append(text)
        if activeSentenceDraft.count > 160 {
            let sealed = activeSentenceDraft
            activeSentenceDraft = ""
            appendSentenceLocked(sealed, appBundleID: appBundleID, now: now)
        }

        // 2. 写入中文/中英混合/英文主题词
        if let zhKeys, !zhKeys.fullVariants.isEmpty {
            upsertChineseTermLocked(text: trimmed, keys: zhKeys, appBundleID: appBundleID, weight: 1.0, now: now)
        } else if let enKeys {
            upsertEnglishTermLocked(text: trimmed, lower: enKeys.lower, initials: enKeys.initials, appBundleID: appBundleID, weight: 1.0, now: now)
        }

        // 3. 记录前文锚点（2~4 字中文尾，或末尾完整英文词如 git / React） -> 当前上屏词
        let cleanLeft = Self.cleanAnchorText(leftContext)
        if cleanLeft.count >= 2 && (pureZh || isEnId || isMixedBilingual) {
            var anchorKeys = Set<String>()
            for len in [4, 3, 2] where cleanLeft.count >= len {
                anchorKeys.insert(String(cleanLeft.suffix(len)))
            }
            if let trailingEn = Self.trailingEnglishAnchor(in: cleanLeft) {
                anchorKeys.insert(trailingEn)
                anchorKeys.insert(trailingEn.lowercased())
            }
            for anchor in anchorKeys {
                upsertTransitionLocked(anchor: anchor, nextText: trimmed, appBundleID: appBundleID, weight: 1.0, now: now)
            }
        }

        // 4. 连词自动组合短语（立即写入工作记忆；累计 >= 2 次自动沉淀进长期 SQLite！）
        if let chained = chainedCandidate {
            upsertChineseTermLocked(text: chained.phrase, keys: chained.keys, appBundleID: appBundleID, weight: 0.85, now: now)
            let newCount = (chainedPhraseCounts[chained.phrase] ?? 0) + 1
            chainedPhraseCounts[chained.phrase] = newCount
            if newCount >= 2 {
                promotedPhrase = (chained.phrase, chained.fullPinyin, chained.initials)
            }
            // 同时记录「前文 -> 组合短语」的锚点接续
            if cleanLeft.count >= 2 {
                let prevLen = prev?.text.count ?? 0
                if cleanLeft.count > prevLen {
                    let beforePrev = String(cleanLeft.dropLast(prevLen))
                    for len in [4, 3, 2] where beforePrev.count >= len {
                        let anchor = String(beforePrev.suffix(len))
                        upsertTransitionLocked(anchor: anchor, nextText: chained.phrase, appBundleID: appBundleID, weight: 0.9, now: now)
                    }
                }
            }
        }

        let normPin = (pinyin ?? "").lowercased().filter { $0 >= "a" && $0 <= "z" }
        lastChunk = (pureZh || isEnId)
            ? RecentCommitChunk(text: trimmed, pinyin: normPin, appBundleID: appBundleID, timestamp: now)
            : nil

        pruneIfNeededLocked(now: now)
        lock.unlock()

        return promotedPhrase
    }

    /// 句末回车/提交时，将当前完整句子封存入环形记忆并做分词与跨句锚点抽取
    public func finalizeCurrentSentence(
        explicitText: String? = nil,
        appBundleID: String,
        isSecureInput: Bool,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        guard !isSecureInput else { return }

        let sentenceToIndex: String
        lock.lock()
        lastChunk = nil
        if let explicitText, !explicitText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sentenceToIndex = explicitText.trimmingCharacters(in: .whitespacesAndNewlines)
            activeSentenceDraft = ""
        } else {
            sentenceToIndex = activeSentenceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            activeSentenceDraft = ""
        }
        lock.unlock()

        guard sentenceToIndex.count >= 3, !SensitiveTextFilter.containsSensitiveData(sentenceToIndex) else { return }
        indexCompletedSentence(sentenceToIndex, appBundleID: appBundleID, now: now)
    }

    /// 对一句完整文本进行分词，抽取主题词、相邻 2-gram 短语、英文标识符与锚点转移（< 2ms）
    public func indexCompletedSentence(
        _ rawSentence: String,
        appBundleID: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        let sentence = String(rawSentence.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        guard sentence.count >= 3, !SensitiveTextFilter.containsSensitiveData(sentence) else { return }

        // 使用 NaturalLanguage 提取中文词组，并用词边界正则提取完整英文/代码标识符
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentence
        var tokens: [(text: String, startOffset: Int, isChinese: Bool)] = []
        tokenizer.enumerateTokens(in: sentence.startIndex..<sentence.endIndex) { range, _ in
            let tok = String(sentence[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tok.isEmpty else { return true }
            let off = sentence.distance(from: sentence.startIndex, to: range.lowerBound)
            if Self.isPureChinese(tok) {
                tokens.append((tok, off, true))
            } else if Self.isEnglishIdentifier(tok) {
                tokens.append((tok, off, false))
            }
            return true
        }

        var extractedZh: [String: PinyinNormalizer.TermPinyinKeys] = [:]
        var extractedTransitions: [(anchor: String, next: String)] = []

        for i in 0..<tokens.count {
            let cur = tokens[i]
            if cur.isChinese && cur.text.count >= 2 && cur.text.count <= 8 {
                if extractedZh[cur.text] == nil {
                    extractedZh[cur.text] = normalizer.keys(forChineseTerm: cur.text)
                }
            }
            if i + 1 < tokens.count {
                let next = tokens[i + 1]
                let gap = next.startOffset - (cur.startOffset + cur.text.count)
                if gap >= 0 && gap <= 2 {
                    if cur.isChinese && next.isChinese {
                        let combined = cur.text + next.text
                        if combined.count >= 2 && combined.count <= 6, extractedZh[combined] == nil {
                            extractedZh[combined] = normalizer.keys(forChineseTerm: combined)
                        }
                    } else if cur.isChinese != next.isChinese {
                        let combined = cur.text + next.text
                        if combined.count >= 3 && combined.count <= 14,
                           extractedZh[combined] == nil,
                           SensitiveTextFilter.isSafeMemoryToken(combined) {
                            extractedZh[combined] = normalizer.keys(forMixedTerm: combined)
                        }
                    }
                    if cur.isChinese {
                        // 直接从原句在 next 之前的真实左文取 2~4 字作锚点，避免单字介词/助词（如「出现」+「在」）断链！
                        let nextIdx = sentence.index(sentence.startIndex, offsetBy: next.startOffset)
                        let rawLeftBeforeNext = Self.cleanAnchorText(String(sentence[..<nextIdx]))
                        if rawLeftBeforeNext.count >= 2 {
                            for len in [4, 3, 2] where rawLeftBeforeNext.count >= len {
                                let ak = String(rawLeftBeforeNext.suffix(len))
                                extractedTransitions.append((ak, next.text))
                                if i + 2 < tokens.count, next.isChinese, tokens[i + 2].isChinese {
                                    let gap2 = tokens[i + 2].startOffset - (next.startOffset + next.text.count)
                                    if gap2 >= 0 && gap2 <= 1 {
                                        let phrase = next.text + tokens[i + 2].text
                                        if phrase.count <= 6 {
                                            extractedTransitions.append((ak, phrase))
                                            if extractedZh[phrase] == nil {
                                                extractedZh[phrase] = normalizer.keys(forChineseTerm: phrase)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else if cur.text.count >= 2 {
                        let lowerAnchor = cur.text.lowercased()
                        let anchors = (lowerAnchor == cur.text) ? [cur.text] : [cur.text, lowerAnchor]
                        for ak in anchors {
                            extractedTransitions.append((ak, next.text))
                            if i + 2 < tokens.count, next.isChinese, tokens[i + 2].isChinese {
                                let gap2 = tokens[i + 2].startOffset - (next.startOffset + next.text.count)
                                if gap2 >= 0 && gap2 <= 1 {
                                    let phrase = next.text + tokens[i + 2].text
                                    if phrase.count <= 6 {
                                        extractedTransitions.append((ak, phrase))
                                        if extractedZh[phrase] == nil {
                                            extractedZh[phrase] = normalizer.keys(forChineseTerm: phrase)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        var extractedEn: [(text: String, lower: String, initials: String)] = []
        let idPattern = #"(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9_]{1,47}(?![A-Za-z0-9_])"#
        if let regex = try? NSRegularExpression(pattern: idPattern) {
            let ns = sentence as NSString
            let matches = regex.matches(in: sentence, range: NSRange(location: 0, length: ns.length))
            for m in matches.prefix(32) {
                let tok = ns.substring(with: m.range)
                if (tok.count >= 3 || tok.contains(where: { $0.isUppercase || $0.isNumber })),
                   SensitiveTextFilter.isSafeMemoryToken(tok) {
                    let k = normalizer.keys(forEnglishIdentifier: tok)
                    extractedEn.append((tok, k.lower, k.initials))
                }
            }
        }

        lock.lock()
        appendSentenceLocked(sentence, appBundleID: appBundleID, now: now)
        for (term, keys) in extractedZh where !keys.fullVariants.isEmpty {
            upsertChineseTermLocked(text: term, keys: keys, appBundleID: appBundleID, weight: 0.75, now: now)
        }
        for en in extractedEn {
            upsertEnglishTermLocked(text: en.text, lower: en.lower, initials: en.initials, appBundleID: appBundleID, weight: 0.75, now: now)
        }
        for (anchor, next) in extractedTransitions {
            upsertTransitionLocked(anchor: anchor, nextText: next, appBundleID: appBundleID, weight: 0.85, now: now)
        }
        pruneIfNeededLocked(now: now)
        lock.unlock()
    }

    /// 结合当前拼音/简拼与光标左文，在 < 0.2ms 内召回短期工作记忆中的主题词与跨句续写
    public func match(
        rawPinyin: String,
        leftContext: String,
        appBundleID: String,
        includeEnglish: Bool,
        shareAcrossApps: Bool,
        maxResults: Int = 4,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [WorkingMemoryMatch] {
        let query = rawPinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
        guard !query.isEmpty else { return [] }

        let cleanLeft = Self.cleanAnchorText(leftContext)

        lock.lock()
        let zhSnap = Array(chineseTerms.values)
        let enSnap = Array(englishTerms.values)
        var contScores: [String: Double] = [:]
        if cleanLeft.count >= 2 {
            var checkedAnchors = Set<String>()
            func accumulateTransitions(anchor: String, lenBonus: Double) {
                guard checkedAnchors.insert(anchor).inserted, let map = transitions[anchor] else { return }
                for entry in map.values {
                    let appFactor = Self.appShareFactor(
                        entryApp: entry.lastAppBundleID,
                        currentApp: appBundleID,
                        shareAcrossApps: shareAcrossApps
                    )
                    guard appFactor > 0 else { continue }
                    let decayed = Self.decayed(entry.recencyEMA, lastTS: entry.lastUsedTS, now: now)
                    guard decayed >= 0.08 else { continue }
                    let score = min(2.4, (0.95 + log1p(Double(entry.count)) * 0.45 + min(0.9, decayed * 0.35)) * lenBonus * appFactor)
                    contScores[entry.nextText] = max(contScores[entry.nextText] ?? 0, score)
                }
            }
            for len in [4, 3, 2] where cleanLeft.count >= len {
                accumulateTransitions(anchor: String(cleanLeft.suffix(len)), lenBonus: len >= 3 ? 1.25 : 1.0)
            }
            if let trailingEn = Self.trailingEnglishAnchor(in: cleanLeft) {
                let bonus = trailingEn.count >= 3 ? 1.25 : 1.0
                accumulateTransitions(anchor: trailingEn, lenBonus: bonus)
                accumulateTransitions(anchor: trailingEn.lowercased(), lenBonus: bonus)
            }
        }
        lock.unlock()

        var results: [WorkingMemoryMatch] = []

        for item in zhSnap {
            let appFactor = Self.appShareFactor(
                entryApp: item.lastAppBundleID,
                currentApp: appBundleID,
                shareAcrossApps: shareAcrossApps
            )
            guard appFactor > 0 else { continue }
            let decayed = Self.decayed(item.recencyEMA, lastTS: item.lastUsedTS, now: now)
            guard decayed >= 0.08 else { continue }

            let match = PinyinNormalizer.matchChinese(query: query, keys: item.keys)
            guard match.strength > 0 else { continue }

            let cont = contScores[item.text] ?? 0
            if query.count == 1 && cont == 0 { continue }

            let freqBoost = min(0.55, log1p(Double(item.count)) * 0.22 + min(0.35, decayed * 0.16))
            let topicScore = (match.strength + freqBoost) * appFactor
            results.append(WorkingMemoryMatch(
                text: item.text,
                topicMatchScore: topicScore,
                continuationScore: cont,
                isEnglishToken: false,
                coversFullQuery: match.coversFullQuery
            ))
        }

        if includeEnglish && query.count >= 2 {
            for item in enSnap {
                let appFactor = Self.appShareFactor(
                    entryApp: item.lastAppBundleID,
                    currentApp: appBundleID,
                    shareAcrossApps: shareAcrossApps
                )
                guard appFactor > 0 else { continue }
                let decayed = Self.decayed(item.recencyEMA, lastTS: item.lastUsedTS, now: now)
                guard decayed >= 0.08 else { continue }

                var strength = 0.0
                var covers = false
                if item.lower == query {
                    strength = 1.80
                    covers = true
                } else if item.initials.count >= 2 && item.initials == query {
                    strength = 1.45
                    covers = true
                } else if query.count >= 3 && item.lower.hasPrefix(query) {
                    strength = 1.25 + 0.30 * (Double(query.count) / Double(max(query.count, item.lower.count)))
                    covers = true
                }
                guard strength > 0 else { continue }
                let cont = contScores[item.text] ?? 0
                let topicScore = (strength + min(0.35, decayed * 0.15)) * appFactor
                results.append(WorkingMemoryMatch(
                    text: item.text,
                    topicMatchScore: topicScore,
                    continuationScore: cont,
                    isEnglishToken: true,
                    coversFullQuery: covers
                ))
            }
        }

        return results
            .sorted { ($0.topicMatchScore + $0.continuationScore) > ($1.topicMatchScore + $1.continuationScore) }
            .prefix(maxResults)
            .map { $0 }
    }

    /// 0ms 句末推荐：根据当前光标前文，直接召回近期刚输入过的后续表达
    public func immediateContinuations(
        forLeftContext leftContext: String,
        appBundleID: String,
        shareAcrossApps: Bool,
        limit: Int = 2,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [String] {
        let cleanLeft = Self.cleanAnchorText(leftContext)
        guard cleanLeft.count >= 2 else { return [] }

        lock.lock()
        var scores: [String: Double] = [:]
        var checkedAnchors = Set<String>()
        func accumulateImmediate(anchor: String, weight: Double) {
            guard checkedAnchors.insert(anchor).inserted, let map = transitions[anchor] else { return }
            for entry in map.values {
                guard entry.nextText.count >= 2 else { continue }
                let appFactor = Self.appShareFactor(
                    entryApp: entry.lastAppBundleID,
                    currentApp: appBundleID,
                    shareAcrossApps: shareAcrossApps
                )
                guard appFactor > 0 else { continue }
                let decayed = Self.decayed(entry.recencyEMA, lastTS: entry.lastUsedTS, now: now)
                guard decayed >= 0.25 else { continue }
                let score = (decayed + Double(entry.count) * 0.45) * weight * appFactor
                scores[entry.nextText] = max(scores[entry.nextText] ?? 0, score)
            }
        }
        for len in [4, 3, 2] where cleanLeft.count >= len {
            accumulateImmediate(anchor: String(cleanLeft.suffix(len)), weight: Double(len))
        }
        if let trailingEn = Self.trailingEnglishAnchor(in: cleanLeft) {
            let weight = Double(min(4, trailingEn.count))
            accumulateImmediate(anchor: trailingEn, weight: weight)
            accumulateImmediate(anchor: trailingEn.lowercased(), weight: weight)
        }
        lock.unlock()

        return scores
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    /// 退格撤销同步降权：用户刚上屏后 4 秒内删掉错词时，同步削减/清除短期记忆中的词条热度、锚点转移与草稿尾部
    public func recordUndoRegret(
        undoneWord: String,
        leftContext: String = "",
        promotedPhrase: String? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        let trimmed = undoneWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        func demoteTerm(_ word: String) {
            if var zh = chineseTerms[word] {
                if zh.count <= 2 {
                    chineseTerms.removeValue(forKey: word)
                } else {
                    zh.count = max(0, zh.count - 2)
                    zh.recencyEMA = max(0, Self.decayed(zh.recencyEMA, lastTS: zh.lastUsedTS, now: now) - 1.5)
                    zh.lastUsedTS = now
                    chineseTerms[word] = zh
                }
            }
            if var en = englishTerms[word] {
                if en.count <= 2 {
                    englishTerms.removeValue(forKey: word)
                } else {
                    en.count = max(0, en.count - 2)
                    en.recencyEMA = max(0, Self.decayed(en.recencyEMA, lastTS: en.lastUsedTS, now: now) - 1.5)
                    en.lastUsedTS = now
                    englishTerms[word] = en
                }
            }
        }

        func demoteTransitions(for targetWord: String, cleanLeft: String) {
            guard cleanLeft.count >= 2 else { return }
            for len in [4, 3, 2] where cleanLeft.count >= len {
                let anchor = String(cleanLeft.suffix(len))
                if var bucket = transitions[anchor], var entry = bucket[targetWord] {
                    if entry.count <= 1 {
                        bucket.removeValue(forKey: targetWord)
                    } else {
                        entry.count -= 1
                        entry.recencyEMA = max(0, Self.decayed(entry.recencyEMA, lastTS: entry.lastUsedTS, now: now) - 1.2)
                        entry.lastUsedTS = now
                        bucket[targetWord] = entry
                    }
                    if bucket.isEmpty {
                        transitions.removeValue(forKey: anchor)
                    } else {
                        transitions[anchor] = bucket
                    }
                }
            }
        }

        let cleanLeft = Self.cleanAnchorText(leftContext)
        demoteTerm(trimmed)
        demoteTransitions(for: trimmed, cleanLeft: cleanLeft)

        if let phrase = promotedPhrase?.trimmingCharacters(in: .whitespacesAndNewlines), !phrase.isEmpty {
            demoteTerm(phrase)
            if let cnt = chainedPhraseCounts[phrase] {
                if cnt <= 1 {
                    chainedPhraseCounts.removeValue(forKey: phrase)
                } else {
                    chainedPhraseCounts[phrase] = cnt - 1
                }
            }
            demoteTransitions(for: phrase, cleanLeft: cleanLeft)
        }

        if lastChunk?.text == trimmed {
            lastChunk = nil
        }
        if activeSentenceDraft.hasSuffix(trimmed) {
            activeSentenceDraft.removeLast(trimmed.count)
        }
    }

    /// 当当前文本框左文很短（如搜索框只有 7 个字）时，为 L2 `Qwen3` 补充极短的近期话题背景（<= 40 字）
    /// 带时效与跨话题相关性门控：同应用放宽至 10 分钟，跨应用仅限 3 分钟且较长左文需存在词面相关性，防止跨话题污染
    public func recentTopicContext(
        forApp appBundleID: String,
        shareAcrossApps: Bool,
        currentLeftContext: String = "",
        maxChars: Int = 40,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> String {
        let sameAppWindow: TimeInterval = 10 * 60
        let crossAppWindow: TimeInterval = 3 * 60
        let cleanLeft = Self.cleanAnchorText(currentLeftContext)

        lock.lock()
        let recent = sentences.reversed().filter { rec in
            let factor = Self.appShareFactor(
                entryApp: rec.appBundleID,
                currentApp: appBundleID,
                shareAcrossApps: shareAcrossApps
            )
            guard factor > 0 else { return false }
            let isSameApp = rec.appBundleID.isEmpty || appBundleID.isEmpty || rec.appBundleID == appBundleID
            let age = max(0, now - rec.timestamp)
            if isSameApp {
                return age <= sameAppWindow
            }
            guard age <= crossAppWindow else { return false }
            // 当左文已有 >= 8 字且跨应用间隔 > 90 秒时，要求至少存在共享 2 字词片或英文标识符，避免无关旧话题干扰 Qwen3
            if cleanLeft.count >= 8 && age > 90 {
                return Self.sharesLexicalOverlap(cleanLeft, rec.text)
            }
            return true
        }
        lock.unlock()

        var pieces: [String] = []
        var total = 0
        for rec in recent {
            let snippet = String(rec.text.suffix(min(rec.text.count, max(12, maxChars - total))))
            guard !snippet.isEmpty else { continue }
            pieces.append(snippet)
            total += snippet.count
            if total >= maxChars { break }
        }
        return pieces.reversed().joined(separator: " ")
    }

    /// 临时英文模式下的跨应用近期标识符补全
    public func matchEnglishCompletions(
        prefix: String,
        appBundleID: String,
        shareAcrossApps: Bool,
        maxResults: Int = 3,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [String] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lowerPrefix = trimmed.lowercased()

        lock.lock()
        let snap = Array(englishTerms.values)
        lock.unlock()

        var scored: [(String, Double)] = []
        for item in snap {
            guard item.text != trimmed else { continue }
            let appFactor = Self.appShareFactor(
                entryApp: item.lastAppBundleID,
                currentApp: appBundleID,
                shareAcrossApps: shareAcrossApps
            )
            guard appFactor > 0 else { continue }
            let decayed = Self.decayed(item.recencyEMA, lastTS: item.lastUsedTS, now: now)
            guard decayed >= 0.10 else { continue }

            var score = 0.0
            if item.text.hasPrefix(trimmed) {
                score = 2.8
            } else if item.lower.hasPrefix(lowerPrefix) {
                score = 2.2
            }
            guard score > 0 else { continue }
            scored.append((item.text, (score + min(0.5, decayed * 0.2)) * appFactor))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(maxResults).map(\.0)
    }

    public func stats() -> WorkingMemoryStats {
        lock.lock()
        defer { lock.unlock() }
        let transCount = transitions.values.reduce(0) { $0 + $1.count }
        return WorkingMemoryStats(
            sentenceCount: sentences.count,
            chineseTermCount: chineseTerms.count,
            englishTermCount: englishTerms.count,
            transitionCount: transCount
        )
    }

    public func clear() {
        lock.lock()
        sentences.removeAll()
        activeSentenceDraft = ""
        activeSentenceAppID = ""
        chineseTerms.removeAll()
        englishTerms.removeAll()
        transitions.removeAll()
        lastChunk = nil
        chainedPhraseCounts.removeAll()
        lock.unlock()
    }

    // MARK: - 私有内部方法

    private func appendSentenceLocked(_ text: String, appBundleID: String, now: TimeInterval) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        guard trimmed.count >= 2 else { return }
        if sentences.last?.text == trimmed { return }
        sentences.append(SentenceRecord(text: trimmed, appBundleID: appBundleID, timestamp: now))
        if sentences.count > Self.maxSentences {
            sentences.removeFirst(sentences.count - Self.maxSentences)
        }
        var totalChars = sentences.reduce(0) { $0 + $1.text.count }
        while totalChars > Self.maxTotalSentenceChars && sentences.count > 1 {
            totalChars -= sentences.removeFirst().text.count
        }
    }

    private func upsertChineseTermLocked(
        text: String,
        keys: PinyinNormalizer.TermPinyinKeys,
        appBundleID: String,
        weight: Double,
        now: TimeInterval
    ) {
        if var existing = chineseTerms[text] {
            existing.recencyEMA = Self.decayed(existing.recencyEMA, lastTS: existing.lastUsedTS, now: now) + weight
            existing.count += 1
            existing.lastUsedTS = now
            existing.lastAppBundleID = appBundleID
            chineseTerms[text] = existing
        } else {
            chineseTerms[text] = ChineseTermEntry(
                text: text,
                keys: keys,
                count: 1,
                recencyEMA: weight,
                lastUsedTS: now,
                lastAppBundleID: appBundleID
            )
        }
    }

    private func upsertEnglishTermLocked(
        text: String,
        lower: String,
        initials: String,
        appBundleID: String,
        weight: Double,
        now: TimeInterval
    ) {
        if var existing = englishTerms[text] {
            existing.recencyEMA = Self.decayed(existing.recencyEMA, lastTS: existing.lastUsedTS, now: now) + weight
            existing.count += 1
            existing.lastUsedTS = now
            existing.lastAppBundleID = appBundleID
            englishTerms[text] = existing
        } else {
            englishTerms[text] = EnglishTermEntry(
                text: text,
                lower: lower,
                initials: initials,
                count: 1,
                recencyEMA: weight,
                lastUsedTS: now,
                lastAppBundleID: appBundleID
            )
        }
    }

    private func upsertTransitionLocked(
        anchor: String,
        nextText: String,
        appBundleID: String,
        weight: Double,
        now: TimeInterval
    ) {
        var bucket = transitions[anchor] ?? [:]
        if var existing = bucket[nextText] {
            existing.recencyEMA = Self.decayed(existing.recencyEMA, lastTS: existing.lastUsedTS, now: now) + weight
            existing.count += 1
            existing.lastUsedTS = now
            existing.lastAppBundleID = appBundleID
            bucket[nextText] = existing
        } else {
            bucket[nextText] = TransitionEntry(
                nextText: nextText,
                count: 1,
                recencyEMA: weight,
                lastUsedTS: now,
                lastAppBundleID: appBundleID
            )
        }
        transitions[anchor] = bucket
    }

    /// 返回近期高活跃中文主题词（供 0ms 场景智能识别器跨换行感知当前话题，自动遵守跨应用共享设置）
    public func recentChineseTerms(
        limit: Int = 12,
        appBundleID: String = "",
        shareAcrossApps: Bool = true,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [String] {
        guard limit > 0 else { return [] }
        lock.lock()
        let snapshot = Array(chineseTerms.values)
        lock.unlock()

        let scored: [(String, Double)] = snapshot.compactMap { entry in
            guard entry.text.count >= 2 && entry.text.count <= 8 else { return nil }
            let factor = Self.appShareFactor(
                entryApp: entry.lastAppBundleID,
                currentApp: appBundleID,
                shareAcrossApps: shareAcrossApps
            )
            guard factor > 0 else { return nil }
            let s = Self.decayed(entry.recencyEMA, lastTS: entry.lastUsedTS, now: now) * factor
            guard s >= 0.15 else { return nil }
            return (entry.text, s)
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    private func pruneIfNeededLocked(now: TimeInterval) {
        if chineseTerms.count > Self.maxChineseTerms {
            let sorted = chineseTerms.sorted {
                Self.decayed($0.value.recencyEMA, lastTS: $0.value.lastUsedTS, now: now)
                    > Self.decayed($1.value.recencyEMA, lastTS: $1.value.lastUsedTS, now: now)
            }
            chineseTerms = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.maxChineseTerms - 40).map { ($0.key, $0.value) })
        }
        if englishTerms.count > Self.maxEnglishTerms {
            let sorted = englishTerms.sorted {
                Self.decayed($0.value.recencyEMA, lastTS: $0.value.lastUsedTS, now: now)
                    > Self.decayed($1.value.recencyEMA, lastTS: $1.value.lastUsedTS, now: now)
            }
            englishTerms = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.maxEnglishTerms - 20).map { ($0.key, $0.value) })
        }
        if transitions.count > 450 {
            let keepKeys = transitions.sorted { lhs, rhs in
                let lt = lhs.value.values.map(\.lastUsedTS).max() ?? 0
                let rt = rhs.value.values.map(\.lastUsedTS).max() ?? 0
                return lt > rt
            }.prefix(380).map(\.key)
            let keepSet = Set(keepKeys)
            transitions = transitions.filter { keepSet.contains($0.key) }
        }
    }

    private static func appShareFactor(entryApp: String, currentApp: String, shareAcrossApps: Bool) -> Double {
        if entryApp.isEmpty || currentApp.isEmpty || entryApp == currentApp {
            return 1.0
        }
        return shareAcrossApps ? 0.75 : 0.0
    }

    private static func sharesLexicalOverlap(_ a: String, _ b: String) -> Bool {
        let charsA = Array(a)
        guard charsA.count >= 2 else { return true }
        for i in 0..<(charsA.count - 1) {
            let bi = String(charsA[i...(i + 1)])
            if Self.isPureChinese(bi) && b.contains(bi) {
                return true
            }
        }
        let lowerB = b.lowercased()
        let asciiWords = a.lowercased().split { !$0.isASCII || (!$0.isLetter && !$0.isNumber && $0 != "_") }
        for w in asciiWords where w.count >= 3 {
            if lowerB.contains(w) { return true }
        }
        return false
    }

    private static func cleanAnchorText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "，。！？、；：,.!?;: "))
    }

    private static func isPureChinese(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    private static func isEnglishIdentifier(_ s: String) -> Bool {
        guard s.count >= 2 && s.count <= 48, let first = s.first, first.isASCII && first.isLetter else {
            return false
        }
        return s.unicodeScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122)
                || ($0.value >= 48 && $0.value <= 57)
                || $0.value == 95
        }
    }

    private static func isMixedChineseEnglish(_ s: String) -> Bool {
        guard s.count >= 2 && s.count <= 20 else { return false }
        var hasChinese = false
        var hasASCIIAlpha = false
        for scalar in s.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
                hasChinese = true
            } else if (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122) {
                hasASCIIAlpha = true
            } else if (scalar.value >= 48 && scalar.value <= 57)
                || scalar.value == 95 || scalar.value == 45 || scalar.value == 43 || scalar.value == 46 {
                continue
            } else {
                return false
            }
        }
        return hasChinese && hasASCIIAlpha
    }

    private static func trailingEnglishAnchor(in text: String) -> String? {
        guard let last = text.last,
              last.isASCII && (last.isLetter || last.isNumber || last == "_") else {
            return nil
        }
        var chars: [Character] = []
        for ch in text.reversed() {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_") {
                chars.append(ch)
                if chars.count > 24 { return nil }
            } else {
                break
            }
        }
        let word = String(chars.reversed())
        guard word.count >= 2, let first = word.first, first.isLetter else { return nil }
        return word
    }

    private static func decayed(_ value: Double, lastTS: TimeInterval, now: TimeInterval) -> Double {
        let dt = max(0, now - lastTS)
        return value * pow(0.5, dt / halfLifeSeconds)
    }
}
