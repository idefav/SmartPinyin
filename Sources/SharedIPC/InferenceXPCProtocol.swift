import Foundation

/// IMK 宿主进程与独立 XPC 推理服务之间的通信契约。
/// 所有参数均采用 Objective-C / NSSecureCoding 兼容类型，确保低开销、强隔离。
@objc public protocol InferenceXPCProtocol {
    /// 语境候选重排：基于光标前文与当前拼音，返回按语境重排后的候选文本顺序。
    /// 若超时、被取消或模型不可用，返回 nil，调用方保留 L1 原始顺序。
    func rerankCandidates(
        leftContext: String,
        pinyin: String,
        candidates: [String],
        requestID: String,
        timeoutMs: Int,
        withReply reply: @escaping ([String]?) -> Void
    )

    /// 带连续神经语境得分的候选重排（返回 JSON 编码的 [ScoredCandidate]，支持与 L1 记忆/工作记忆/文档分统一融合）。
    func rerankCandidatesScored(
        leftContext: String,
        pinyin: String,
        candidates: [String],
        requestID: String,
        timeoutMs: Int,
        withReply reply: @escaping (Data?) -> Void
    )

    /// 联想词句预测：基于上屏后的前文上下文，异步预测 1~3 条自然后续短语。
    func predictContinuation(
        leftContext: String,
        maxSuggestions: Int,
        requestID: String,
        withReply reply: @escaping ([String]) -> Void
    )

    /// 实时文本翻译：将源文本翻译为 targetLanguageCode（如 "en", "ja", "ko"）。
    /// 返回 JSON 编码的 TranslationReplyPayload，包含译文、耗时与当前内存快照。
    func translateText(
        sourceText: String,
        leftContext: String,
        targetLanguageCode: String,
        requestID: String,
        withReply reply: @escaping (Data?) -> Void
    )

    /// 整句暂存错别字语义校对（复用 .light 槽 Qwen3-0.6B，100% 离线，严格 < 2GB）。
    /// 返回 JSON 编码的 ProofreadReplyPayload；模型不可用或翻译槽活跃时返回 nil。
    func proofreadSentence(
        sourceText: String,
        leftContext: String,
        requestID: String,
        withReply reply: @escaping (Data?) -> Void
    )

    /// 抢占式取消进行中的推理请求，避免高速打字引发队列堆积。
    func cancelRequest(requestID: String)

    /// 预热翻译模型槽（开启翻译模式时提前加载 HY-MT1.5，降低首次自动翻译等待）。
    func prewarmTranslation(withReply reply: @escaping (Bool) -> Void)

    /// 主动通知服务在空闲时卸载权重以释放内存。
    func unloadModels(withReply reply: @escaping (Bool) -> Void)

    /// 获取当前推理进程的内存与活跃模型状态（JSON 编码的 InferenceServiceStatus）。
    func fetchStatus(withReply reply: @escaping (Data?) -> Void)
}

/// XPC 翻译应答负载
public struct TranslationReplyPayload: Codable, Sendable {
    public let translatedText: String
    public let latencyMs: Double
    public let fromCache: Bool
    public let backendName: String
    public let physicalFootprintMB: Double

    public init(
        translatedText: String,
        latencyMs: Double,
        fromCache: Bool,
        backendName: String,
        physicalFootprintMB: Double
    ) {
        self.translatedText = translatedText
        self.latencyMs = latencyMs
        self.fromCache = fromCache
        self.backendName = backendName
        self.physicalFootprintMB = physicalFootprintMB
    }
}

/// XPC 整句校对应答负载
public struct ProofreadReplyPayload: Codable, Sendable {
    public let correctedText: String
    public let hasChanges: Bool
    public let latencyMs: Double
    public let fromCache: Bool
    public let backendName: String
    public let physicalFootprintMB: Double

    public init(
        correctedText: String,
        hasChanges: Bool,
        latencyMs: Double,
        fromCache: Bool,
        backendName: String,
        physicalFootprintMB: Double
    ) {
        self.correctedText = correctedText
        self.hasChanges = hasChanges
        self.latencyMs = latencyMs
        self.fromCache = fromCache
        self.backendName = backendName
        self.physicalFootprintMB = physicalFootprintMB
    }
}

public enum SmartPinyinIdentifiers {
    public static let appBundleID = "com.smartpinyin.inputmethod.SmartPinyin"
    public static let connectionName = "\(appBundleID)_Connection"
    public static let xpcServiceName = "com.smartpinyin.inputmethod.SmartPinyin.InferenceService"
    public static let appSupportFolderName = "SmartPinyin"
}
