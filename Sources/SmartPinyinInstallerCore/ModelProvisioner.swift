import Foundation
import SharedIPC

/// Tier-C 两个本地 GGUF 模型的元数据规格
public struct LocalModelSpec: Identifiable, Equatable, Sendable {
    public let id: String
    public let filename: String
    public let displayName: String
    public let roleDescription: String
    public let expectedSizeMB: Int
    public let minValidBytes: Int64
    public let downloadURLs: [URL]

    public init(
        id: String,
        filename: String,
        displayName: String,
        roleDescription: String,
        expectedSizeMB: Int,
        minValidBytes: Int64,
        downloadURLs: [URL]
    ) {
        self.id = id
        self.filename = filename
        self.displayName = displayName
        self.roleDescription = roleDescription
        self.expectedSizeMB = expectedSizeMB
        self.minValidBytes = minValidBytes
        self.downloadURLs = downloadURLs
    }

    public static let tierCModels: [LocalModelSpec] = [
        LocalModelSpec(
            id: "qwen3-0.6b",
            filename: "Qwen3-0.6B-Q4_K_M.gguf",
            displayName: "Qwen3-0.6B (4-bit)",
            roleDescription: "日常语境重排 + 联想词句（内存约 450 MB）",
            expectedSizeMB: 378,
            minValidBytes: 200 * 1024 * 1024,
            downloadURLs: [
                URL(string: "https://www.modelscope.cn/api/v1/models/unsloth/Qwen3-0.6B-GGUF/repo?Revision=master&FilePath=Qwen3-0.6B-Q4_K_M.gguf")!,
                URL(string: "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf")!
            ]
        ),
        LocalModelSpec(
            id: "hy-mt-1.8b",
            filename: "HY-MT1.5-1.8B-Q4_K_M.gguf",
            displayName: "HY-MT1.5-1.8B (4-bit)",
            roleDescription: "中→英/日/韩/法/德专职翻译（互斥懒加载）",
            expectedSizeMB: 1081,
            minValidBytes: 700 * 1024 * 1024,
            downloadURLs: [
                URL(string: "https://www.modelscope.cn/api/v1/models/Tencent-Hunyuan/HY-MT1.5-1.8B-GGUF/repo?Revision=master&FilePath=HY-MT1.5-1.8B-Q4_K_M.gguf")!,
                URL(string: "https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/resolve/main/HY-MT1.5-1.8B-Q4_K_M.gguf")!
            ]
        )
    ]
}

public enum ModelAvailability: Equatable, Sendable {
    case ready(path: URL, sizeBytes: Int64)
    case discoverable(sourceURL: URL, sizeBytes: Int64)
    case missing
}

public struct ModelInspectionItem: Identifiable, Equatable, Sendable {
    public var id: String { spec.id }
    public let spec: LocalModelSpec
    public let availability: ModelAvailability

    public init(spec: LocalModelSpec, availability: ModelAvailability) {
        self.spec = spec
        self.availability = availability
    }
}

public enum ModelProvisionError: LocalizedError {
    case invalidGGUFFile(String)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidGGUFFile(let detail): return "无效的 GGUF 模型文件：\(detail)"
        case .downloadFailed(let detail): return "模型下载失败：\(detail)"
        }
    }
}

/// 本地 GGUF 模型探测、校验、导入与在线下载管理器
public final class ModelProvisioner: @unchecked Sendable {
    public let targetModelsDirectory: URL
    private let extraSearchDirectories: [URL]

    public init(
        targetModelsDirectory: URL? = nil,
        extraSearchDirectories: [URL] = []
    ) {
        if let targetModelsDirectory {
            self.targetModelsDirectory = targetModelsDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.targetModelsDirectory = appSupport
                .appendingPathComponent(SmartPinyinIdentifiers.appSupportFolderName, isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
        }
        self.extraSearchDirectories = extraSearchDirectories
    }

    /// 校验文件是否具备合法的 GGUF 魔数头与最小文件体积
    public static func validateGGUFFile(at url: URL, minBytes: Int64) -> Int64? {
        let resolved = url.resolvingSymlinksInPath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              let size = attrs[.size] as? Int64,
              size >= minBytes,
              let fh = try? FileHandle(forReadingFrom: resolved)
        else {
            return nil
        }
        defer { try? fh.close() }
        guard let header = try? fh.read(upToCount: 4),
              header == Data("GGUF".utf8)
        else {
            return nil
        }
        return size
    }

    /// 扫描所有 Tier-C 模型状态（先查标准目标目录，再查安装包内嵌目录及额外搜索目录）
    public func inspectAll(specs: [LocalModelSpec] = LocalModelSpec.tierCModels) -> [ModelInspectionItem] {
        var searchDirs = extraSearchDirectories
        if let bundleModels = Bundle.main.resourceURL?.appendingPathComponent("Models", isDirectory: true) {
            searchDirs.append(bundleModels)
        }
        if let envDir = ProcessInfo.processInfo.environment["SMARTPINYIN_MODELS_DIR"], !envDir.isEmpty {
            searchDirs.append(URL(fileURLWithPath: envDir, isDirectory: true))
        }

        return specs.map { spec in
            let installedURL = targetModelsDirectory.appendingPathComponent(spec.filename)
            if let size = Self.validateGGUFFile(at: installedURL, minBytes: spec.minValidBytes) {
                return ModelInspectionItem(spec: spec, availability: .ready(path: installedURL, sizeBytes: size))
            }
            for dir in searchDirs {
                let candidate = dir.appendingPathComponent(spec.filename)
                if let size = Self.validateGGUFFile(at: candidate, minBytes: spec.minValidBytes) {
                    return ModelInspectionItem(spec: spec, availability: .discoverable(sourceURL: candidate, sizeBytes: size))
                }
            }
            return ModelInspectionItem(spec: spec, availability: .missing)
        }
    }

    /// 将用户选择的或发现的本地 GGUF 文件校验后导入至标准 Models 目录
    public func importModel(from sourceURL: URL, for spec: LocalModelSpec, preferSymlink: Bool = false) throws -> URL {
        guard Self.validateGGUFFile(at: sourceURL, minBytes: spec.minValidBytes) != nil else {
            throw ModelProvisionError.invalidGGUFFile("\(sourceURL.lastPathComponent) 不是有效的 GGUF 权重或文件不完整")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: targetModelsDirectory, withIntermediateDirectories: true)
        let destURL = targetModelsDirectory.appendingPathComponent(spec.filename)
        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }
        if preferSymlink {
            try fm.createSymbolicLink(at: destURL, withDestinationURL: sourceURL.resolvingSymlinksInPath())
        } else {
            try fm.copyItem(at: sourceURL.resolvingSymlinksInPath(), to: destURL)
        }
        return destURL
    }

    /// 在线下载模型并实时回调进度（0.0...1.0），自动在 ModelScope 与 HuggingFace 间容错回落
    public func downloadModel(
        _ spec: LocalModelSpec,
        onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: targetModelsDirectory, withIntermediateDirectories: true)
        let destURL = targetModelsDirectory.appendingPathComponent(spec.filename)
        let tempURL = targetModelsDirectory.appendingPathComponent(spec.filename + ".download")
        defer { try? fm.removeItem(at: tempURL) }

        var lastError: Error = ModelProvisionError.downloadFailed("无可用下载源")
        for url in spec.downloadURLs {
            do {
                let downloaded = try await performDownload(from: url, to: tempURL, onProgress: onProgress)
                guard Self.validateGGUFFile(at: downloaded, minBytes: spec.minValidBytes) != nil else {
                    throw ModelProvisionError.invalidGGUFFile("下载结果未通过 GGUF 文件头校验")
                }
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fm.moveItem(at: downloaded, to: destURL)
                return destURL
            } catch {
                lastError = error
            }
        }
        throw ModelProvisionError.downloadFailed(lastError.localizedDescription)
    }

    private func performDownload(
        from url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void
    ) async throws -> URL {
        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (localTmp, response) = try await session.download(from: url, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ModelProvisionError.downloadFailed("HTTP \(http.statusCode)")
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: localTmp, to: destination)
        return destination
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double, Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = totalBytesExpectedToWrite > 0
            ? min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            : 0.0
        onProgress(fraction, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
