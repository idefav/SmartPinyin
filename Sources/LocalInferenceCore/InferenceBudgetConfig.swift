import Foundation
import SharedIPC

/// 档位 C 内存预算配置（严格守住整套输入法 < 2GB 红线）
public struct InferenceBudgetConfig: Sendable {
    /// XPC 推理进程软内存上限（MB），留出约 200MB 给 IMK + librime
    public let memoryBudgetMB: Double
    /// 短上下文窗口长度（输入法仅需前文 + 当前句，512 足以覆盖，KV 仅 ~15MB）
    public let contextSize: Int32
    /// 批量大小
    public let batchSize: Int32
    /// Metal GPU 层卸载数（99 表示全量卸载至统一内存 Metal）
    public let gpuLayers: Int32
    /// 空闲自动卸载时间（秒），停止输入后释放权重使内存回落至 ~150MB
    public let idleUnloadSeconds: TimeInterval
    /// 日常轻量模型路径（Qwen3-0.6B-Q4_K_M 或 suzu 40M）
    public let lightModelPath: String
    /// 专职翻译模型路径（HY-MT1.5-1.8B-Q4_K_M / IQ4_XS）
    public let translationModelPath: String
    /// 当初始配置路径尚未存在时，是否在运行时动态重新探测默认模型目录（支持 Lite 安装包先装后下模型即刻生效）
    public let autoRediscoverMissingModels: Bool

    public init(
        memoryBudgetMB: Double = 1750.0,
        contextSize: Int32 = 512,
        batchSize: Int32 = 128,
        gpuLayers: Int32 = 99,
        idleUnloadSeconds: TimeInterval = 180,
        lightModelPath: String,
        translationModelPath: String,
        autoRediscoverMissingModels: Bool = false
    ) {
        self.memoryBudgetMB = memoryBudgetMB
        self.contextSize = contextSize
        self.batchSize = batchSize
        self.gpuLayers = gpuLayers
        self.idleUnloadSeconds = idleUnloadSeconds
        self.lightModelPath = lightModelPath
        self.translationModelPath = translationModelPath
        self.autoRediscoverMissingModels = autoRediscoverMissingModels
    }

    /// 自动探测默认模型路径（优先环境变量 -> 项目 Models 目录 -> Application Support -> Bundle -> 当前工作目录）
    /// 若所有目录暂未找到模型（例如轻量安装包尚未下载权重），固定回落到标准 Application Support/SmartPinyin/Models 目录，
    /// 绝不回落到只读的 XPC Bundle 内部路径，确保下载完成后无需重启即可生效。
    public static func defaultConfig(
        projectModelsDir: String? = nil,
        appSupportModelsDir: String? = nil,
        workingDirectory: String? = nil
    ) -> InferenceBudgetConfig {
        let fm = FileManager.default
        let appSupport = appSupportModelsDir
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("SmartPinyin/Models").path
            ?? ""
        let cwd = workingDirectory ?? fm.currentDirectoryPath
        let candidates = [
            ProcessInfo.processInfo.environment["SMARTPINYIN_MODELS_DIR"],
            projectModelsDir,
            appSupport,
            Bundle.main.resourceURL?.appendingPathComponent("Models").path,
            cwd.isEmpty ? nil : (cwd as NSString).appendingPathComponent("Models")
        ].compactMap { $0 }.filter { !$0.isEmpty }

        func locate(_ filenames: [String]) -> String {
            for dir in candidates {
                for name in filenames {
                    let full = (dir as NSString).appendingPathComponent(name)
                    if fm.fileExists(atPath: full) {
                        return full
                    }
                }
            }
            let fallbackBase = !appSupport.isEmpty ? appSupport : (candidates.first ?? "")
            return (fallbackBase as NSString).appendingPathComponent(filenames[0])
        }

        let prefs = SmartPinyinPreferencesStore.load()
        return InferenceBudgetConfig(
            idleUnloadSeconds: TimeInterval(prefs.idleUnloadSeconds),
            lightModelPath: locate(["Qwen3-0.6B-Q4_K_M.gguf", "Qwen3-0.6B-IQ4_XS.gguf", "suzu-40m.gguf"]),
            translationModelPath: locate(["HY-MT1.5-1.8B-Q4_K_M.gguf", "HY-MT1.5-1.8B.IQ4_XS.gguf"]),
            autoRediscoverMissingModels: true
        )
    }
}

/// 进程级物理内存采样（与 macOS 活动监视器 phys_footprint 一致）
public enum ProcessMemoryMonitor {
    public static func physicalFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024.0 * 1024.0)
    }

    public static func residentSizeMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024.0 * 1024.0)
    }
}

/// 线程安全轻量 LRU 缓存（用于预翻译缓存，命中即 0ms 上屏）
public final class TranslationLRUCache: @unchecked Sendable {
    private struct Entry {
        let value: String
        let timestamp: Date
    }

    private let capacity: Int
    private let lock = NSLock()
    private var storage: [String: Entry] = [:]
    private var order: [String] = []

    public init(capacity: Int = 256) {
        self.capacity = max(16, capacity)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    public func get(source: String, targetLang: String) -> String? {
        let key = "\(targetLang)::\(source)"
        lock.lock()
        defer { lock.unlock() }
        guard let entry = storage[key] else { return nil }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        return entry.value
    }

    public func set(source: String, targetLang: String, translation: String) {
        let key = "\(targetLang)::\(source)"
        lock.lock()
        defer { lock.unlock() }
        storage[key] = Entry(value: translation, timestamp: Date())
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.append(key)
        while order.count > capacity {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        order.removeAll()
    }
}

/// 线程安全轻量 L2 神经重排 LRU 缓存（回退改字/重复语境时 < 0.1ms 直接复用，仅缓存完整无截断结果）
public final class RerankLRUCache: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var storage: [String: [ScoredCandidate]] = [:]
    private var order: [String] = []

    public init(capacity: Int = 64) {
        self.capacity = max(16, capacity)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    private static func makeKey(contextPrefix: String, candidates: [String]) -> String {
        contextPrefix + "\0" + candidates.joined(separator: "\u{1F}")
    }

    public func get(contextPrefix: String, candidates: [String]) -> [ScoredCandidate]? {
        let key = Self.makeKey(contextPrefix: contextPrefix, candidates: candidates)
        lock.lock()
        defer { lock.unlock() }
        guard let value = storage[key] else { return nil }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        return value
    }

    public func set(contextPrefix: String, candidates: [String], scored: [ScoredCandidate]) {
        guard scored.count == candidates.count, !scored.isEmpty else { return }
        let key = Self.makeKey(contextPrefix: contextPrefix, candidates: candidates)
        lock.lock()
        defer { lock.unlock() }
        storage[key] = scored
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.append(key)
        while order.count > capacity {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        order.removeAll()
    }
}

/// 线程安全轻量 L2 联想续写 LRU 缓存（常见上文尾段命中 < 0.1ms 零 GPU 消耗）
public final class PredictionLRUCache: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var storage: [String: [String]] = [:]
    private var order: [String] = []

    public init(capacity: Int = 128) {
        self.capacity = max(16, capacity)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    private static func makeKey(contextTail: String, maxSuggestions: Int) -> String {
        "\(maxSuggestions)::\(contextTail)"
    }

    public func get(contextTail: String, maxSuggestions: Int) -> [String]? {
        let key = Self.makeKey(contextTail: contextTail, maxSuggestions: maxSuggestions)
        lock.lock()
        defer { lock.unlock() }
        guard let value = storage[key] else { return nil }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        return value
    }

    public func set(contextTail: String, maxSuggestions: Int, suggestions: [String]) {
        guard !suggestions.isEmpty else { return }
        let key = Self.makeKey(contextTail: contextTail, maxSuggestions: maxSuggestions)
        lock.lock()
        defer { lock.unlock() }
        storage[key] = suggestions
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.append(key)
        while order.count > capacity {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        order.removeAll()
    }
}
