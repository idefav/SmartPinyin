import Foundation
import SharedIPC

/// 预联想首字母融合候选（刚上屏后 6 秒内保留的句末联想短语，匹配下一段拼音首字母/简拼/全拼时 0ms 融进候选栏）
public struct PendingPredictionCandidate: Equatable, Sendable {
    public let text: String
    public let rankIndex: Int
    public let matchStrength: Double

    public init(text: String, rankIndex: Int, matchStrength: Double) {
        self.text = text
        self.rankIndex = rankIndex
        self.matchStrength = matchStrength
    }
}

/// 音节纠偏探针召回候选（覆盖跨排错键 shaighai->shanghai、字母倒序、多敲连键与漏键）
public struct TypoCorrectedCandidate: Equatable, Sendable {
    public let text: String
    public let correctedPinyin: String
    public let rankInProbe: Int
    public let editCost: Double
    public let isFragmentedSource: Bool

    public init(
        text: String,
        correctedPinyin: String,
        rankInProbe: Int,
        editCost: Double,
        isFragmentedSource: Bool
    ) {
        self.text = text
        self.correctedPinyin = correctedPinyin
        self.rankInProbe = rankInProbe
        self.editCost = editCost
        self.isFragmentedSource = isFragmentedSource
    }
}

/// 融合排序后的单个候选元信息（保留原 Rime 页内/全局索引与 10 维特征向量，支持正确回写 Rime 词库与在线权重更新）
public struct RankedCandidateItem: Equatable, Sendable {
    public let candidate: PinyinCandidate
    /// 若该候选来自当前页 Rime 输出，则保留其原始 0-based 页内索引，选词时同步反馈给 librime
    public let originalRimeIndex: Int?
    /// 若该候选来自 Rime 候选列表（含首页与 Top-16 深层池），保留其全局 0-based 索引以便无损选词并保留剩余拼音
    public let globalRimeIndex: Int?
    /// 若该候选经由智能拼写纠偏召回，保存纠正后的标准拼音以便干净回写个人记忆库（绝不污染错拼）
    public let correctedPinyin: String?
    public let features: CandidateFeatureVector
    public let score: Double

    /// 该候选是否由 Rime 词典/语法支撑（非独立合成注入）
    public var isRimeBacked: Bool {
        originalRimeIndex != nil || globalRimeIndex != nil
    }

    public init(
        candidate: PinyinCandidate,
        originalRimeIndex: Int?,
        globalRimeIndex: Int? = nil,
        correctedPinyin: String? = nil,
        features: CandidateFeatureVector,
        score: Double
    ) {
        self.candidate = candidate
        self.originalRimeIndex = originalRimeIndex
        self.globalRimeIndex = globalRimeIndex ?? originalRimeIndex
        self.correctedPinyin = correctedPinyin
        self.features = features
        self.score = score
    }
}

/// 多信号同步融合排序器（L1 同步 < 0.5ms，零闪烁）：
/// - Page 0：融合万象 L1 首页 + Top-16 深层捞词 + 长期 SQLite 偏好/退格惩罚/语境搭配/应用场景 + 去重包络后的文档/工作记忆信号
/// - Page 1+：纯翻页模式，保留 Rime 原分页顺序，杜绝首页记忆词跨页重复污染
/// - L2 融合：带语义区分度门控、未打分尾部锚定、首位防抖滞后与 10 维特征回写（闭环 Pairwise 自进化）
public struct CandidateFusionRanker: Sendable {
    public init() {}

    public func rank(
        rimeCandidates: [PinyinCandidate],
        extendedRimeCandidates: [PinyinCandidate] = [],
        pageNo: Int = 0,
        excludedFirstPageTexts: Set<String> = [],
        pendingPredictions: [PendingPredictionCandidate] = [],
        typoCandidates: [TypoCorrectedCandidate] = [],
        mixedBilingualCandidates: [MixedBilingualCandidate] = [],
        rawPinyin: String,
        leftContext: String,
        appBundleID: String,
        memoryStore: UserMemoryStore?,
        documentIndex: DocumentContextIndex?,
        workingMemory: SessionWorkingMemory? = nil,
        sceneState: SceneContextState = .general,
        tagStore: DomainAndLiteraryTagStore? = nil,
        preferences: SmartPinyinPreferences,
        pageLimit: Int
    ) -> [RankedCandidateItem] {
        let effectiveLimit = max(1, pageLimit)
        let weights = memoryStore?.currentWeights() ?? RankerWeights()
        let useMemory = preferences.enablePersonalMemory && memoryStore != nil

        // 第 2 页及以上（pageNo > 0）：纯翻页模式——保留 Rime 分页序，不重复注入第 1 页记忆词，仅过滤首页已捞起的重复项
        if pageNo > 0 {
            return rankSubsequentPage(
                rimeCandidates: rimeCandidates,
                pageNo: pageNo,
                pageLimit: effectiveLimit,
                excludedFirstPageTexts: excludedFirstPageTexts,
                rawPinyin: rawPinyin,
                leftContext: leftContext,
                appBundleID: appBundleID,
                memoryStore: useMemory ? memoryStore : nil,
                weights: weights
            )
        }

        let useDoc = preferences.enableDocumentContextAssist && documentIndex != nil
        let useWorking = preferences.enableWorkingMemory && workingMemory != nil

        let docMatches: [DocumentCandidateMatch] = useDoc
            ? (documentIndex?.match(
                rawPinyin: rawPinyin,
                leftContext: leftContext,
                includeEnglish: preferences.enableDocumentEnglishTokens,
                maxResults: 4
            ) ?? [])
            : []
        let docByText = Dictionary(uniqueKeysWithValues: docMatches.map { ($0.text, $0) })

        let workMatches: [WorkingMemoryMatch] = useWorking
            ? (workingMemory?.match(
                rawPinyin: rawPinyin,
                leftContext: leftContext,
                appBundleID: appBundleID,
                includeEnglish: preferences.enableDocumentEnglishTokens,
                shareAcrossApps: preferences.shareWorkingMemoryAcrossApps,
                maxResults: 4
            ) ?? [])
            : []
        let workByText = Dictionary(uniqueKeysWithValues: workMatches.map { ($0.text, $0) })

        var predByText: [String: PendingPredictionCandidate] = [:]
        for p in pendingPredictions where predByText[p.text] == nil {
            predByText[p.text] = p
        }

        var seen = Set<String>()
        var items: [RankedCandidateItem] = []
        items.reserveCapacity(rimeCandidates.count + extendedRimeCandidates.count + pendingPredictions.count + 6)

        // 1. 评分 Rime 当前首页候选（0..<pageLimit）+ Top-16 深层池（含领域场景无损捞词）
        scoreRimePool(
            rimeCandidates: rimeCandidates,
            extendedRimeCandidates: extendedRimeCandidates,
            rawPinyin: rawPinyin,
            leftContext: leftContext,
            appBundleID: appBundleID,
            memoryStore: useMemory ? memoryStore : nil,
            docByText: docByText,
            workByText: workByText,
            predByText: predByText,
            sceneState: sceneState,
            tagStore: tagStore,
            preferences: preferences,
            weights: weights,
            seen: &seen,
            into: &items
        )

        // 1.5 注入与当前拼音（哪怕仅 1 个首字母）匹配的 0ms 句末预联想短语（上限 2 条，带「联」徽标）
        var injectedPredCount = 0
        for pred in pendingPredictions where injectedPredCount < 2 && seen.insert(pred.text).inserted {
            let sig = lookupMemorySignals(
                memoryStore: useMemory ? memoryStore : nil,
                rawPinyin: rawPinyin,
                word: pred.text,
                leftContext: leftContext,
                appBundleID: appBundleID
            )
            let predCont = max(1.65, 2.25 - 0.18 * Double(pred.rankIndex))
            let features = CandidateFeatureVector(
                rimePrior: 0.90,
                exactPinyinPref: sig.exactPref,
                regretPenalty: sig.regret,
                contextBigram: sig.bigram,
                appScenePref: sig.appPref,
                workingMemoryMatch: min(1.8, pred.matchStrength * 0.75),
                workingMemoryContinuation: predCont
            )
            items.append(RankedCandidateItem(
                candidate: PinyinCandidate(index: items.count, text: pred.text, comment: nil, source: .neuralPrediction),
                originalRimeIndex: nil,
                globalRimeIndex: nil,
                features: features,
                score: weights.score(features)
            ))
            injectedPredCount += 1
        }

        // 1.8 融合智能拼写纠偏候选（动态分档：原输入切碎时直接置顶第 1 位，原输入合法时放第 2 位并由记忆/Qwen3 语境仲裁）
        var injectedTypoCount = 0
        var typoDocCache: [String: [String: DocumentCandidateMatch]] = [:]
        var typoWorkCache: [String: [String: WorkingMemoryMatch]] = [:]
        for typo in typoCandidates where injectedTypoCount < 2 {
            let corrPin = typo.correctedPinyin
            let sig = lookupMemorySignals(
                memoryStore: useMemory ? memoryStore : nil,
                rawPinyin: corrPin,
                word: typo.text,
                leftContext: leftContext,
                appBundleID: appBundleID
            )
            if useDoc, typoDocCache[corrPin] == nil {
                let matches = documentIndex?.match(
                    rawPinyin: corrPin,
                    leftContext: leftContext,
                    includeEnglish: false,
                    maxResults: 3
                ) ?? []
                typoDocCache[corrPin] = Dictionary(uniqueKeysWithValues: matches.map { ($0.text, $0) })
            }
            if useWorking, typoWorkCache[corrPin] == nil {
                let matches = workingMemory?.match(
                    rawPinyin: corrPin,
                    leftContext: leftContext,
                    appBundleID: appBundleID,
                    includeEnglish: false,
                    shareAcrossApps: preferences.shareWorkingMemoryAcrossApps,
                    maxResults: 3
                ) ?? []
                typoWorkCache[corrPin] = Dictionary(uniqueKeysWithValues: matches.map { ($0.text, $0) })
            }
            let env = Self.contextEnvelope(
                docHit: typoDocCache[corrPin]?[typo.text],
                workHit: typoWorkCache[corrPin]?[typo.text]
            )
            let basePrior: Double
            if typo.isFragmentedSource {
                basePrior = max(1.45, 2.78 - 0.42 * Double(typo.rankInProbe) - 0.22 * typo.editCost)
            } else {
                basePrior = max(1.05, 1.92 - 0.35 * Double(typo.rankInProbe) - 0.20 * typo.editCost)
            }

            let domainBoost = SceneContextDetector.domainBoost(
                forCandidateText: typo.text,
                sceneState: sceneState,
                preferences: preferences,
                tagStore: tagStore
            )
            if seen.insert(typo.text).inserted {
                let features = CandidateFeatureVector(
                    rimePrior: basePrior,
                    exactPinyinPref: sig.exactPref,
                    regretPenalty: sig.regret,
                    contextBigram: sig.bigram,
                    appScenePref: sig.appPref,
                    docLexiconMatch: env.docLex,
                    docContinuation: env.docCont,
                    workingMemoryMatch: env.workLex,
                    workingMemoryContinuation: env.workCont,
                    domainSceneBoost: domainBoost
                )
                items.append(RankedCandidateItem(
                    candidate: PinyinCandidate(index: items.count, text: typo.text, comment: nil, source: .typoCorrected),
                    originalRimeIndex: nil,
                    globalRimeIndex: nil,
                    correctedPinyin: corrPin,
                    features: features,
                    score: weights.score(features)
                ))
                injectedTypoCount += 1
            } else if let existingIdx = items.firstIndex(where: { $0.candidate.text == typo.text }) {
                // 若该词已被 Rime 模糊音召回但沉在深层（如 shanhai -> 上海排在 #8），
                // 融合其正确拼音（shanghai）的个人记忆/语境分并按动态分档提升，同时保留原生 Rime 选词索引！
                let existing = items[existingIdx]
                let mergedFeatures = CandidateFeatureVector(
                    rimePrior: max(existing.features.rimePrior, basePrior),
                    exactPinyinPref: max(existing.features.exactPinyinPref, sig.exactPref),
                    regretPenalty: min(existing.features.regretPenalty, sig.regret),
                    contextBigram: max(existing.features.contextBigram, sig.bigram),
                    appScenePref: max(existing.features.appScenePref, sig.appPref),
                    docLexiconMatch: max(existing.features.docLexiconMatch, env.docLex),
                    docContinuation: max(existing.features.docContinuation, env.docCont),
                    workingMemoryMatch: max(existing.features.workingMemoryMatch, env.workLex),
                    workingMemoryContinuation: max(existing.features.workingMemoryContinuation, env.workCont),
                    neuralContextScore: existing.features.neuralContextScore,
                    domainSceneBoost: max(existing.features.domainSceneBoost, domainBoost)
                )
                let newScore = weights.score(mergedFeatures)
                if newScore > existing.score + 0.05 {
                    let upgradedSource: CandidateSource = (existing.candidate.source == .rime && existingIdx >= 2)
                        ? .typoCorrected
                        : existing.candidate.source
                    items[existingIdx] = RankedCandidateItem(
                        candidate: PinyinCandidate(
                            index: existing.candidate.index,
                            text: existing.candidate.text,
                            comment: existing.candidate.comment,
                            source: upgradedSource
                        ),
                        originalRimeIndex: existing.originalRimeIndex,
                        globalRimeIndex: existing.globalRimeIndex,
                        correctedPinyin: corrPin,
                        features: mergedFeatures,
                        score: newScore
                    )
                }
            }
        }

        // 1.85 融合中英文混输、离线英文词典补全与英文拼写纠错候选
        var injectedMixedCount = 0
        for mixed in mixedBilingualCandidates where injectedMixedCount < 3 {
            let sigKey = mixed.canonicalKey.isEmpty ? rawPinyin : mixed.canonicalKey
            let sig = lookupMemorySignals(
                memoryStore: useMemory ? memoryStore : nil,
                rawPinyin: sigKey,
                word: mixed.text,
                leftContext: leftContext,
                appBundleID: appBundleID
            )
            let rawSig = (sigKey != rawPinyin)
                ? lookupMemorySignals(
                    memoryStore: useMemory ? memoryStore : nil,
                    rawPinyin: rawPinyin,
                    word: mixed.text,
                    leftContext: leftContext,
                    appBundleID: appBundleID
                )
                : (exactPref: 0.0, regret: 0.0, bigram: 0.0, appPref: 0.0)
            let mergedExactPref = max(sig.exactPref, rawSig.exactPref)
            let mergedRegret = min(sig.regret, rawSig.regret)
            let mergedBigram = max(sig.bigram, rawSig.bigram)
            let mergedAppPref = max(sig.appPref, rawSig.appPref)

            let env = Self.contextEnvelope(
                docHit: docByText[mixed.text],
                workHit: workByText[mixed.text]
            )
            let sceneBoost: Double = (sceneState.primaryScene == .computerScience && preferences.enableSmartSceneAdaptation) ? 0.20 : 0.0
            let rimeTopIsPureASCII = rimeCandidates.first.map {
                !$0.text.isEmpty && $0.text.unicodeScalars.allSatisfy { $0.value < 128 }
            } ?? false
            let basePrior: Double
            if mixed.isFragmentedSource {
                if mixed.isSpellCorrected {
                    basePrior = max(1.50, 2.74 - 0.26 * Double(mixed.rank) - 0.16 * min(2.0, mixed.editCost))
                } else {
                    basePrior = max(1.55, 2.75 - 0.28 * Double(mixed.rank))
                }
            } else if rimeTopIsPureASCII {
                // Rime 首位已是纯英文（如 git / dock）：在保留首位的基础上把精选技术词（GitHub / Docker）提至前 2–3 位
                basePrior = max(1.40, 2.22 - 0.14 * Double(mixed.rank))
            } else {
                // 原输入本身是合法纯中文整串（如 api / ai / apiwendang）：克制次选，绝不抢占高频纯中文第 1 位
                basePrior = max(1.05, 1.88 - 0.30 * Double(mixed.rank))
            }

            let source: CandidateSource = mixed.isSpellCorrected ? .typoCorrected : .mixedBilingual
            if seen.insert(mixed.text).inserted {
                let features = CandidateFeatureVector(
                    rimePrior: basePrior,
                    exactPinyinPref: mergedExactPref,
                    regretPenalty: mergedRegret,
                    contextBigram: mergedBigram,
                    appScenePref: mergedAppPref,
                    docLexiconMatch: env.docLex,
                    docContinuation: env.docCont,
                    workingMemoryMatch: env.workLex,
                    workingMemoryContinuation: env.workCont,
                    domainSceneBoost: sceneBoost
                )
                items.append(RankedCandidateItem(
                    candidate: PinyinCandidate(index: items.count, text: mixed.text, comment: nil, source: source),
                    originalRimeIndex: nil,
                    globalRimeIndex: nil,
                    correctedPinyin: sigKey,
                    features: features,
                    score: weights.score(features)
                ))
                injectedMixedCount += 1
            } else if let existingIdx = items.firstIndex(where: { $0.candidate.text == mixed.text }) {
                let existing = items[existingIdx]
                let mergedFeatures = CandidateFeatureVector(
                    rimePrior: max(existing.features.rimePrior, basePrior),
                    exactPinyinPref: max(existing.features.exactPinyinPref, mergedExactPref),
                    regretPenalty: min(existing.features.regretPenalty, mergedRegret),
                    contextBigram: max(existing.features.contextBigram, mergedBigram),
                    appScenePref: max(existing.features.appScenePref, mergedAppPref),
                    docLexiconMatch: max(existing.features.docLexiconMatch, env.docLex),
                    docContinuation: max(existing.features.docContinuation, env.docCont),
                    workingMemoryMatch: max(existing.features.workingMemoryMatch, env.workLex),
                    workingMemoryContinuation: max(existing.features.workingMemoryContinuation, env.workCont),
                    neuralContextScore: existing.features.neuralContextScore,
                    domainSceneBoost: max(existing.features.domainSceneBoost, sceneBoost)
                )
                let newScore = weights.score(mergedFeatures)
                if newScore > existing.score + 0.05 {
                    items[existingIdx] = RankedCandidateItem(
                        candidate: PinyinCandidate(
                            index: existing.candidate.index,
                            text: existing.candidate.text,
                            comment: existing.candidate.comment,
                            source: existing.candidate.source
                        ),
                        originalRimeIndex: existing.originalRimeIndex,
                        globalRimeIndex: existing.globalRimeIndex,
                        correctedPinyin: existing.correctedPinyin ?? sigKey,
                        features: mergedFeatures,
                        score: newScore
                    )
                }
            }
        }

        // 2. 收集满足「整段覆盖守卫」的独立合成注入候选（文档 / 工作记忆 / 个人记忆）
        collectSyntheticInjections(
            docMatches: docMatches,
            workMatches: workMatches,
            workByText: workByText,
            rawPinyin: rawPinyin,
            leftContext: leftContext,
            appBundleID: appBundleID,
            memoryStore: useMemory ? memoryStore : nil,
            weights: weights,
            seen: &seen,
            into: &items
        )

        // 3. 排序并执行合成注入槽位预算（确保至少 >= 50% 槽位保留给 Rime 原生候选）
        return sortAndCapWithSlotBudget(items: items, pageLimit: effectiveLimit)
    }

    /// 合入 L2 异步神经重排顺序（兼容旧版纯列表接口）
    public func mergeNeuralOrder(
        base: [RankedCandidateItem],
        neuralOrderedTexts: [String]
    ) -> [RankedCandidateItem] {
        guard !base.isEmpty, !neuralOrderedTexts.isEmpty else { return base }

        if let first = base.first,
           (first.features.docContinuation >= 1.2
            || first.features.workingMemoryContinuation >= 1.3
            || first.features.exactPinyinPref >= 1.6) {
            return base
        }

        let byText = Dictionary(uniqueKeysWithValues: base.map { ($0.candidate.text, $0) })
        var rebuilt: [RankedCandidateItem] = []
        var used = Set<String>()

        for text in neuralOrderedTexts {
            if let existing = byText[text], used.insert(text).inserted {
                let newSource: CandidateSource = (rebuilt.isEmpty && existing.candidate.text != base.first?.candidate.text)
                    ? .neuralReranked
                    : existing.candidate.source
                rebuilt.append(RankedCandidateItem(
                    candidate: PinyinCandidate(
                        index: rebuilt.count,
                        text: existing.candidate.text,
                        comment: existing.candidate.comment,
                        source: newSource
                    ),
                    originalRimeIndex: existing.originalRimeIndex,
                    globalRimeIndex: existing.globalRimeIndex,
                    correctedPinyin: existing.correctedPinyin,
                    features: existing.features,
                    score: existing.score
                ))
            }
        }
        for item in base where used.insert(item.candidate.text).inserted {
            rebuilt.append(RankedCandidateItem(
                candidate: PinyinCandidate(
                    index: rebuilt.count,
                    text: item.candidate.text,
                    comment: item.candidate.comment,
                    source: item.candidate.source
                ),
                originalRimeIndex: item.originalRimeIndex,
                globalRimeIndex: item.globalRimeIndex,
                correctedPinyin: item.correctedPinyin,
                features: item.features,
                score: item.score
            ))
        }
        return rebuilt
    }

    /// 将 L2 神经语境连续得分通过带语义区分度门控的 z-score 融合进已有 L1 总分：
    /// - 未打分尾部锚定在 `min(0, minEffZ - 0.15)`，彻底消除超时截断导致的尾部倒挂
    /// - 语义区分度极低时自动衰减，避免噪声扰动
    /// - 首位换位执行防抖滞后阈值（普通首候选 >= 0.35，高置信记忆/锚点 >= 0.75）
    /// - 将 `effectiveZ` 写回 `features.neuralContextScore`，闭合 10 维 Pairwise 在线学习回路
    public func mergeNeuralScores(
        base: [RankedCandidateItem],
        scoredCandidates: [ScoredCandidate],
        neuralWeight: Double = 0.85
    ) -> [RankedCandidateItem] {
        guard !base.isEmpty, !scoredCandidates.isEmpty else { return base }

        let valid = scoredCandidates.filter { $0.score.isFinite && $0.score > -1e8 }
        guard valid.count >= 2 else { return base }

        let scores = valid.map(\.score)
        let mean = scores.reduce(0.0, +) / Double(scores.count)
        let variance = scores.reduce(0.0) { acc, s in
            let d = s - mean
            return acc + d * d
        } / Double(scores.count)
        let std = max(0.35, sqrt(variance))
        let spread = (scores.max() ?? mean) - (scores.min() ?? mean)
        let spreadConfidence = min(1.0, max(0.25, spread / 1.4))

        var zByText: [String: Double] = [:]
        zByText.reserveCapacity(valid.count)
        for item in valid {
            let clippedZ = max(-1.6, min(1.6, (item.score - mean) / std))
            zByText[item.text] = clippedZ * spreadConfidence
        }
        let minEffZ = zByText.values.min() ?? 0.0
        let unscoredFallbackZ = min(0.0, minEffZ - 0.15)

        let originalFirstText = base.first?.candidate.text
        let protectTopAnchor: Bool = {
            guard let first = base.first else { return false }
            return first.features.docContinuation >= 1.2
                || first.features.workingMemoryContinuation >= 1.3
                || first.features.exactPinyinPref >= 1.6
        }()
        let requiredTopSwapMargin = protectTopAnchor ? 0.75 : 0.35

        var fused: [(origIdx: Int, item: RankedCandidateItem, updatedFeatures: CandidateFeatureVector, finalScore: Double, neuralZ: Double)] =
            base.enumerated().map { idx, item in
                let effZ = zByText[item.candidate.text] ?? unscoredFallbackZ
                var updated = item.features
                let prevZ = updated.neuralContextScore
                updated.neuralContextScore = effZ
                let finalScore = item.score + neuralWeight * (effZ - prevZ)
                return (idx, item, updated, finalScore, effZ)
            }

        fused.sort { lhs, rhs in
            if abs(lhs.finalScore - rhs.finalScore) > 1e-6 {
                return lhs.finalScore > rhs.finalScore
            }
            return lhs.origIdx < rhs.origIdx
        }

        // 首位防抖滞后保护：新首位必须拉开足够净优势才允许替换原第 1 位
        if let newFirst = fused.first,
           newFirst.origIdx != 0,
           let origFirstPos = fused.firstIndex(where: { $0.origIdx == 0 }),
           (newFirst.finalScore - fused[origFirstPos].finalScore) < requiredTopSwapMargin {
            let orig = fused.remove(at: origFirstPos)
            fused.insert(orig, at: 0)
        }

        return fused.enumerated().map { displayIdx, entry in
            let liftedByNeural = (displayIdx == 0 && entry.item.candidate.text != originalFirstText && entry.neuralZ > 0.30)
            let strongNeuralTop = (displayIdx == 0 && entry.item.candidate.source == .rime && entry.neuralZ >= 0.75)
            let newSource: CandidateSource = (liftedByNeural || strongNeuralTop)
                ? .neuralReranked
                : entry.item.candidate.source
            return RankedCandidateItem(
                candidate: PinyinCandidate(
                    index: displayIdx,
                    text: entry.item.candidate.text,
                    comment: entry.item.candidate.comment,
                    source: newSource
                ),
                originalRimeIndex: entry.item.originalRimeIndex,
                globalRimeIndex: entry.item.globalRimeIndex,
                correctedPinyin: entry.item.correctedPinyin,
                features: entry.updatedFeatures,
                score: entry.finalScore
            )
        }
    }

    // MARK: - 内部阶段辅助方法

    private func rankSubsequentPage(
        rimeCandidates: [PinyinCandidate],
        pageNo: Int,
        pageLimit: Int,
        excludedFirstPageTexts: Set<String>,
        rawPinyin: String,
        leftContext: String,
        appBundleID: String,
        memoryStore: UserMemoryStore?,
        weights: RankerWeights
    ) -> [RankedCandidateItem] {
        var filtered: [(pageIdx: Int, cand: PinyinCandidate)] = []
        filtered.reserveCapacity(rimeCandidates.count)
        for (idx, cand) in rimeCandidates.enumerated() where !cand.text.isEmpty {
            if !excludedFirstPageTexts.contains(cand.text) {
                filtered.append((idx, cand))
            }
        }
        // 兜底：若整页恰好都被排除则回退保留原页候选
        if filtered.isEmpty {
            filtered = rimeCandidates.enumerated()
                .filter { !$0.element.text.isEmpty }
                .map { ($0.offset, $0.element) }
        }

        let pageBase = pageNo * pageLimit
        return filtered.prefix(pageLimit).enumerated().map { displayIdx, pair in
            let globalIdx = pageBase + pair.pageIdx
            let rimePrior = Self.rimePrior(forGlobalRank: globalIdx)
            let sig = lookupMemorySignals(
                memoryStore: memoryStore,
                rawPinyin: rawPinyin,
                word: pair.cand.text,
                leftContext: leftContext,
                appBundleID: appBundleID
            )
            let features = CandidateFeatureVector(
                rimePrior: rimePrior,
                exactPinyinPref: sig.exactPref,
                regretPenalty: sig.regret,
                contextBigram: sig.bigram,
                appScenePref: sig.appPref
            )
            return RankedCandidateItem(
                candidate: PinyinCandidate(
                    index: displayIdx,
                    text: pair.cand.text,
                    comment: pair.cand.comment,
                    source: pair.cand.source
                ),
                originalRimeIndex: pair.pageIdx,
                globalRimeIndex: globalIdx,
                features: features,
                score: weights.score(features)
            )
        }
    }

    private func scoreRimePool(
        rimeCandidates: [PinyinCandidate],
        extendedRimeCandidates: [PinyinCandidate],
        rawPinyin: String,
        leftContext: String,
        appBundleID: String,
        memoryStore: UserMemoryStore?,
        docByText: [String: DocumentCandidateMatch],
        workByText: [String: WorkingMemoryMatch],
        predByText: [String: PendingPredictionCandidate],
        sceneState: SceneContextState,
        tagStore: DomainAndLiteraryTagStore?,
        preferences: SmartPinyinPreferences,
        weights: RankerWeights,
        seen: inout Set<String>,
        into items: inout [RankedCandidateItem]
    ) {
        // 1A. 当前首页 Rime 候选
        for (idx, cand) in rimeCandidates.enumerated() {
            guard !cand.text.isEmpty, seen.insert(cand.text).inserted else { continue }
            let domainBoost = SceneContextDetector.domainBoost(
                forCandidateText: cand.text,
                sceneState: sceneState,
                preferences: preferences,
                tagStore: tagStore
            )
            let item = buildRimeItem(
                cand: cand,
                pageLocalIndex: idx,
                globalIndex: idx,
                rawPinyin: rawPinyin,
                leftContext: leftContext,
                appBundleID: appBundleID,
                memoryStore: memoryStore,
                docHit: docByText[cand.text],
                workHit: workByText[cand.text],
                predHit: predByText[cand.text],
                domainSceneBoost: domainBoost,
                weights: weights
            )
            items.append(item)
        }

        // 1B. Top-16 深层召回池（当存在个人记忆、上下文、预联想或高置信专业场景领域命中时无损捞上首页，无信号时不扰动万象首页，绝不提前污染 seen 集合）
        for cand in extendedRimeCandidates {
            guard !cand.text.isEmpty, cand.index < 16, !seen.contains(cand.text) else { continue }
            let docHit = docByText[cand.text]
            let workHit = workByText[cand.text]
            let predHit = predByText[cand.text]
            let domainBoost = SceneContextDetector.domainBoost(
                forCandidateText: cand.text,
                sceneState: sceneState,
                preferences: preferences,
                tagStore: tagStore
            )
            let sig = lookupMemorySignals(
                memoryStore: memoryStore,
                rawPinyin: rawPinyin,
                word: cand.text,
                leftContext: leftContext,
                appBundleID: appBundleID
            )
            let hasBoostSignal = sig.exactPref > 0.15
                || sig.bigram > 0.15
                || sig.appPref > 0.15
                || docHit != nil
                || workHit != nil
                || predHit != nil
                || domainBoost >= 0.25
            guard hasBoostSignal else { continue }
            seen.insert(cand.text)

            let env = Self.contextEnvelope(docHit: docHit, workHit: workHit)
            let predCont = predHit.map { max(1.65, 2.25 - 0.18 * Double($0.rankIndex)) } ?? 0
            let features = CandidateFeatureVector(
                rimePrior: Self.rimePrior(forGlobalRank: cand.index),
                exactPinyinPref: sig.exactPref,
                regretPenalty: sig.regret,
                contextBigram: sig.bigram,
                appScenePref: sig.appPref,
                docLexiconMatch: env.docLex,
                docContinuation: env.docCont,
                workingMemoryMatch: env.workLex,
                workingMemoryContinuation: max(env.workCont, predCont),
                domainSceneBoost: domainBoost
            )
            let source = predHit != nil
                ? .neuralPrediction
                : Self.resolveSource(
                    baseSource: cand.source,
                    docHit: docHit,
                    workHit: workHit,
                    sig: sig
                )
            items.append(RankedCandidateItem(
                candidate: PinyinCandidate(
                    index: items.count,
                    text: cand.text,
                    comment: cand.comment,
                    source: source,
                    category: cand.category
                ),
                originalRimeIndex: nil,
                globalRimeIndex: cand.index,
                features: features,
                score: weights.score(features)
            ))
        }
    }

    private func buildRimeItem(
        cand: PinyinCandidate,
        pageLocalIndex: Int,
        globalIndex: Int,
        rawPinyin: String,
        leftContext: String,
        appBundleID: String,
        memoryStore: UserMemoryStore?,
        docHit: DocumentCandidateMatch?,
        workHit: WorkingMemoryMatch?,
        predHit: PendingPredictionCandidate?,
        domainSceneBoost: Double,
        weights: RankerWeights
    ) -> RankedCandidateItem {
        let sig = lookupMemorySignals(
            memoryStore: memoryStore,
            rawPinyin: rawPinyin,
            word: cand.text,
            leftContext: leftContext,
            appBundleID: appBundleID
        )
        let env = Self.contextEnvelope(docHit: docHit, workHit: workHit)
        let predCont = predHit.map { max(1.65, 2.25 - 0.18 * Double($0.rankIndex)) } ?? 0
        let features = CandidateFeatureVector(
            rimePrior: Self.rimePrior(forGlobalRank: globalIndex),
            exactPinyinPref: sig.exactPref,
            regretPenalty: sig.regret,
            contextBigram: sig.bigram,
            appScenePref: sig.appPref,
            docLexiconMatch: env.docLex,
            docContinuation: env.docCont,
            workingMemoryMatch: env.workLex,
            workingMemoryContinuation: max(env.workCont, predCont),
            domainSceneBoost: domainSceneBoost
        )
        let source = predHit != nil
            ? .neuralPrediction
            : Self.resolveSource(
                baseSource: cand.source,
                docHit: docHit,
                workHit: workHit,
                sig: sig
            )
        return RankedCandidateItem(
            candidate: PinyinCandidate(index: pageLocalIndex, text: cand.text, comment: cand.comment, source: source),
            originalRimeIndex: pageLocalIndex,
            globalRimeIndex: globalIndex,
            features: features,
            score: weights.score(features)
        )
    }

    private func collectSyntheticInjections(
        docMatches: [DocumentCandidateMatch],
        workMatches: [WorkingMemoryMatch],
        workByText: [String: WorkingMemoryMatch],
        rawPinyin: String,
        leftContext: String,
        appBundleID: String,
        memoryStore: UserMemoryStore?,
        weights: RankerWeights,
        seen: inout Set<String>,
        into items: inout [RankedCandidateItem]
    ) {
        // A. 当前文本框术语/代码词（必须通过 coversFullQuery 覆盖守卫，防止选中后 clearComposition 误吞长句尾段）
        for hit in docMatches where hit.coversFullQuery && seen.insert(hit.text).inserted {
            let sig = lookupMemorySignals(
                memoryStore: memoryStore,
                rawPinyin: rawPinyin,
                word: hit.text,
                leftContext: leftContext,
                appBundleID: appBundleID
            )
            let env = Self.contextEnvelope(docHit: hit, workHit: workByText[hit.text])
            let basePrior = hit.isEnglishToken ? 0.35 : 0.75
            let features = CandidateFeatureVector(
                rimePrior: basePrior,
                exactPinyinPref: sig.exactPref,
                regretPenalty: sig.regret,
                contextBigram: sig.bigram,
                appScenePref: sig.appPref,
                docLexiconMatch: env.docLex,
                docContinuation: env.docCont,
                workingMemoryMatch: env.workLex,
                workingMemoryContinuation: env.workCont
            )
            items.append(RankedCandidateItem(
                candidate: PinyinCandidate(index: items.count, text: hit.text, comment: nil, source: .documentContext),
                originalRimeIndex: nil,
                globalRimeIndex: nil,
                features: features,
                score: weights.score(features)
            ))
        }

        // B. 短期工作记忆主题词/短语（跨换行与跨应用生效，上限 3 条，同样受 coversFullQuery 保护）
        var injectedWorkCount = 0
        for hit in workMatches where injectedWorkCount < 3 && hit.coversFullQuery && seen.insert(hit.text).inserted {
            let sig = lookupMemorySignals(
                memoryStore: memoryStore,
                rawPinyin: rawPinyin,
                word: hit.text,
                leftContext: leftContext,
                appBundleID: appBundleID
            )
            let basePrior = hit.isEnglishToken ? 0.30 : 0.72
            let features = CandidateFeatureVector(
                rimePrior: basePrior,
                exactPinyinPref: sig.exactPref,
                regretPenalty: sig.regret,
                contextBigram: sig.bigram,
                appScenePref: sig.appPref,
                workingMemoryMatch: hit.topicMatchScore,
                workingMemoryContinuation: hit.continuationScore
            )
            items.append(RankedCandidateItem(
                candidate: PinyinCandidate(index: items.count, text: hit.text, comment: nil, source: .workingMemory),
                originalRimeIndex: nil,
                globalRimeIndex: nil,
                features: features,
                score: weights.score(features)
            ))
            injectedWorkCount += 1
        }

        // C. 个人长期高频词与自动成词短语（上限 3 条）
        if let mem = memoryStore {
            for prefWord in mem.topPreferredWords(forPinyin: rawPinyin, limit: 3) where seen.insert(prefWord).inserted {
                let sig = lookupMemorySignals(
                    memoryStore: mem,
                    rawPinyin: rawPinyin,
                    word: prefWord,
                    leftContext: leftContext,
                    appBundleID: appBundleID
                )
                let workHit = workByText[prefWord]
                let features = CandidateFeatureVector(
                    rimePrior: 0.70,
                    exactPinyinPref: sig.exactPref,
                    regretPenalty: sig.regret,
                    contextBigram: sig.bigram,
                    appScenePref: sig.appPref,
                    workingMemoryMatch: workHit?.topicMatchScore ?? 0,
                    workingMemoryContinuation: workHit?.continuationScore ?? 0
                )
                items.append(RankedCandidateItem(
                    candidate: PinyinCandidate(index: items.count, text: prefWord, comment: nil, source: .userMemory),
                    originalRimeIndex: nil,
                    globalRimeIndex: nil,
                    features: features,
                    score: weights.score(features)
                ))
            }
        }
    }

    private func sortAndCapWithSlotBudget(
        items: [RankedCandidateItem],
        pageLimit: Int
    ) -> [RankedCandidateItem] {
        let sorted = items.sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 1e-6 {
                return lhs.score > rhs.score
            }
            return (lhs.globalRimeIndex ?? Int.max) < (rhs.globalRimeIndex ?? Int.max)
        }

        let maxSyntheticSlots = min(3, max(1, pageLimit / 2))
        let totalRimeBacked = sorted.filter(\.isRimeBacked).count
        let reservedRimeSlots = min(totalRimeBacked, max(0, pageLimit - maxSyntheticSlots))

        var chosen: [RankedCandidateItem] = []
        chosen.reserveCapacity(pageLimit)
        var syntheticUsed = 0
        var rimeUsed = 0
        var deferredSynthetic: [RankedCandidateItem] = []

        for item in sorted {
            if chosen.count >= pageLimit { break }
            if item.isRimeBacked {
                chosen.append(item)
                rimeUsed += 1
            } else {
                let remainingSlotsAfterThis = pageLimit - chosen.count - 1
                let remainingRimeNeeded = max(0, reservedRimeSlots - rimeUsed)
                if syntheticUsed < maxSyntheticSlots && remainingSlotsAfterThis >= remainingRimeNeeded {
                    chosen.append(item)
                    syntheticUsed += 1
                } else {
                    deferredSynthetic.append(item)
                }
            }
        }

        // 若 Rime 候选本身不足以填满页面，用被延后的合成候选补齐空槽位
        for extra in deferredSynthetic where chosen.count < pageLimit {
            chosen.append(extra)
        }

        return chosen.enumerated().map { displayIdx, item in
            RankedCandidateItem(
                candidate: PinyinCandidate(
                    index: displayIdx,
                    text: item.candidate.text,
                    comment: item.candidate.comment,
                    source: item.candidate.source
                ),
                originalRimeIndex: item.originalRimeIndex,
                globalRimeIndex: item.globalRimeIndex,
                correctedPinyin: item.correctedPinyin,
                features: item.features,
                score: item.score
            )
        }
    }

    /// 同源上下文去重包络：当同一词同时命中当前文本框与短期工作记忆时，保留较强信号并将较弱重复信号衰减至 0.20×，
    /// 彻底杜绝双倍计分（14+ 分）淹没 Rime 先验与 Qwen3 语义。
    private static func contextEnvelope(
        docHit: DocumentCandidateMatch?,
        workHit: WorkingMemoryMatch?
    ) -> (docLex: Double, docCont: Double, workLex: Double, workCont: Double) {
        let rawDocLex = docHit?.lexiconMatchScore ?? 0
        let rawWorkLex = workHit?.topicMatchScore ?? 0
        let docLex: Double
        let workLex: Double
        if rawDocLex > 0 && rawWorkLex > 0 {
            if rawDocLex >= rawWorkLex {
                docLex = rawDocLex
                workLex = rawWorkLex * 0.20
            } else {
                docLex = rawDocLex * 0.20
                workLex = rawWorkLex
            }
        } else {
            docLex = rawDocLex
            workLex = rawWorkLex
        }

        let rawDocCont = docHit?.continuationScore ?? 0
        let rawWorkCont = workHit?.continuationScore ?? 0
        let docCont: Double
        let workCont: Double
        if rawDocCont > 0 && rawWorkCont > 0 {
            if rawDocCont >= rawWorkCont {
                docCont = rawDocCont
                workCont = rawWorkCont * 0.20
            } else {
                docCont = rawDocCont * 0.20
                workCont = rawWorkCont
            }
        } else {
            docCont = rawDocCont
            workCont = rawWorkCont
        }

        return (docLex, docCont, workLex, workCont)
    }

    private func lookupMemorySignals(
        memoryStore: UserMemoryStore?,
        rawPinyin: String,
        word: String,
        leftContext: String,
        appBundleID: String
    ) -> (exactPref: Double, regret: Double, bigram: Double, appPref: Double) {
        guard let mem = memoryStore else { return (0, 0, 0, 0) }
        let sig = mem.lookupSignals(
            pinyin: rawPinyin,
            word: word,
            leftContext: leftContext,
            appBundleID: appBundleID
        )
        return (sig.exactPref, sig.regretPenalty, sig.contextBigram, sig.appPref)
    }

    private static func resolveSource(
        baseSource: CandidateSource,
        docHit: DocumentCandidateMatch?,
        workHit: WorkingMemoryMatch?,
        sig: (exactPref: Double, regret: Double, bigram: Double, appPref: Double)
    ) -> CandidateSource {
        if let docHit, (docHit.continuationScore > 0 || docHit.lexiconMatchScore >= 1.4) {
            return .documentContext
        }
        if let workHit, (workHit.continuationScore > 0 || workHit.topicMatchScore >= 1.25) {
            return .workingMemory
        }
        if sig.exactPref >= 0.9 || sig.bigram >= 0.8 || sig.appPref >= 0.7 {
            return .userMemory
        }
        return baseSource
    }

    private static func rimePrior(forGlobalRank rank: Int) -> Double {
        max(0.15, 2.40 - 0.55 * log2(Double(max(0, rank)) + 1.0))
    }
}
