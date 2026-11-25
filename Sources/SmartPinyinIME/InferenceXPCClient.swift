import Foundation
import SharedIPC

/// IMK 宿主侧的 XPC 客户端：
/// - 自动重连：若 XPC 推理进程因内存压力崩溃或被重启，主进程无感降级回纯 L1 离线拼音，下一次请求自动拉起
/// - Latest-Wins 抢占：新请求自动取消上一个同类型请求
@MainActor
public final class InferenceXPCClient {
    public static let shared = InferenceXPCClient()

    private var connection: NSXPCConnection?
    private var activeRerankRequestID: String?
    private var activePreviewTranslateRequestID: String?
    private var activeCommitTranslateRequestID: String?
    private var activePredictRequestID: String?
    private var activeProofreadRequestID: String?
    private var activeCommitProofreadRequestID: String?

    private init() {}

    private func proxy(onError: @escaping @Sendable () -> Void) -> InferenceXPCProtocol? {
        if connection == nil {
            let conn = NSXPCConnection(serviceName: SmartPinyinIdentifiers.xpcServiceName)
            conn.remoteObjectInterface = NSXPCInterface(with: InferenceXPCProtocol.self)
            conn.interruptionHandler = { [weak self] in
                Task { @MainActor in
                    self?.connection = nil
                }
            }
            conn.invalidationHandler = { [weak self] in
                Task { @MainActor in
                    self?.connection = nil
                }
            }
            conn.resume()
            self.connection = conn
        }
        return connection?.remoteObjectProxyWithErrorHandler { _ in
            onError()
        } as? InferenceXPCProtocol
    }

    public func cancelAll(includeCommit: Bool = false) {
        guard let proxy = connection?.remoteObjectProxy as? InferenceXPCProtocol else {
            activeRerankRequestID = nil
            activePreviewTranslateRequestID = nil
            if includeCommit {
                activeCommitTranslateRequestID = nil
                activeCommitProofreadRequestID = nil
            }
            activePredictRequestID = nil
            activeProofreadRequestID = nil
            return
        }
        var ids = [activeRerankRequestID, activePreviewTranslateRequestID, activePredictRequestID, activeProofreadRequestID]
        if includeCommit {
            ids.append(activeCommitTranslateRequestID)
            ids.append(activeCommitProofreadRequestID)
        }
        for id in ids.compactMap({ $0 }) {
            proxy.cancelRequest(requestID: id)
        }
        activeRerankRequestID = nil
        activePreviewTranslateRequestID = nil
        if includeCommit {
            activeCommitTranslateRequestID = nil
            activeCommitProofreadRequestID = nil
        }
        activePredictRequestID = nil
        activeProofreadRequestID = nil
    }

    public func rerank(
        leftContext: String,
        pinyin: String,
        candidates: [String],
        timeoutMs: Int = 40
    ) async -> [String]? {
        if let prev = activeRerankRequestID {
            (connection?.remoteObjectProxy as? InferenceXPCProtocol)?.cancelRequest(requestID: prev)
        }
        let reqID = UUID().uuidString
        activeRerankRequestID = reqID

        return await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            guard let p = proxy(onError: {
                if resumed.trySet() { continuation.resume(returning: nil) }
            }) else {
                if resumed.trySet() { continuation.resume(returning: nil) }
                return
            }
            p.rerankCandidates(
                leftContext: leftContext,
                pinyin: pinyin,
                candidates: candidates,
                requestID: reqID,
                timeoutMs: timeoutMs
            ) { result in
                if resumed.trySet() {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    public func rerankScored(
        leftContext: String,
        pinyin: String,
        candidates: [String],
        timeoutMs: Int = 85
    ) async -> [ScoredCandidate]? {
        if let prev = activeRerankRequestID {
            (connection?.remoteObjectProxy as? InferenceXPCProtocol)?.cancelRequest(requestID: prev)
        }
        let reqID = UUID().uuidString
        activeRerankRequestID = reqID

        return await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            guard let p = proxy(onError: {
                if resumed.trySet() { continuation.resume(returning: nil) }
            }) else {
                if resumed.trySet() { continuation.resume(returning: nil) }
                return
            }
            p.rerankCandidatesScored(
                leftContext: leftContext,
                pinyin: pinyin,
                candidates: candidates,
                requestID: reqID,
                timeoutMs: timeoutMs
            ) { data in
                guard resumed.trySet() else { return }
                guard let data,
                      let decoded = try? JSONDecoder().decode([ScoredCandidate].self, from: data)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: decoded)
            }
        }
    }

    public func predictContinuation(
        leftContext: String,
        maxSuggestions: Int = 3
    ) async -> [String] {
        if let prev = activePredictRequestID {
            (connection?.remoteObjectProxy as? InferenceXPCProtocol)?.cancelRequest(requestID: prev)
        }
        let reqID = UUID().uuidString
        activePredictRequestID = reqID

        return await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            guard let p = proxy(onError: {
                if resumed.trySet() { continuation.resume(returning: []) }
            }) else {
                if resumed.trySet() { continuation.resume(returning: []) }
                return
            }
            p.predictContinuation(
                leftContext: leftContext,
                maxSuggestions: maxSuggestions,
                requestID: reqID
            ) { result in
                if resumed.trySet() {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    public func translate(
        sourceText: String,
        leftContext: String,
        target: TargetLanguage,
        isCommitRequest: Bool = false
    ) async -> TranslationReplyPayload? {
        if let prevPreview = activePreviewTranslateRequestID {
            (connection?.remoteObjectProxy as? InferenceXPCProtocol)?.cancelRequest(requestID: prevPreview)
            activePreviewTranslateRequestID = nil
        }
        if isCommitRequest, let prevCommit = activeCommitTranslateRequestID {
            (connection?.remoteObjectProxy as? InferenceXPCProtocol)?.cancelRequest(requestID: prevCommit)
            activeCommitTranslateRequestID = nil
        }
        let reqID = UUID().uuidString
        if isCommitRequest {
            activeCommitTranslateRequestID = reqID
        } else {
            activePreviewTranslateRequestID = reqID
        }

        return await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            let timeoutSecs: Double = isCommitRequest ? 3.5 : 5.0
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSecs) {
                if resumed.trySet() {
                    continuation.resume(returning: nil)
                }
            }
            guard let p = proxy(onError: {
                if resumed.trySet() { continuation.resume(returning: nil) }
            }) else {
                if resumed.trySet() { continuation.resume(returning: nil) }
                return
            }
            p.translateText(
                sourceText: sourceText,
                leftContext: leftContext,
                targetLanguageCode: target.rawValue,
                requestID: reqID
            ) { data in
                guard resumed.trySet() else { return }
                guard let data,
                      let decoded = try? JSONDecoder().decode(TranslationReplyPayload.self, from: data)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: decoded)
            }
        }
    }

    public func proofreadSentence(
        sourceText: String,
        leftContext: String,
        timeoutSeconds: Double = 2.2,
        isCommitRequest: Bool = false
    ) async -> ProofreadReplyPayload? {
        if let prev = activeProofreadRequestID {
            (connection?.remoteObjectProxy as? InferenceXPCProtocol)?.cancelRequest(requestID: prev)
            activeProofreadRequestID = nil
        }
        if isCommitRequest, let prevCommit = activeCommitProofreadRequestID {
            (connection?.remoteObjectProxy as? InferenceXPCProtocol)?.cancelRequest(requestID: prevCommit)
            activeCommitProofreadRequestID = nil
        }
        let reqID = UUID().uuidString
        if isCommitRequest {
            activeCommitProofreadRequestID = reqID
        } else {
            activeProofreadRequestID = reqID
        }

        return await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0.15, timeoutSeconds)) {
                if resumed.trySet() {
                    continuation.resume(returning: nil)
                }
            }
            guard let p = proxy(onError: {
                if resumed.trySet() { continuation.resume(returning: nil) }
            }) else {
                if resumed.trySet() { continuation.resume(returning: nil) }
                return
            }
            p.proofreadSentence(
                sourceText: sourceText,
                leftContext: leftContext,
                requestID: reqID
            ) { data in
                guard resumed.trySet() else { return }
                guard let data,
                      let decoded = try? JSONDecoder().decode(ProofreadReplyPayload.self, from: data)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: decoded)
            }
        }
    }

    public func prewarmTranslation() {
        guard let p = proxy(onError: {}) else { return }
        p.prewarmTranslation { _ in }
    }

    public func fetchStatus() async -> InferenceServiceStatus? {
        await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            guard let p = proxy(onError: {
                if resumed.trySet() { continuation.resume(returning: nil) }
            }) else {
                if resumed.trySet() { continuation.resume(returning: nil) }
                return
            }
            p.fetchStatus { data in
                guard resumed.trySet() else { return }
                guard let data,
                      let status = try? JSONDecoder().decode(InferenceServiceStatus.self, from: data)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: status)
            }
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func trySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
