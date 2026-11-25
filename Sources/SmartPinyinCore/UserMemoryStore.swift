import Foundation
import SharedIPC
import SQLite3

/// 候选排序特征向量（11 维：覆盖 L1 多信号融合、L2 神经语境与智能领域场景提权，支持闭环在线 Pairwise 权重自校准）
public struct CandidateFeatureVector: Equatable, Sendable {
    public var rimePrior: Double
    public var exactPinyinPref: Double
    public var regretPenalty: Double
    public var contextBigram: Double
    public var appScenePref: Double
    public var docLexiconMatch: Double
    public var docContinuation: Double
    public var workingMemoryMatch: Double
    public var workingMemoryContinuation: Double
    /// L2 Qwen3 标准化语境得分（带语义区分度门控），使 Pairwise 更新可联合校准 L2 权重
    public var neuralContextScore: Double
    /// 第 11 维：当前活跃专业场景（游戏/数学/计算机/美术/科学/医学/财经/文学）命中的领域知识库提权分
    public var domainSceneBoost: Double

    public init(
        rimePrior: Double = 0,
        exactPinyinPref: Double = 0,
        regretPenalty: Double = 0,
        contextBigram: Double = 0,
        appScenePref: Double = 0,
        docLexiconMatch: Double = 0,
        docContinuation: Double = 0,
        workingMemoryMatch: Double = 0,
        workingMemoryContinuation: Double = 0,
        neuralContextScore: Double = 0,
        domainSceneBoost: Double = 0
    ) {
        self.rimePrior = rimePrior
        self.exactPinyinPref = exactPinyinPref
        self.regretPenalty = regretPenalty
        self.contextBigram = contextBigram
        self.appScenePref = appScenePref
        self.docLexiconMatch = docLexiconMatch
        self.docContinuation = docContinuation
        self.workingMemoryMatch = workingMemoryMatch
        self.workingMemoryContinuation = workingMemoryContinuation
        self.neuralContextScore = neuralContextScore
        self.domainSceneBoost = domainSceneBoost
    }
}

/// 在线自校准的融合权重向量（有界裁剪，防止极端样本漂移）
public struct RankerWeights: Equatable, Sendable {
    public var rimePrior: Double = 1.00
    public var exactPinyinPref: Double = 1.35
    public var regretPenalty: Double = 1.40
    public var contextBigram: Double = 0.95
    public var appScenePref: Double = 0.75
    public var docLexiconMatch: Double = 1.15
    public var docContinuation: Double = 1.85
    public var workingMemoryMatch: Double = 1.20
    public var workingMemoryContinuation: Double = 1.75
    public var neuralContext: Double = 0.85
    public var domainScene: Double = 1.15
    public var updateCount: Int = 0

    public init() {}

    public func score(_ f: CandidateFeatureVector) -> Double {
        rimePrior * f.rimePrior
            + exactPinyinPref * f.exactPinyinPref
            - regretPenalty * f.regretPenalty
            + contextBigram * f.contextBigram
            + appScenePref * f.appScenePref
            + docLexiconMatch * f.docLexiconMatch
            + docContinuation * f.docContinuation
            + workingMemoryMatch * f.workingMemoryMatch
            + workingMemoryContinuation * f.workingMemoryContinuation
            + neuralContext * f.neuralContextScore
            + domainScene * f.domainSceneBoost
    }

    public mutating func applyPairwiseUpdate(
        chosen: CandidateFeatureVector,
        skippedTop: CandidateFeatureVector,
        learningRate: Double = 0.035
    ) {
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
            min(hi, max(lo, v))
        }
        rimePrior = clamp(rimePrior + learningRate * (chosen.rimePrior - skippedTop.rimePrior), 0.45, 1.80)
        exactPinyinPref = clamp(exactPinyinPref + learningRate * (chosen.exactPinyinPref - skippedTop.exactPinyinPref), 0.60, 2.80)
        regretPenalty = clamp(regretPenalty + learningRate * (skippedTop.regretPenalty - chosen.regretPenalty), 0.70, 2.80)
        contextBigram = clamp(contextBigram + learningRate * (chosen.contextBigram - skippedTop.contextBigram), 0.30, 2.20)
        appScenePref = clamp(appScenePref + learningRate * (chosen.appScenePref - skippedTop.appScenePref), 0.25, 1.80)
        docLexiconMatch = clamp(docLexiconMatch + learningRate * (chosen.docLexiconMatch - skippedTop.docLexiconMatch), 0.40, 2.40)
        docContinuation = clamp(docContinuation + learningRate * (chosen.docContinuation - skippedTop.docContinuation), 0.80, 3.20)
        workingMemoryMatch = clamp(workingMemoryMatch + learningRate * (chosen.workingMemoryMatch - skippedTop.workingMemoryMatch), 0.45, 2.40)
        workingMemoryContinuation = clamp(workingMemoryContinuation + learningRate * (chosen.workingMemoryContinuation - skippedTop.workingMemoryContinuation), 0.80, 3.10)
        neuralContext = clamp(neuralContext + learningRate * (chosen.neuralContextScore - skippedTop.neuralContextScore), 0.35, 1.60)
        domainScene = clamp(domainScene + learningRate * (chosen.domainSceneBoost - skippedTop.domainSceneBoost), 0.45, 2.20)
        updateCount += 1
    }
}

/// 个人本地记忆统计概览
public struct UserMemoryStats: Equatable, Sendable {
    public let pinyinEntries: Int
    public let contextBigrams: Int
    public let appEntries: Int
    public let learnedPhrases: Int
    public let weightUpdates: Int

    public init(
        pinyinEntries: Int,
        contextBigrams: Int,
        appEntries: Int,
        learnedPhrases: Int = 0,
        weightUpdates: Int
    ) {
        self.pinyinEntries = pinyinEntries
        self.contextBigrams = contextBigrams
        self.appEntries = appEntries
        self.learnedPhrases = learnedPhrases
        self.weightUpdates = weightUpdates
    }
}

/// 100% 本地自进化偏好记忆库（SQLite WAL + 内存热缓存）：
/// - 主线程查询全走内存 O(1)（< 0.1ms），写入走低优先级串行队列异步落盘
/// - 记录精确拼音/简拼偏好、跳选/退格撤销负反馈、上下文二元搭配、分应用场景偏好与在线自适应权重
/// - 密码框（isSecureInput = true）硬阻断零读写
public final class UserMemoryStore: @unchecked Sendable {
    public static let didResetNotification = Notification.Name(
        "\(SmartPinyinIdentifiers.appBundleID).memoryDidReset"
    )

    public struct PinyinWordRecord: Sendable {
        public var acceptCount: Int
        public var skipCount: Int
        public var undoCount: Int
        public var recencyEMA: Double
        public var lastUsedTS: TimeInterval
    }

    public struct CountRecord: Sendable {
        public var count: Int
        public var recencyEMA: Double
        public var lastUsedTS: TimeInterval
    }

    private struct PinyinWordKey: Hashable {
        let pinyin: String
        let word: String
    }

    private struct BigramKey: Hashable {
        let prevTail: String
        let word: String
    }

    private struct AppWordKey: Hashable {
        let appID: String
        let pinyin: String
        let word: String
    }

    private let dbURL: URL
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.smartpinyin.memory.sqlite", qos: .utility)
    private var db: OpaquePointer?

    public struct LearnedPhraseRecord: Sendable {
        public let phrase: String
        public let fullPinyin: String
        public let initials: String
        public var count: Int
        public var recencyEMA: Double
        public var lastUsedTS: TimeInterval
    }

    private var pinyinCache: [PinyinWordKey: PinyinWordRecord] = [:]
    private var pinyinToWords: [String: Set<String>] = [:]
    /// 首字母分桶拼音索引：支持不完整拼音前缀查表（如 shenm 命中 shenme -> 什么）
    private var firstCharPinyinKeys: [Character: Set<String>] = [:]
    private var wordToPinyins: [String: Set<String>] = [:]
    private var bigramCache: [BigramKey: CountRecord] = [:]
    /// 前文锚点反向索引：支持 0ms 个人高频后续词推荐
    private var bigramByTail: [String: Set<String>] = [:]
    private var appCache: [AppWordKey: CountRecord] = [:]
    /// 自动连词造词沉淀表（2~6 字个人高频短语）
    private var learnedPhrases: [String: LearnedPhraseRecord] = [:]
    private var weights = RankerWeights()

    private static let halfLifeSeconds: TimeInterval = 14 * 24 * 3600 // 14 天时间衰减半衰期
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(SmartPinyinIdentifiers.appSupportFolderName, isDirectory: true)
        return base.appendingPathComponent("user_memory.sqlite3")
    }

    public init(databaseURL: URL = UserMemoryStore.defaultDatabaseURL()) {
        self.dbURL = databaseURL
        openAndHydrate()
    }

    private struct SendableSQLiteHandle: @unchecked Sendable {
        let ptr: OpaquePointer
    }

    deinit {
        if let handle = db {
            db = nil
            let boxed = SendableSQLiteHandle(ptr: handle)
            writeQueue.async {
                sqlite3_close_v2(boxed.ptr)
            }
        }
    }

    // MARK: - 快速只读查询（< 0.1ms，纯内存热缓存）

    public func currentWeights() -> RankerWeights {
        lock.lock()
        defer { lock.unlock() }
        return weights
    }

    /// 计算单个候选在当前拼音、前文与宿主 App 下的偏好信号（全部归一化到友好数值区间）
    public func lookupSignals(
        pinyin: String,
        word: String,
        leftContext: String,
        appBundleID: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> (exactPref: Double, regretPenalty: Double, contextBigram: Double, appPref: Double) {
        let normPinyin = Self.normalizePinyinKey(pinyin)
        guard !normPinyin.isEmpty, !word.isEmpty else { return (0, 0, 0, 0) }
        let tail3 = Self.contextTail(leftContext, maxChars: 3)
        let tail2 = Self.contextTail(leftContext, maxChars: 2)
        let tail1 = Self.contextTail(leftContext, maxChars: 1)

        lock.lock()
        let exactRec = pinyinCache[PinyinWordKey(pinyin: normPinyin, word: word)]
        // 若精确拼音未命中（如用户输入不完整拼音 shenm，而记忆库记住的是 shenme -> 什么），自动回退前缀/简拼匹配！
        var prefixRec: (rec: PinyinWordRecord, coverage: Double)?
        if exactRec == nil, normPinyin.count >= 2, let knownPinyins = wordToPinyins[word] {
            var bestScore = -1.0
            for full in knownPinyins where full.hasPrefix(normPinyin) && full.count > normPinyin.count {
                if let r = pinyinCache[PinyinWordKey(pinyin: full, word: word)] {
                    let cov = Double(normPinyin.count) / Double(full.count)
                    let strength = Double(r.acceptCount) * cov
                    if strength > bestScore {
                        bestScore = strength
                        prefixRec = (r, cov)
                    }
                }
            }
        }
        let phraseRec = learnedPhrases[word]
        let b3 = tail3.count == 3 ? bigramCache[BigramKey(prevTail: tail3, word: word)] : nil
        let b2 = tail2.count == 2 ? bigramCache[BigramKey(prevTail: tail2, word: word)] : nil
        let b1 = !tail1.isEmpty ? bigramCache[BigramKey(prevTail: tail1, word: word)] : nil
        let aRec = !appBundleID.isEmpty
            ? appCache[AppWordKey(appID: appBundleID, pinyin: normPinyin, word: word)]
            : nil
        lock.unlock()

        var exactPref = 0.0
        var regret = 0.0
        if let pRec = exactRec {
            let decayedEMA = Self.decayed(pRec.recencyEMA, lastTS: pRec.lastUsedTS, now: now)
            let acceptBoost = log1p(Double(pRec.acceptCount)) * 0.85 + min(2.2, decayedEMA * 0.55)
            // 结合个人采纳率（accept / (accept + skip + 2)），避免历史高次但近期反复被跳过的旧词僵死首位
            let denom = Double(pRec.acceptCount + pRec.skipCount + 2)
            let acceptRatio = Double(pRec.acceptCount + 1) / denom
            exactPref = acceptBoost * (0.45 + 0.55 * acceptRatio)

            let skipPen = log1p(Double(pRec.skipCount)) * 0.42
            let undoPen = log1p(Double(pRec.undoCount)) * 1.15
            regret = min(3.2, skipPen + undoPen)
        } else if let (pRec, coverage) = prefixRec {
            let decayedEMA = Self.decayed(pRec.recencyEMA, lastTS: pRec.lastUsedTS, now: now)
            let acceptBoost = log1p(Double(pRec.acceptCount)) * 0.80 + min(1.8, decayedEMA * 0.48)
            let denom = Double(pRec.acceptCount + pRec.skipCount + 2)
            let acceptRatio = Double(pRec.acceptCount + 1) / denom
            let prefixFactor = 0.52 + 0.45 * coverage
            exactPref = acceptBoost * (0.45 + 0.55 * acceptRatio) * prefixFactor

            let undoPen = log1p(Double(pRec.undoCount)) * 0.85
            regret = min(2.4, undoPen)
        }

        if let phraseRec,
           (phraseRec.fullPinyin.hasPrefix(normPinyin) || phraseRec.initials == normPinyin || phraseRec.initials.hasPrefix(normPinyin)) {
            let d = Self.decayed(phraseRec.recencyEMA, lastTS: phraseRec.lastUsedTS, now: now)
            let bonus = (log1p(Double(phraseRec.count)) * 0.55 + min(1.2, d * 0.35))
            exactPref = max(exactPref, bonus)
        }

        var bigramScore = 0.0
        if let b3 {
            let d3 = Self.decayed(b3.recencyEMA, lastTS: b3.lastUsedTS, now: now)
            bigramScore += log1p(Double(b3.count)) * 0.90 + min(1.8, d3 * 0.55)
        }
        if let b2 {
            let d2 = Self.decayed(b2.recencyEMA, lastTS: b2.lastUsedTS, now: now)
            bigramScore += log1p(Double(b2.count)) * 0.72 + min(1.5, d2 * 0.45)
        }
        if let b1 {
            let d1 = Self.decayed(b1.recencyEMA, lastTS: b1.lastUsedTS, now: now)
            bigramScore += log1p(Double(b1.count)) * 0.35 + min(0.8, d1 * 0.25)
        }

        var appScore = 0.0
        if let aRec {
            let da = Self.decayed(aRec.recencyEMA, lastTS: aRec.lastUsedTS, now: now)
            appScore = log1p(Double(aRec.count)) * 0.65 + min(1.4, da * 0.40)
        }

        return (exactPref, regret, bigramScore, appScore)
    }

    /// 召回用户在当前拼音/前缀/简拼下高频偏好与自动成词的个人记忆词（最多 limit 个）
    public func topPreferredWords(
        forPinyin pinyin: String,
        limit: Int = 3,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [String] {
        let normPinyin = Self.normalizePinyinKey(pinyin)
        guard normPinyin.count >= 2, let firstCh = normPinyin.first else { return [] }

        lock.lock()
        var bestByWord: [String: Double] = [:]

        // 1. 精确拼音命中
        if let words = pinyinToWords[normPinyin] {
            for w in words {
                if let rec = pinyinCache[PinyinWordKey(pinyin: normPinyin, word: w)],
                   rec.acceptCount >= 2,
                   rec.undoCount < rec.acceptCount {
                    let score = log1p(Double(rec.acceptCount)) + Self.decayed(rec.recencyEMA, lastTS: rec.lastUsedTS, now: now)
                        - Double(rec.undoCount) * 0.9 - Double(rec.skipCount) * 0.25
                    if score > 0.8 {
                        bestByWord[w] = max(bestByWord[w] ?? 0, score)
                    }
                }
            }
        }

        // 2. 前缀拼音命中（如 shenm -> shenme 下的「什么」），利用首字母分桶控制 < 0.15ms，且要求 >= 55% 覆盖防长短失配
        if normPinyin.count >= 3, let bucket = firstCharPinyinKeys[firstCh] {
            for candidateKey in bucket where candidateKey.hasPrefix(normPinyin) && candidateKey.count > normPinyin.count {
                let coverage = Double(normPinyin.count) / Double(candidateKey.count)
                guard coverage >= 0.55, let words = pinyinToWords[candidateKey] else { continue }
                for w in words {
                    if let rec = pinyinCache[PinyinWordKey(pinyin: candidateKey, word: w)],
                       rec.acceptCount >= 2,
                       rec.undoCount < rec.acceptCount {
                        let raw = log1p(Double(rec.acceptCount)) + Self.decayed(rec.recencyEMA, lastTS: rec.lastUsedTS, now: now)
                            - Double(rec.undoCount) * 0.9 - Double(rec.skipCount) * 0.25
                        let score = raw * (0.55 + 0.45 * coverage)
                        if score > 0.85 {
                            bestByWord[w] = max(bestByWord[w] ?? 0, score)
                        }
                    }
                }
            }
        }

        // 3. 长期自动沉淀短语命中（全拼 / 精确简拼 / 高覆盖全拼前缀，过滤已被频繁撤销的短语）
        for rec in learnedPhrases.values where rec.count >= 1 {
            if let undoRec = pinyinCache[PinyinWordKey(pinyin: normPinyin, word: rec.phrase)]
                ?? pinyinCache[PinyinWordKey(pinyin: rec.fullPinyin, word: rec.phrase)],
               undoRec.undoCount > rec.count {
                continue
            }
            let matchFactor: Double
            if rec.fullPinyin == normPinyin {
                matchFactor = 1.15
            } else if rec.initials == normPinyin {
                matchFactor = 1.05
            } else if normPinyin.count >= 3 && rec.fullPinyin.hasPrefix(normPinyin) {
                let coverage = Double(normPinyin.count) / Double(max(normPinyin.count, rec.fullPinyin.count))
                guard coverage >= 0.55 else { continue }
                matchFactor = 0.70 + 0.35 * coverage
            } else {
                continue
            }
            let d = Self.decayed(rec.recencyEMA, lastTS: rec.lastUsedTS, now: now)
            let score = (log1p(Double(rec.count)) + d * 0.65) * matchFactor
            if score > 0.85 {
                bestByWord[rec.phrase] = max(bestByWord[rec.phrase] ?? 0, score)
            }
        }
        lock.unlock()

        return bestByWord.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    /// 0ms 个人长期高频后续词推荐（用于句末联想即时展示，无需等待大模型）
    public func topContinuations(
        forLeftContext leftContext: String,
        limit: Int = 2,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [String] {
        let tail3 = Self.contextTail(leftContext, maxChars: 3)
        let tail2 = Self.contextTail(leftContext, maxChars: 2)
        guard tail2.count >= 2 else { return [] }

        lock.lock()
        var scored: [String: Double] = [:]
        for (tail, weight) in [(tail3, 1.45), (tail2, 1.0)] where tail.count >= 2 {
            guard let nextWords = bigramByTail[tail] else { continue }
            for w in nextWords where w.count >= 2 {
                guard let rec = bigramCache[BigramKey(prevTail: tail, word: w)], rec.count >= 2 else { continue }
                let d = Self.decayed(rec.recencyEMA, lastTS: rec.lastUsedTS, now: now)
                guard d >= 0.20 else { continue }
                let score = (log1p(Double(rec.count)) * 0.8 + d * 0.5) * weight
                scored[w] = max(scored[w] ?? 0, score)
            }
        }
        lock.unlock()

        return scored.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    /// 记录经短期工作记忆验证的高频连词短语（累计 >= 2 次自动沉淀进长期 SQLite）
    public func recordLearnedPhrase(
        phrase: String,
        fullPinyin: String,
        initials: String,
        isSecureInput: Bool,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        guard !isSecureInput else { return }
        let clean = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let normFull = Self.normalizePinyinKey(fullPinyin)
        let normInit = Self.normalizePinyinKey(initials)
        guard clean.count >= 2 && clean.count <= 6,
              !normFull.isEmpty,
              SensitiveTextFilter.isSafeMemoryToken(clean)
        else { return }

        lock.lock()
        var rec = learnedPhrases[clean] ?? LearnedPhraseRecord(
            phrase: clean,
            fullPinyin: normFull,
            initials: normInit,
            count: 0,
            recencyEMA: 0,
            lastUsedTS: now
        )
        rec.recencyEMA = Self.decayed(rec.recencyEMA, lastTS: rec.lastUsedTS, now: now) + 1.0
        rec.count += 1
        rec.lastUsedTS = now
        learnedPhrases[clean] = rec
        let snapshot = rec
        lock.unlock()

        writeQueue.async { [weak self] in
            self?.upsertLearnedPhraseLocked(snapshot)
        }
    }

    // MARK: - 在线反馈与自迭代学习

    /// 记录用户的一次选词结果：
    /// - 正向强化所选词的拼音偏好、上下文搭配与 App 场景偏好
    /// - 若用户跳过了原本排在第 1 位的词（selectedRank > 0），对首位记录温和跳选惩罚并执行一次 Pairwise 权重自校准
    public func recordSelection(
        pinyin: String,
        chosenWord: String,
        selectedRank: Int,
        skippedTopWord: String?,
        chosenFeatures: CandidateFeatureVector?,
        skippedTopFeatures: CandidateFeatureVector?,
        leftContext: String,
        appBundleID: String,
        isSecureInput: Bool,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        guard !isSecureInput else { return }
        let normPinyin = Self.normalizePinyinKey(pinyin)
        let cleanWord = chosenWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanWord.isEmpty, SensitiveTextFilter.isSafeMemoryToken(cleanWord) else { return }

        var updatedPinyinRec: PinyinWordRecord?
        var updatedSkippedRec: (String, PinyinWordRecord)?
        var updatedBigrams: [(String, CountRecord)] = []
        var updatedAppRec: CountRecord?
        var updatedWeights: RankerWeights?

        lock.lock()

        if !normPinyin.isEmpty {
            let key = PinyinWordKey(pinyin: normPinyin, word: cleanWord)
            var rec = pinyinCache[key] ?? PinyinWordRecord(
                acceptCount: 0, skipCount: 0, undoCount: 0, recencyEMA: 0, lastUsedTS: now
            )
            rec.recencyEMA = Self.decayed(rec.recencyEMA, lastTS: rec.lastUsedTS, now: now) + 1.0
            rec.acceptCount += 1
            rec.lastUsedTS = now
            pinyinCache[key] = rec
            pinyinToWords[normPinyin, default: []].insert(cleanWord)
            if let first = normPinyin.first {
                firstCharPinyinKeys[first, default: []].insert(normPinyin)
            }
            wordToPinyins[cleanWord, default: []].insert(normPinyin)
            updatedPinyinRec = rec

            if selectedRank > 0, let skipped = skippedTopWord, !skipped.isEmpty, skipped != cleanWord {
                let sKey = PinyinWordKey(pinyin: normPinyin, word: skipped)
                var sRec = pinyinCache[sKey] ?? PinyinWordRecord(
                    acceptCount: 0, skipCount: 0, undoCount: 0, recencyEMA: 0, lastUsedTS: now
                )
                sRec.skipCount += 1
                sRec.recencyEMA = max(0, Self.decayed(sRec.recencyEMA, lastTS: sRec.lastUsedTS, now: now) - 0.35)
                sRec.lastUsedTS = now
                pinyinCache[sKey] = sRec
                updatedSkippedRec = (skipped, sRec)
            }

            if !appBundleID.isEmpty {
                let aKey = AppWordKey(appID: appBundleID, pinyin: normPinyin, word: cleanWord)
                var aRec = appCache[aKey] ?? CountRecord(count: 0, recencyEMA: 0, lastUsedTS: now)
                aRec.recencyEMA = Self.decayed(aRec.recencyEMA, lastTS: aRec.lastUsedTS, now: now) + 1.0
                aRec.count += 1
                aRec.lastUsedTS = now
                appCache[aKey] = aRec
                updatedAppRec = aRec
            }
        }

        // 记录前文 3 字 / 2 字 / 1 字搭配（同时维护反向锚点表支持 0ms 个人续写）
        for tailLen in [3, 2, 1] {
            let tail = Self.contextTail(leftContext, maxChars: tailLen)
            if tail.count == tailLen {
                let bKey = BigramKey(prevTail: tail, word: cleanWord)
                var bRec = bigramCache[bKey] ?? CountRecord(count: 0, recencyEMA: 0, lastUsedTS: now)
                bRec.recencyEMA = Self.decayed(bRec.recencyEMA, lastTS: bRec.lastUsedTS, now: now) + 1.0
                bRec.count += 1
                bRec.lastUsedTS = now
                bigramCache[bKey] = bRec
                if tailLen >= 2 {
                    bigramByTail[tail, default: []].insert(cleanWord)
                }
                updatedBigrams.append((tail, bRec))
            }
        }

        // 若用户跳过首位，执行在线 Pairwise Margin 权重自迭代
        if selectedRank > 0, let cf = chosenFeatures, let sf = skippedTopFeatures {
            weights.applyPairwiseUpdate(chosen: cf, skippedTop: sf)
            updatedWeights = weights
        }

        lock.unlock()

        let pinyinRecSnapshot = updatedPinyinRec
        let skippedRecSnapshot = updatedSkippedRec
        let bigramsSnapshot = updatedBigrams
        let appRecSnapshot = updatedAppRec
        let weightsSnapshot = updatedWeights

        writeQueue.async { [weak self] in
            guard let self else { return }
            if let rec = pinyinRecSnapshot {
                self.upsertPinyinPrefLocked(pinyin: normPinyin, word: cleanWord, rec: rec)
            }
            if let (skippedWord, sRec) = skippedRecSnapshot {
                self.upsertPinyinPrefLocked(pinyin: normPinyin, word: skippedWord, rec: sRec)
            }
            for (tail, bRec) in bigramsSnapshot {
                self.upsertBigramLocked(prevTail: tail, word: cleanWord, rec: bRec)
            }
            if let aRec = appRecSnapshot, !appBundleID.isEmpty {
                self.upsertAppPrefLocked(appID: appBundleID, pinyin: normPinyin, word: cleanWord, rec: aRec)
            }
            if let w = weightsSnapshot {
                self.persistWeightsLocked(w)
            }
        }
    }

    /// 记录退格撤销负反馈（用户上屏后 4 秒内连续退格删掉了刚上屏的词），并同步降权/清理命中的自动沉淀短语
    public func recordUndoRegret(
        pinyin: String,
        undoneWord: String,
        promotedPhrase: String? = nil,
        isSecureInput: Bool,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        guard !isSecureInput else { return }
        let normPinyin = Self.normalizePinyinKey(pinyin)
        guard !normPinyin.isEmpty, !undoneWord.isEmpty else { return }

        var updatedPhrases: [LearnedPhraseRecord] = []
        var deletedPhrases: [String] = []

        lock.lock()
        let key = PinyinWordKey(pinyin: normPinyin, word: undoneWord)
        var rec = pinyinCache[key] ?? PinyinWordRecord(
            acceptCount: 0, skipCount: 0, undoCount: 0, recencyEMA: 0, lastUsedTS: now
        )
        rec.undoCount += 1
        rec.recencyEMA = max(0, Self.decayed(rec.recencyEMA, lastTS: rec.lastUsedTS, now: now) - 0.8)
        rec.lastUsedTS = now
        pinyinCache[key] = rec
        let recSnapshot = rec

        // 同步降权/移除命中的长期自动造词短语
        var targets = [undoneWord]
        if let p = promotedPhrase, !p.isEmpty, p != undoneWord {
            targets.append(p)
        }
        for phrase in targets {
            if var pRec = learnedPhrases[phrase] {
                if pRec.count <= 1 {
                    learnedPhrases.removeValue(forKey: phrase)
                    deletedPhrases.append(phrase)
                } else {
                    pRec.count -= 1
                    pRec.recencyEMA = max(0, Self.decayed(pRec.recencyEMA, lastTS: pRec.lastUsedTS, now: now) - 1.0)
                    pRec.lastUsedTS = now
                    learnedPhrases[phrase] = pRec
                    updatedPhrases.append(pRec)
                }
            }
        }
        lock.unlock()

        let phrasesToUpsert = updatedPhrases
        let phrasesToDelete = deletedPhrases
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.upsertPinyinPrefLocked(pinyin: normPinyin, word: undoneWord, rec: recSnapshot)
            for pRec in phrasesToUpsert {
                self.upsertLearnedPhraseLocked(pRec)
            }
            for phrase in phrasesToDelete {
                self.deleteLearnedPhraseLocked(phrase)
            }
        }
    }

    /// 等待所有异步 SQLite 写入落盘（供单元测试与安全退出使用）
    public func flush() {
        writeQueue.sync {}
    }

    /// 返回当前本地记忆库统计概览
    public func stats() -> UserMemoryStats {
        lock.lock()
        defer { lock.unlock() }
        return UserMemoryStats(
            pinyinEntries: pinyinCache.count,
            contextBigrams: bigramCache.count,
            appEntries: appCache.count,
            learnedPhrases: learnedPhrases.count,
            weightUpdates: weights.updateCount
        )
    }

    /// 清空全部内存与 SQLite 偏好记忆并恢复默认权重
    public func resetAll(postNotification: Bool = true) {
        lock.lock()
        pinyinCache.removeAll()
        pinyinToWords.removeAll()
        firstCharPinyinKeys.removeAll()
        wordToPinyins.removeAll()
        bigramCache.removeAll()
        bigramByTail.removeAll()
        appCache.removeAll()
        learnedPhrases.removeAll()
        weights = RankerWeights()
        lock.unlock()

        writeQueue.sync {
            guard let handle = db else { return }
            _ = sqlite3_exec(handle, "DELETE FROM pinyin_prefs; DELETE FROM context_bigrams; DELETE FROM app_prefs; DELETE FROM learned_phrases; DELETE FROM ranker_weights;", nil, nil, nil)
        }

        if postNotification {
            DistributedNotificationCenter.default().postNotificationName(
                Self.didResetNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }

    /// 仅重载内存缓存（当外部设置面板清空数据库后由分布式通知触发）
    public func reloadFromDisk() {
        writeQueue.sync {
            if let handle = db {
                sqlite3_close(handle)
                db = nil
            }
        }
        lock.lock()
        pinyinCache.removeAll()
        pinyinToWords.removeAll()
        firstCharPinyinKeys.removeAll()
        wordToPinyins.removeAll()
        bigramCache.removeAll()
        bigramByTail.removeAll()
        appCache.removeAll()
        learnedPhrases.removeAll()
        weights = RankerWeights()
        lock.unlock()
        openAndHydrate()
    }

    // MARK: - 私有 SQLite 初始化与读写

    private func openAndHydrate() {
        writeQueue.sync {
            let dir = dbURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            var handle: OpaquePointer?
            guard sqlite3_open_v2(
                dbURL.path,
                &handle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK, let handle else {
                if let handle { sqlite3_close(handle) }
                return
            }
            self.db = handle

            let schemaSQL = """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS pinyin_prefs (
                pinyin_key TEXT NOT NULL,
                word TEXT NOT NULL,
                accept_count INTEGER NOT NULL DEFAULT 0,
                skip_count INTEGER NOT NULL DEFAULT 0,
                undo_count INTEGER NOT NULL DEFAULT 0,
                recency_ema REAL NOT NULL DEFAULT 0,
                last_used_ts REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (pinyin_key, word)
            );
            CREATE TABLE IF NOT EXISTS context_bigrams (
                prev_tail TEXT NOT NULL,
                word TEXT NOT NULL,
                count INTEGER NOT NULL DEFAULT 0,
                recency_ema REAL NOT NULL DEFAULT 0,
                last_used_ts REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (prev_tail, word)
            );
            CREATE TABLE IF NOT EXISTS app_prefs (
                app_bundle_id TEXT NOT NULL,
                pinyin_key TEXT NOT NULL,
                word TEXT NOT NULL,
                accept_count INTEGER NOT NULL DEFAULT 0,
                recency_ema REAL NOT NULL DEFAULT 0,
                last_used_ts REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (app_bundle_id, pinyin_key, word)
            );
            CREATE TABLE IF NOT EXISTS learned_phrases (
                phrase TEXT PRIMARY KEY,
                full_pinyin TEXT NOT NULL,
                initials TEXT NOT NULL,
                count INTEGER NOT NULL DEFAULT 0,
                recency_ema REAL NOT NULL DEFAULT 0,
                last_used_ts REAL NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS ranker_weights (
                feature_key TEXT PRIMARY KEY,
                weight REAL NOT NULL,
                update_count INTEGER NOT NULL DEFAULT 0
            );
            """
            _ = sqlite3_exec(handle, schemaSQL, nil, nil, nil)
            hydrateCachesLocked(handle)
        }
    }

    private func hydrateCachesLocked(_ handle: OpaquePointer) {
        var newPinyin: [PinyinWordKey: PinyinWordRecord] = [:]
        var newPinyinWords: [String: Set<String>] = [:]
        var newFirstCharBuckets: [Character: Set<String>] = [:]
        var newWordToPinyins: [String: Set<String>] = [:]
        var newBigrams: [BigramKey: CountRecord] = [:]
        var newBigramByTail: [String: Set<String>] = [:]
        var newApps: [AppWordKey: CountRecord] = [:]
        var newPhrases: [String: LearnedPhraseRecord] = [:]
        var loadedWeights = RankerWeights()

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT pinyin_key, word, accept_count, skip_count, undo_count, recency_ema, last_used_ts FROM pinyin_prefs ORDER BY last_used_ts DESC LIMIT 4000;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let p = Self.colText(stmt, 0)
                let w = Self.colText(stmt, 1)
                let rec = PinyinWordRecord(
                    acceptCount: Int(sqlite3_column_int(stmt, 2)),
                    skipCount: Int(sqlite3_column_int(stmt, 3)),
                    undoCount: Int(sqlite3_column_int(stmt, 4)),
                    recencyEMA: sqlite3_column_double(stmt, 5),
                    lastUsedTS: sqlite3_column_double(stmt, 6)
                )
                newPinyin[PinyinWordKey(pinyin: p, word: w)] = rec
                newPinyinWords[p, default: []].insert(w)
                if let first = p.first {
                    newFirstCharBuckets[first, default: []].insert(p)
                }
                newWordToPinyins[w, default: []].insert(p)
            }
        }
        sqlite3_finalize(stmt)

        stmt = nil
        if sqlite3_prepare_v2(handle, "SELECT prev_tail, word, count, recency_ema, last_used_ts FROM context_bigrams ORDER BY last_used_ts DESC LIMIT 4000;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let tail = Self.colText(stmt, 0)
                let w = Self.colText(stmt, 1)
                newBigrams[BigramKey(prevTail: tail, word: w)] = CountRecord(
                    count: Int(sqlite3_column_int(stmt, 2)),
                    recencyEMA: sqlite3_column_double(stmt, 3),
                    lastUsedTS: sqlite3_column_double(stmt, 4)
                )
                if tail.count >= 2 {
                    newBigramByTail[tail, default: []].insert(w)
                }
            }
        }
        sqlite3_finalize(stmt)

        stmt = nil
        if sqlite3_prepare_v2(handle, "SELECT app_bundle_id, pinyin_key, word, accept_count, recency_ema, last_used_ts FROM app_prefs ORDER BY last_used_ts DESC LIMIT 3000;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let appID = Self.colText(stmt, 0)
                let p = Self.colText(stmt, 1)
                let w = Self.colText(stmt, 2)
                newApps[AppWordKey(appID: appID, pinyin: p, word: w)] = CountRecord(
                    count: Int(sqlite3_column_int(stmt, 3)),
                    recencyEMA: sqlite3_column_double(stmt, 4),
                    lastUsedTS: sqlite3_column_double(stmt, 5)
                )
            }
        }
        sqlite3_finalize(stmt)

        stmt = nil
        if sqlite3_prepare_v2(handle, "SELECT phrase, full_pinyin, initials, count, recency_ema, last_used_ts FROM learned_phrases ORDER BY last_used_ts DESC LIMIT 1200;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let phrase = Self.colText(stmt, 0)
                let fullP = Self.colText(stmt, 1)
                let inits = Self.colText(stmt, 2)
                newPhrases[phrase] = LearnedPhraseRecord(
                    phrase: phrase,
                    fullPinyin: fullP,
                    initials: inits,
                    count: Int(sqlite3_column_int(stmt, 3)),
                    recencyEMA: sqlite3_column_double(stmt, 4),
                    lastUsedTS: sqlite3_column_double(stmt, 5)
                )
            }
        }
        sqlite3_finalize(stmt)

        stmt = nil
        if sqlite3_prepare_v2(handle, "SELECT feature_key, weight, update_count FROM ranker_weights;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = Self.colText(stmt, 0)
                let val = sqlite3_column_double(stmt, 1)
                let upd = Int(sqlite3_column_int(stmt, 2))
                loadedWeights.updateCount = max(loadedWeights.updateCount, upd)
                switch key {
                case "rimePrior": loadedWeights.rimePrior = val
                case "exactPinyinPref": loadedWeights.exactPinyinPref = val
                case "regretPenalty": loadedWeights.regretPenalty = val
                case "contextBigram": loadedWeights.contextBigram = val
                case "appScenePref": loadedWeights.appScenePref = val
                case "docLexiconMatch": loadedWeights.docLexiconMatch = val
                case "docContinuation": loadedWeights.docContinuation = val
                case "workingMemoryMatch": loadedWeights.workingMemoryMatch = val
                case "workingMemoryContinuation": loadedWeights.workingMemoryContinuation = val
                case "neuralContext": loadedWeights.neuralContext = val
                case "domainScene": loadedWeights.domainScene = val
                default: break
                }
            }
        }
        sqlite3_finalize(stmt)

        lock.lock()
        pinyinCache = newPinyin
        pinyinToWords = newPinyinWords
        firstCharPinyinKeys = newFirstCharBuckets
        wordToPinyins = newWordToPinyins
        bigramCache = newBigrams
        bigramByTail = newBigramByTail
        appCache = newApps
        learnedPhrases = newPhrases
        weights = loadedWeights
        lock.unlock()
    }

    private func upsertPinyinPrefLocked(pinyin: String, word: String, rec: PinyinWordRecord) {
        guard let handle = db else { return }
        let sql = """
        INSERT INTO pinyin_prefs (pinyin_key, word, accept_count, skip_count, undo_count, recency_ema, last_used_ts)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(pinyin_key, word) DO UPDATE SET
            accept_count=excluded.accept_count,
            skip_count=excluded.skip_count,
            undo_count=excluded.undo_count,
            recency_ema=excluded.recency_ema,
            last_used_ts=excluded.last_used_ts;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pinyin, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, word, -1, Self.sqliteTransient)
        sqlite3_bind_int(stmt, 3, Int32(rec.acceptCount))
        sqlite3_bind_int(stmt, 4, Int32(rec.skipCount))
        sqlite3_bind_int(stmt, 5, Int32(rec.undoCount))
        sqlite3_bind_double(stmt, 6, rec.recencyEMA)
        sqlite3_bind_double(stmt, 7, rec.lastUsedTS)
        _ = sqlite3_step(stmt)
    }

    private func upsertBigramLocked(prevTail: String, word: String, rec: CountRecord) {
        guard let handle = db else { return }
        let sql = """
        INSERT INTO context_bigrams (prev_tail, word, count, recency_ema, last_used_ts)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(prev_tail, word) DO UPDATE SET
            count=excluded.count,
            recency_ema=excluded.recency_ema,
            last_used_ts=excluded.last_used_ts;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, prevTail, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, word, -1, Self.sqliteTransient)
        sqlite3_bind_int(stmt, 3, Int32(rec.count))
        sqlite3_bind_double(stmt, 4, rec.recencyEMA)
        sqlite3_bind_double(stmt, 5, rec.lastUsedTS)
        _ = sqlite3_step(stmt)
    }

    private func upsertAppPrefLocked(appID: String, pinyin: String, word: String, rec: CountRecord) {
        guard let handle = db else { return }
        let sql = """
        INSERT INTO app_prefs (app_bundle_id, pinyin_key, word, accept_count, recency_ema, last_used_ts)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(app_bundle_id, pinyin_key, word) DO UPDATE SET
            accept_count=excluded.accept_count,
            recency_ema=excluded.recency_ema,
            last_used_ts=excluded.last_used_ts;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, appID, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, pinyin, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 3, word, -1, Self.sqliteTransient)
        sqlite3_bind_int(stmt, 4, Int32(rec.count))
        sqlite3_bind_double(stmt, 5, rec.recencyEMA)
        sqlite3_bind_double(stmt, 6, rec.lastUsedTS)
        _ = sqlite3_step(stmt)
    }

    private func upsertLearnedPhraseLocked(_ rec: LearnedPhraseRecord) {
        guard let handle = db else { return }
        let sql = """
        INSERT INTO learned_phrases (phrase, full_pinyin, initials, count, recency_ema, last_used_ts)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(phrase) DO UPDATE SET
            full_pinyin=excluded.full_pinyin,
            initials=excluded.initials,
            count=excluded.count,
            recency_ema=excluded.recency_ema,
            last_used_ts=excluded.last_used_ts;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, rec.phrase, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 2, rec.fullPinyin, -1, Self.sqliteTransient)
        sqlite3_bind_text(stmt, 3, rec.initials, -1, Self.sqliteTransient)
        sqlite3_bind_int(stmt, 4, Int32(rec.count))
        sqlite3_bind_double(stmt, 5, rec.recencyEMA)
        sqlite3_bind_double(stmt, 6, rec.lastUsedTS)
        _ = sqlite3_step(stmt)
    }

    private func deleteLearnedPhraseLocked(_ phrase: String) {
        guard let handle = db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "DELETE FROM learned_phrases WHERE phrase = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, phrase, -1, Self.sqliteTransient)
        _ = sqlite3_step(stmt)
    }

    private func persistWeightsLocked(_ w: RankerWeights) {
        guard let handle = db else { return }
        let entries: [(String, Double)] = [
            ("rimePrior", w.rimePrior),
            ("exactPinyinPref", w.exactPinyinPref),
            ("regretPenalty", w.regretPenalty),
            ("contextBigram", w.contextBigram),
            ("appScenePref", w.appScenePref),
            ("docLexiconMatch", w.docLexiconMatch),
            ("docContinuation", w.docContinuation),
            ("workingMemoryMatch", w.workingMemoryMatch),
            ("workingMemoryContinuation", w.workingMemoryContinuation),
            ("neuralContext", w.neuralContext),
            ("domainScene", w.domainScene)
        ]
        let sql = """
        INSERT INTO ranker_weights (feature_key, weight, update_count)
        VALUES (?, ?, ?)
        ON CONFLICT(feature_key) DO UPDATE SET
            weight=excluded.weight,
            update_count=excluded.update_count;
        """
        for (k, v) in entries {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, k, -1, Self.sqliteTransient)
                sqlite3_bind_double(stmt, 2, v)
                sqlite3_bind_int(stmt, 3, Int32(w.updateCount))
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    private static func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let cstr = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: cstr)
    }

    private static func normalizePinyinKey(_ raw: String) -> String {
        raw.lowercased().filter { $0 >= "a" && $0 <= "z" }
    }

    private static func contextTail(_ text: String, maxChars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // 剥离末尾常见标点后再取末字作为搭配锚点
        let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "，。！？、；：,.!?;: "))
        guard !stripped.isEmpty else { return "" }
        return String(stripped.suffix(maxChars))
    }

    private static func decayed(_ value: Double, lastTS: TimeInterval, now: TimeInterval) -> Double {
        let dt = max(0, now - lastTS)
        return value * pow(0.5, dt / halfLifeSeconds)
    }
}
