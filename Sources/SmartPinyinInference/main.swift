import Foundation
import LocalInferenceCore
import SharedIPC

final class InferenceServiceHandler: NSObject, InferenceXPCProtocol {
    private let coordinator: LocalInferenceCoordinator

    init(coordinator: LocalInferenceCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func rerankCandidates(
        leftContext: String,
        pinyin: String,
        candidates: [String],
        requestID: String,
        timeoutMs: Int,
        withReply reply: @escaping ([String]?) -> Void
    ) {
        coordinator.rerankCandidates(
            leftContext: leftContext,
            pinyin: pinyin,
            candidates: candidates,
            requestID: requestID,
            timeoutMs: timeoutMs,
            completion: reply
        )
    }

    func rerankCandidatesScored(
        leftContext: String,
        pinyin: String,
        candidates: [String],
        requestID: String,
        timeoutMs: Int,
        withReply reply: @escaping (Data?) -> Void
    ) {
        coordinator.rerankCandidatesScored(
            leftContext: leftContext,
            pinyin: pinyin,
            candidates: candidates,
            requestID: requestID,
            timeoutMs: timeoutMs
        ) { scored in
            guard let scored, let data = try? JSONEncoder().encode(scored) else {
                reply(nil)
                return
            }
            reply(data)
        }
    }

    func predictContinuation(
        leftContext: String,
        maxSuggestions: Int,
        requestID: String,
        withReply reply: @escaping ([String]) -> Void
    ) {
        coordinator.predictContinuation(
            leftContext: leftContext,
            maxSuggestions: maxSuggestions,
            requestID: requestID,
            completion: reply
        )
    }

    func translateText(
        sourceText: String,
        leftContext: String,
        targetLanguageCode: String,
        requestID: String,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let target = TargetLanguage(rawValue: targetLanguageCode) ?? .english
        coordinator.translateText(
            sourceText: sourceText,
            leftContext: leftContext,
            target: target,
            requestID: requestID
        ) { payload in
            guard let payload, let encoded = try? JSONEncoder().encode(payload) else {
                reply(nil)
                return
            }
            reply(encoded)
        }
    }

    func proofreadSentence(
        sourceText: String,
        leftContext: String,
        requestID: String,
        withReply reply: @escaping (Data?) -> Void
    ) {
        coordinator.proofreadSentence(
            sourceText: sourceText,
            leftContext: leftContext,
            requestID: requestID
        ) { payload in
            guard let payload, let encoded = try? JSONEncoder().encode(payload) else {
                reply(nil)
                return
            }
            reply(encoded)
        }
    }

    func cancelRequest(requestID: String) {
        coordinator.cancel(requestID: requestID)
    }

    func prewarmTranslation(withReply reply: @escaping (Bool) -> Void) {
        coordinator.prewarmSlot(.translation) { ok in
            reply(ok)
        }
    }

    func unloadModels(withReply reply: @escaping (Bool) -> Void) {
        coordinator.unloadNow()
        reply(true)
    }

    func fetchStatus(withReply reply: @escaping (Data?) -> Void) {
        let status = coordinator.currentStatus()
        reply(try? JSONEncoder().encode(status))
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let handler = InferenceServiceHandler(
        coordinator: LocalInferenceCoordinator(config: .defaultConfig())
    )

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: InferenceXPCProtocol.self)
        newConnection.exportedObject = handler
        newConnection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
