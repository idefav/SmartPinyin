@_implementationOnly import CLlamaBridge
import Foundation
import SharedIPC

/// 档位 C 本地推理协调器（严格 < 2GB 总内存预算）：
/// - 日常轻量槽（light）：Qwen3-0.6B-Q4_K_M（~380MB），负责语境重排（<40ms）与联想续写
/// - 专职翻译槽（translation）：HY-MT1.5-1.8B-Q4_K_M（~1.08GB），负责中→英/多语种实时翻译
/// - 互斥懒加载：切入翻译槽前先卸载轻量槽，确保任意时刻仅驻留单个模型，峰值物理内存稳稳 < 2GB
/// - 空闲自动卸载：超过 idleUnloadSeconds 无调用自动释放全部权重
public final class LocalInferenceCoordinator: @unchecked Sendable {
    public enum ModelSlot: String, Sendable {
        case none
        case light
        case translation
    }

    public struct LoadMetrics: Sendable {
        public let slot: ModelSlot
        public let loadMs: Double
        public let physicalFootprintMB: Double
    }

    public struct RerankOutcome: Sendable {
        public let orderedCandidates: [String]
        public let scores: [Double]
        public let scoredCandidates: [ScoredCandidate]
        public let latencyMs: Double
        public let timedOutOrSkipped: Bool
        public let physicalFootprintMB: Double
    }

    public struct PredictionOutcome: Sendable {
        public let suggestions: [String]
        public let ttftMs: Double
        public let latencyMs: Double
        public let physicalFootprintMB: Double
    }

    private let config: InferenceBudgetConfig
    private let cache = TranslationLRUCache(capacity: 256)
    private let rerankCache = RerankLRUCache(capacity: 64)
    private let predictionCache = PredictionLRUCache(capacity: 128)
    private let proofreadCache = ProofreadLRUCache(capacity: 128)
    private let neuralProofreader = DraftNeuralProofreader()
    private let workerQueue = DispatchQueue(label: "com.smartpinyin.inference.worker", qos: .userInteractive)
    private let stateLock = NSLock()

    private var activeSlot: ModelSlot = .none
    private var activeHandle: OpaquePointer?
    private var activeModelName: String = "idle"
    private var activeRequestID: String?
    /// 已取消但可能仍在 workerQueue 中排队的请求 ID（防止旧请求继续执行并污染缓存）
    private var cancelledRequestIDs: [String] = []
    private var idleTimer: DispatchSourceTimer?

    public init(config: InferenceBudgetConfig) {
        self.config = config
    }

    deinit {
        unloadNow()
    }

    // MARK: - 公开同步/异步推理接口

    public static func backendSummary() -> String {
        guard let ptr = spm_llama_backend_summary() else { return "unknown" }
        defer { free(ptr) }
        return String(cString: ptr)
    }

    public func currentStatus() -> InferenceServiceStatus {
        stateLock.lock()
        let slot = activeSlot.rawValue
        let name = activeModelName
        stateLock.unlock()
        return InferenceServiceStatus(
            activeSlot: slot,
            activeModelName: name,
            physicalFootprintMB: ProcessMemoryMonitor.physicalFootprintMB(),
            memoryBudgetMB: config.memoryBudgetMB,
            cachedTranslations: cache.count
        )
    }

    public func cancel(requestID: String) {
        stateLock.lock()
        cancelledRequestIDs.append(requestID)
        if cancelledRequestIDs.count > 64 {
            cancelledRequestIDs.removeFirst(cancelledRequestIDs.count - 64)
        }
        // 在 stateLock 持有期间执行无锁原子取消，彻底杜绝解锁后 workerQueue 并发 unloadActiveLocked() 销毁 handle 引发 UAF
        if activeRequestID == requestID, let handle = activeHandle {
            spm_llama_request_cancel(handle)
        }
        stateLock.unlock()
    }

    public func clearTranslationCache() {
        cache.clear()
        rerankCache.clear()
        predictionCache.clear()
        proofreadCache.clear()
    }

    public func clearRerankCache() {
        rerankCache.clear()
    }

    public func clearPredictionCache() {
        predictionCache.clear()
    }

    private func consumeCancelled(_ requestID: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let idx = cancelledRequestIDs.firstIndex(of: requestID) {
            cancelledRequestIDs.remove(at: idx)
            return true
        }
        return false
    }

    public func unloadNow() {
        workerQueue.sync {
            self.unloadActiveLocked()
        }
    }

    /// 异步预热指定模型槽（例如开启翻译模式时提前切入 HY-MT1.5，降低首次自动翻译延迟）
    public func prewarmSlot(_ slot: ModelSlot, completion: (@Sendable (Bool) -> Void)? = nil) {
        workerQueue.async {
            let ok = (self.activateSlotLocked(slot) != nil)
            completion?(ok)
        }
    }

    /// 显式切换模型槽并返回冷加载耗时与内存快照（供 Benchmark 实测）
    @discardableResult
    public func ensureSlotLoadedSync(_ slot: ModelSlot) -> LoadMetrics {
        workerQueue.sync {
            let start = CFAbsoluteTimeGetCurrent()
            let _ = self.activateSlotLocked(slot)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            return LoadMetrics(
                slot: slot,
                loadMs: ms,
                physicalFootprintMB: ProcessMemoryMonitor.physicalFootprintMB()
            )
        }
    }

    // MARK: - 1. 语境候选重排 (L2, 目标 < 40ms)

    public func rerankCandidates(
        leftContext: String,
        pinyin: String,
        candidates: [String],
        requestID: String,
        timeoutMs: Int,
        completion: @escaping @Sendable ([String]?) -> Void
    ) {
        workerQueue.async {
            if self.consumeCancelled(requestID) {
                completion(nil)
                return
            }
            let outcome = self.rerankCandidatesSync(
                leftContext: leftContext,
                pinyin: pinyin,
                candidates: candidates,
                requestID: requestID,
                timeoutMs: timeoutMs
            )
            completion(outcome.timedOutOrSkipped ? nil : outcome.orderedCandidates)
        }
    }

    /// 返回带原始连续神经语境分数的候选列表（供 CandidateFusionRanker 做统一连续分融合，且保留超时前已算完的前 K 项）
    public func rerankCandidatesScored(
        leftContext: String,
        pinyin: String,
        candidates: [String],
        requestID: String,
        timeoutMs: Int,
        completion: @escaping @Sendable ([ScoredCandidate]?) -> Void
    ) {
        workerQueue.async {
            if self.consumeCancelled(requestID) {
                completion(nil)
                return
            }
            let outcome = self.rerankCandidatesSync(
                leftContext: leftContext,
                pinyin: pinyin,
                candidates: candidates,
                requestID: requestID,
                timeoutMs: timeoutMs
            )
            guard !outcome.timedOutOrSkipped, !outcome.scoredCandidates.isEmpty else {
                completion(nil)
                return
            }
            completion(outcome.scoredCandidates)
        }
    }

    public func rerankCandidatesSync(
        leftContext: String,
        pinyin: String,
        candidates: [String],
        requestID: String = UUID().uuidString,
        timeoutMs: Int = 40
    ) -> RerankOutcome {
        // 无真实上文（< 2 字）时跳过神经重排，避免伪造前缀污染高质量万象首候选
        let cleanContext = leftContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidates.count > 1, cleanContext.count >= 2 else {
            return RerankOutcome(
                orderedCandidates: candidates,
                scores: [],
                scoredCandidates: [],
                latencyMs: 0,
                timedOutOrSkipped: true,
                physicalFootprintMB: ProcessMemoryMonitor.physicalFootprintMB()
            )
        }
        // 优先命中 L2 重排 LRU 缓存（回退改字/重复语境时 < 0.1ms 零 GPU 重算）
        let contextPrefix = String(cleanContext.suffix(104))
        if let cachedScored = rerankCache.get(contextPrefix: contextPrefix, candidates: candidates) {
            let mem = ProcessMemoryMonitor.physicalFootprintMB()
            let scoreByText = Dictionary(uniqueKeysWithValues: cachedScored.map { ($0.text, $0.score) })
            let indexed = candidates.enumerated().map { idx, text -> (origIdx: Int, text: String, score: Double) in
                let rankPrior = -0.42 * log2(Double(idx) + 1.0)
                return (idx, text, (scoreByText[text] ?? -20.0) + rankPrior)
            }
            var sorted = indexed.sorted { $0.score > $1.score }
            if let best = sorted.first, best.origIdx != 0,
               let origFirst = indexed.first,
               (best.score - origFirst.score) < 0.70,
               let origPos = sorted.firstIndex(where: { $0.origIdx == 0 }) {
                let firstItem = sorted.remove(at: origPos)
                sorted.insert(firstItem, at: 0)
            }
            return RerankOutcome(
                orderedCandidates: sorted.map(\.text),
                scores: sorted.map(\.score),
                scoredCandidates: cachedScored,
                latencyMs: 0.05,
                timedOutOrSkipped: false,
                physicalFootprintMB: mem
            )
        }

        guard let handle = activateSlotLocked(.light) else {
            return RerankOutcome(
                orderedCandidates: candidates,
                scores: [],
                scoredCandidates: [],
                latencyMs: 0,
                timedOutOrSkipped: true,
                physicalFootprintMB: ProcessMemoryMonitor.physicalFootprintMB()
            )
        }

        beginRequest(requestID, handle: handle)
        defer { endRequest(requestID) }

        var scores = [Double](repeating: -1e9, count: candidates.count)
        var elapsed: Double = 0

        let ok = withCStringArray(candidates) { cPtrs in
            spm_llama_score_candidates(
                handle,
                contextPrefix,
                cPtrs,
                Int32(candidates.count),
                Int32(timeoutMs),
                &scores,
                &elapsed
            )
        }

        let mem = ProcessMemoryMonitor.physicalFootprintMB()
        guard ok else {
            return RerankOutcome(
                orderedCandidates: candidates,
                scores: scores,
                scoredCandidates: [],
                latencyMs: elapsed,
                timedOutOrSkipped: true,
                physicalFootprintMB: mem
            )
        }

        // 保留已成功打分的原始连续神经对数似然（未算完的哨兵值 -1e9 不参与标准化）
        let scoredList: [ScoredCandidate] = candidates.enumerated().compactMap { idx, text in
            let s = scores[idx]
            guard s.isFinite && s > -1e8 else { return nil }
            return ScoredCandidate(text: text, score: s)
        }
        guard scoredList.count >= 2 else {
            return RerankOutcome(
                orderedCandidates: candidates,
                scores: scores,
                scoredCandidates: [],
                latencyMs: elapsed,
                timedOutOrSkipped: true,
                physicalFootprintMB: mem
            )
        }

        // 仅当全部候选均在超时前完成打分时写入 LRU 缓存，避免缓存截断结果
        if scoredList.count == candidates.count {
            rerankCache.set(contextPrefix: contextPrefix, candidates: candidates, scored: scoredList)
        }

        // 兼容旧接口：稳健融合 L1 排名先验 + 神经语境分数（未打分的排在末尾保持原序）
        let minScored = scoredList.map(\.score).min() ?? -20.0
        let indexed = candidates.enumerated().map { idx, text -> (origIdx: Int, text: String, score: Double) in
            let rankPrior = -0.42 * log2(Double(idx) + 1.0)
            let raw = (scores[idx].isFinite && scores[idx] > -1e8) ? scores[idx] : (minScored - 0.5)
            return (idx, text, raw + rankPrior)
        }
        var sorted = indexed.sorted { $0.score > $1.score }
        if let best = sorted.first, best.origIdx != 0,
           let origFirst = indexed.first,
           (best.score - origFirst.score) < 0.70 {
            if let origPos = sorted.firstIndex(where: { $0.origIdx == 0 }) {
                let firstItem = sorted.remove(at: origPos)
                sorted.insert(firstItem, at: 0)
            }
        }
        return RerankOutcome(
            orderedCandidates: sorted.map(\.text),
            scores: sorted.map(\.score),
            scoredCandidates: scoredList,
            latencyMs: elapsed,
            timedOutOrSkipped: false,
            physicalFootprintMB: mem
        )
    }

    // MARK: - 2. 联想词句续写 (L2, Qwen3-0.6B 关闭 thinking)

    public func predictContinuation(
        leftContext: String,
        maxSuggestions: Int,
        requestID: String,
        completion: @escaping @Sendable ([String]) -> Void
    ) {
        workerQueue.async {
            if self.consumeCancelled(requestID) {
                completion([])
                return
            }
            let outcome = self.predictContinuationSync(
                leftContext: leftContext,
                maxSuggestions: maxSuggestions,
                requestID: requestID
            )
            completion(outcome.suggestions)
        }
    }

    public func predictContinuationSync(
        leftContext: String,
        maxSuggestions: Int = 3,
        requestID: String = UUID().uuidString
    ) -> PredictionOutcome {
        let trimmed = leftContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            return PredictionOutcome(
                suggestions: [],
                ttftMs: 0,
                latencyMs: 0,
                physicalFootprintMB: ProcessMemoryMonitor.physicalFootprintMB()
            )
        }

        let contextTail = String(trimmed.suffix(48))
        let cappedMax = max(1, min(4, maxSuggestions))

        // 1. 优先命中 128 项联想 LRU 缓存（< 0.1ms 零 GPU 开销）
        if let cached = predictionCache.get(contextTail: contextTail, maxSuggestions: cappedMax) {
            return PredictionOutcome(
                suggestions: cached,
                ttftMs: 0.05,
                latencyMs: 0.05,
                physicalFootprintMB: ProcessMemoryMonitor.physicalFootprintMB()
            )
        }

        // 2. 保护翻译模型槽：若当前正驻留 HY-MT1.5 翻译模型，不因后台联想强行颠簸卸载翻译权重
        stateLock.lock()
        let isTranslationLoaded = (activeSlot == .translation && activeHandle != nil)
        stateLock.unlock()
        if isTranslationLoaded {
            return PredictionOutcome(
                suggestions: [],
                ttftMs: 0,
                latencyMs: 0,
                physicalFootprintMB: ProcessMemoryMonitor.physicalFootprintMB()
            )
        }

        guard let handle = activateSlotLocked(.light) else {
            return PredictionOutcome(
                suggestions: [],
                ttftMs: 0,
                latencyMs: 0,
                physicalFootprintMB: ProcessMemoryMonitor.physicalFootprintMB()
            )
        }

        beginRequest(requestID, handle: handle)
        defer { endRequest(requestID) }

        // 3. 共享 KV 前缀原生多分支续写（8 独立分支 + 逗号桥接 × 最多 5 token，总超时 140ms）
        var branchRes = spm_llama_predict_branches(handle, contextTail, 8, 5, 140)
        defer { spm_llama_free_branch_result(&branchRes) }

        let mem = ProcessMemoryMonitor.physicalFootprintMB()
        guard branchRes.ok, let itemsPtr = branchRes.items, branchRes.count > 0 else {
            return PredictionOutcome(
                suggestions: [],
                ttftMs: branchRes.total_ms,
                latencyMs: branchRes.total_ms,
                physicalFootprintMB: mem
            )
        }

        var rawBranches: [RawContinuationBranch] = []
        rawBranches.reserveCapacity(Int(branchRes.count))
        for i in 0..<Int(branchRes.count) {
            let item = itemsPtr[i]
            guard let cText = item.text else { continue }
            rawBranches.append(RawContinuationBranch(
                text: String(cString: cText),
                avgLogProb: item.avg_logprob
            ))
        }

        let refined = PredictionPostProcessor.refineBranches(
            rawBranches,
            leftContext: contextTail,
            maxSuggestions: cappedMax
        )
        if !refined.isEmpty {
            predictionCache.set(contextTail: contextTail, maxSuggestions: cappedMax, suggestions: refined)
        }

        return PredictionOutcome(
            suggestions: refined,
            ttftMs: branchRes.total_ms,
            latencyMs: branchRes.total_ms,
            physicalFootprintMB: mem
        )
    }

    // MARK: - 3. 实时高质量多语种翻译 (L3, HY-MT1.5-1.8B 互斥懒加载)

    public func translateText(
        sourceText: String,
        leftContext: String,
        target: TargetLanguage,
        requestID: String,
        completion: @escaping @Sendable (TranslationReplyPayload?) -> Void
    ) {
        workerQueue.async {
            if self.consumeCancelled(requestID) {
                completion(nil)
                return
            }
            let payload = self.translateTextSync(
                sourceText: sourceText,
                leftContext: leftContext,
                target: target,
                requestID: requestID
            )
            completion(payload)
        }
    }

    public func translateTextSync(
        sourceText: String,
        leftContext: String = "",
        target: TargetLanguage,
        requestID: String = UUID().uuidString,
        bypassCache: Bool = false
    ) -> TranslationReplyPayload? {
        _ = leftContext // 严格隔离：绝不把输入框已有目标语译文或无关段落注入翻译 Prompt，彻底消除跨段冲突与复读
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if consumeCancelled(requestID) { return nil }

        if !bypassCache, let cached = cache.get(source: trimmed, targetLang: target.rawValue) {
            return TranslationReplyPayload(
                translatedText: cached,
                latencyMs: 0.1,
                fromCache: true,
                backendName: "\(activeModelName) (cache)",
                physicalFootprintMB: ProcessMemoryMonitor.physicalFootprintMB()
            )
        }

        guard let handle = activateSlotLocked(.translation) else { return nil }
        if consumeCancelled(requestID) { return nil }

        beginRequest(requestID, handle: handle)
        defer { endRequest(requestID) }

        // 遵循腾讯 HY-MT1.5 官方汉译外纯句指令模板（中文指令 + 中文语种名，零目标语上文污染）
        let userPrompt = "将以下文本翻译为\(target.chinesePromptName)，注意只需要输出翻译后的结果，不要额外解释：\n\(trimmed)"
        let formattedPrompt = buildPrompt(
            handle: handle,
            systemPrompt: nil,
            userPrompt: userPrompt,
            disableThinking: false
        )

        let stops = ["<｜hy_place▁holder▁no▁2｜>", "<|eos|>", "<|im_end|>", "<|endoftext|>", "\n"]
        let maxTokens = Int32(min(192, max(32, trimmed.count * 4 + 12)))
        var result = withCStringArray(stops) { cStops in
            spm_llama_generate(handle, formattedPrompt, maxTokens, 0.0, cStops, Int32(stops.count))
        }
        defer { spm_llama_free_gen_result(&result) }

        guard result.ok, !result.cancelled, let cText = result.text else { return nil }
        let cleaned = cleanTranslationOutput(String(cString: cText))
        guard Self.isValidTranslationOutput(source: trimmed, output: cleaned, target: target) else {
            return nil
        }

        cache.set(source: trimmed, targetLang: target.rawValue, translation: cleaned)
        return TranslationReplyPayload(
            translatedText: cleaned,
            latencyMs: result.total_ms,
            fromCache: false,
            backendName: activeModelName,
            physicalFootprintMB: ProcessMemoryMonitor.physicalFootprintMB()
        )
    }

    /// 译文健全性校验：拦截空串、Prompt 泄露、短句重复回声（如 "Hello! Hello!"）与极端长度幻觉，严防脏数据入缓存
    public static func isValidTranslationOutput(
        source: String,
        output: String,
        target: TargetLanguage
    ) -> Bool {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let o = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !o.isEmpty else { return false }

        // 1. 拦截指令泄露
        let forbiddenFragments = [
            "将以下文本翻译为",
            "注意只需要输出",
            "不要额外解释",
            "参考上面的信息",
            "Translate the following segment"
        ]
        for frag in forbiddenFragments where o.contains(frag) {
            return false
        }

        // 2. 拦截极端长度爆炸（如 1~2 字源文本输出几十个字符的幻觉）
        let maxReasonableLen = s.count <= 2 ? 40 : max(64, s.count * 16)
        if o.count > maxReasonableLen {
            return false
        }

        // 3. 拦截相同短句紧邻重复回声（例如 "Hello! Hello!"、"Today. Today."），仅当源文自身不含重复时触发
        let wordsOrClauses = o
            .components(separatedBy: CharacterSet(charactersIn: " \t"))
            .filter { !$0.isEmpty }
        if wordsOrClauses.count == 2,
           wordsOrClauses[0].caseInsensitiveCompare(wordsOrClauses[1]) == .orderedSame,
           s.count <= 3 {
            let half = s.count / 2
            let sourceRepeated = half > 0 && String(s.prefix(half)) == String(s.suffix(half))
            if !sourceRepeated {
                return false
            }
        }

        // 4. 汉译拉丁语系时若源文本 >= 2 汉字且输出与中文源文本完全一致，视为未翻译
        if [.english, .french, .german, .spanish].contains(target) && s.count >= 2 && o == s {
            let hasChinese = s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            if hasChinese {
                return false
            }
        }

        return true
    }

    // MARK: - 4. 整句暂存错别字语义校对 (L2, 复用 .light 槽 Qwen3-0.6B，0 额外模型内存)

    public func proofreadSentence(
        sourceText: String,
        leftContext: String,
        requestID: String,
        completion: @escaping @Sendable (ProofreadReplyPayload?) -> Void
    ) {
        workerQueue.async {
            if self.consumeCancelled(requestID) {
                completion(nil)
                return
            }
            let payload = self.proofreadSentenceSync(
                sourceText: sourceText,
                leftContext: leftContext,
                requestID: requestID
            )
            completion(payload)
        }
    }

    public func proofreadSentenceSync(
        sourceText: String,
        leftContext: String = "",
        requestID: String = UUID().uuidString,
        bypassCache: Bool = false
    ) -> ProofreadReplyPayload? {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return nil }
        if consumeCancelled(requestID) { return nil }

        if !bypassCache, let cached = proofreadCache.get(source: trimmed) {
            return ProofreadReplyPayload(
                correctedText: cached,
                hasChanges: cached != trimmed,
                latencyMs: 0.1,
                fromCache: true,
                backendName: "\(activeModelName) (cache)",
                physicalFootprintMB: ProcessMemoryMonitor.physicalFootprintMB()
            )
        }

        // 整句校对与翻译模式互斥，仅在用户主动处于草稿校对模式时调用；
        // 若先前翻译留下了 .translation 槽，此处应按档位 C 互斥卸载并切回 .light（~135ms 一次），
        // 绝不因翻译槽驻留而让整句校对在空闲卸载前（默认 3 分钟）完全失效。
        guard let handle = activateSlotLocked(.light) else { return nil }
        if consumeCancelled(requestID) { return nil }

        beginRequest(requestID, handle: handle)
        defer { endRequest(requestID) }
        if consumeCancelled(requestID) { return nil }

        // 使用「易混字定位 + 单次前向高惊讶度同音探测 + 精确联合对数似然裁决」替代 0.6B 生成式 Prompt：
        // 零幻觉、零长度漂移、不漏纠句首易混字（「再上海→在上海」），且耗时仅 ~25–60ms
        _ = leftContext
        guard let outcome = neuralProofreader.proofread(
            handle: handle,
            sourceText: trimmed,
            timeoutMs: 260
        ) else {
            return nil
        }
        if consumeCancelled(requestID) { return nil }

        let cleaned = outcome.correctedText
        guard !cleaned.isEmpty else { return nil }

        // 仅当校对完整跑完、未被取消且未因超时截断时才写入缓存，严防脏结果污染 LRU
        if outcome.isComplete {
            proofreadCache.set(source: trimmed, corrected: cleaned)
        }
        return ProofreadReplyPayload(
            correctedText: cleaned,
            hasChanges: cleaned != trimmed,
            latencyMs: outcome.latencyMs,
            fromCache: false,
            backendName: activeModelName,
            physicalFootprintMB: ProcessMemoryMonitor.physicalFootprintMB()
        )
    }

    /// 供校对与基准探针使用的精确联合对数似然批量打分（复用 .light 槽 Qwen3-0.6B）
    public func scoreExactTextsSync(
        sharedPrefix: String = "",
        candidates: [String],
        timeoutMs: Int = 250
    ) -> (scores: [Double], latencyMs: Double)? {
        guard candidates.count >= 2 else { return nil }
        return workerQueue.sync {
            guard let handle = self.activateSlotLocked(.light) else { return nil }
            spm_llama_clear_cancel(handle)
            var scores = [Double](repeating: -1e9, count: candidates.count)
            var elapsed: Double = 0
            let ok = self.withCStringArray(candidates) { cPtrs in
                spm_llama_score_texts_exact(
                    handle,
                    sharedPrefix,
                    cPtrs,
                    Int32(candidates.count),
                    Int32(timeoutMs),
                    &scores,
                    &elapsed
                )
            }
            guard ok else { return nil }
            return (scores, elapsed)
        }
    }

    // MARK: - 档位 C 互斥加载与空闲回收闸门

    private func activateSlotLocked(_ slot: ModelSlot) -> OpaquePointer? {
        rescheduleIdleUnloadTimer()

        stateLock.lock()
        if activeSlot == slot, let handle = activeHandle {
            stateLock.unlock()
            return handle
        }
        stateLock.unlock()

        // 互斥策略：切换槽位前强制卸载旧模型，确保物理内存始终低于 2GB
        unloadActiveLocked()

        var path: String
        switch slot {
        case .none:
            return nil
        case .light:
            path = config.lightModelPath
        case .translation:
            path = config.translationModelPath
        }

        // 轻量安装包先启输入法、后下载/导入模型时，动态重探一次标准模型目录，无需重启 XPC 进程即可即刻生效
        if !FileManager.default.fileExists(atPath: path), config.autoRediscoverMissingModels {
            let refreshed = InferenceBudgetConfig.defaultConfig()
            path = (slot == .light) ? refreshed.lightModelPath : refreshed.translationModelPath
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        let cConfig = SPMLlamaConfig(
            n_ctx: config.contextSize,
            n_batch: config.batchSize,
            n_gpu_layers: config.gpuLayers,
            n_threads: 0,
            quantize_kv_q8: true
        )
        guard let loaded = spm_llama_load(path, cConfig) else {
            return nil
        }

        let label = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        stateLock.lock()
        activeSlot = slot
        activeHandle = loaded
        activeModelName = label
        stateLock.unlock()
        return loaded
    }

    private func unloadActiveLocked() {
        stateLock.lock()
        let old = activeHandle
        activeHandle = nil
        activeSlot = .none
        activeModelName = "idle"
        stateLock.unlock()

        if let old {
            spm_llama_unload(old)
        }
    }

    private func rescheduleIdleUnloadTimer() {
        guard config.idleUnloadSeconds > 0 else { return }
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        timer.schedule(deadline: .now() + config.idleUnloadSeconds)
        timer.setEventHandler { [weak self] in
            self?.unloadActiveLocked()
        }
        timer.resume()
        idleTimer = timer
    }

    private func beginRequest(_ id: String, handle: OpaquePointer) {
        stateLock.lock()
        let alreadyCancelled = cancelledRequestIDs.contains(id)
        activeRequestID = id
        if alreadyCancelled {
            spm_llama_request_cancel(handle)
        } else {
            spm_llama_clear_cancel(handle)
        }
        stateLock.unlock()
    }

    private func endRequest(_ id: String) {
        stateLock.lock()
        if activeRequestID == id {
            activeRequestID = nil
        }
        stateLock.unlock()
    }

    // MARK: - Prompt 构造与输出清洗

    private func buildPrompt(
        handle: OpaquePointer,
        systemPrompt: String?,
        userPrompt: String,
        disableThinking: Bool
    ) -> String {
        let templatedPtr = spm_llama_apply_chat_template(handle, systemPrompt, userPrompt, true)
        var prompt: String
        if let templatedPtr {
            prompt = String(cString: templatedPtr)
            free(templatedPtr)
        } else {
            if let systemPrompt {
                prompt = "<|im_start|>system\n\(systemPrompt)<|im_end|>\n<|im_start|>user\n\(userPrompt)<|im_end|>\n<|im_start|>assistant\n"
            } else {
                prompt = "<|im_start|>user\n\(userPrompt)<|im_end|>\n<|im_start|>assistant\n"
            }
        }
        if disableThinking && !prompt.contains("<think>") {
            // Qwen3 空思维块直通，彻底消除思维链延迟
            prompt += "<think>\n\n</think>\n"
        }
        return prompt
    }

    private func stripThinkTags(_ text: String) -> String {
        if let endRange = text.range(of: "</think>") {
            return String(text[endRange.upperBound...])
        }
        return text
    }

    private func cleanTranslationOutput(_ raw: String) -> String {
        var s = stripThinkTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        // 如果模型输出多行，取首行有效译文
        if let firstLine = s.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            s = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    private func withCStringArray<R>(
        _ strings: [String],
        body: (UnsafePointer<UnsafePointer<CChar>?>) -> R
    ) -> R {
        let cStrings = strings.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        let constPtrs: [UnsafePointer<CChar>?] = cStrings.map { $0.map { UnsafePointer($0) } }
        return constPtrs.withUnsafeBufferPointer { buf in
            body(buf.baseAddress!)
        }
    }
}

private final class ProofreadLRUCache: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var order: [String] = []

    init(capacity: Int) {
        self.capacity = max(16, capacity)
    }

    func get(source: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = storage[source] else { return nil }
        if let idx = order.firstIndex(of: source) {
            order.remove(at: idx)
            order.append(source)
        }
        return value
    }

    func set(source: String, corrected: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[source] = corrected
        if let idx = order.firstIndex(of: source) {
            order.remove(at: idx)
        }
        order.append(source)
        while order.count > capacity {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    func clear() {
        lock.lock()
        storage.removeAll()
        order.removeAll()
        lock.unlock()
    }
}
