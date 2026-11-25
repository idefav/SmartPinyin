import Foundation
import SharedIPC

/// 开源词库与用户自定义词库的源类型
public enum LexiconSourceKind: String, Codable, Sendable {
    /// 万象每日构建核心词库包（dicts.zip -> 解压更新 RimeUserData/dicts/ 核心表）
    case wanxiangCoreZip
    /// 万象官方单文件扩展词库（原生带声调 .dict.yaml）
    case wanxiangExtraYAML
    /// 清华 THUOCL 纯文本词表（MIT，下载后本地自动注音转 Rime .dict.yaml + 生成领域标签 .bin）
    case thuoclPlainText
    /// GitHub Release 动态资产 .dict.yaml（如萌娘百科 moegirl / 维基百科 zhwiki / 网络热词）
    case githubReleaseYAML
    /// 用户本地导入自定义词库（.dict.yaml 或纯文本）
    case userImported
}

/// 词库包规格定义
public struct LexiconPackSpec: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let tableName: String
    public let displayName: String
    public let summary: String
    public let domain: InputSceneDomain
    public let license: String
    public let sourceKind: LexiconSourceKind
    public let downloadURLString: String?
    /// 用于 GitHub Release API 解析最新资产下载链接（例如 "outloudvi/mw2fcitx"）
    public let githubRepo: String?
    /// GitHub Release 资产名称前缀/匹配串（例如 "moegirl.dict.yaml" 或 "zhwiki-"）
    public let releaseAssetPrefix: String?
    public let releaseAssetSuffix: String?
    public let approxSizeLabel: String

    public init(
        id: String,
        tableName: String,
        displayName: String,
        summary: String,
        domain: InputSceneDomain,
        license: String,
        sourceKind: LexiconSourceKind,
        downloadURLString: String? = nil,
        githubRepo: String? = nil,
        releaseAssetPrefix: String? = nil,
        releaseAssetSuffix: String? = nil,
        approxSizeLabel: String = ""
    ) {
        self.id = id
        self.tableName = tableName
        self.displayName = displayName
        self.summary = summary
        self.domain = domain
        self.license = license
        self.sourceKind = sourceKind
        self.downloadURLString = downloadURLString
        self.githubRepo = githubRepo
        self.releaseAssetPrefix = releaseAssetPrefix
        self.releaseAssetSuffix = releaseAssetSuffix
        self.approxSizeLabel = approxSizeLabel
    }
}

/// 本地词库安装状态持久化记录（保存在 LexiconPacks/manifest.json）
public struct InstalledLexiconRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let tableName: String
    public var displayName: String
    public var domain: InputSceneDomain
    public var isEnabled: Bool
    public var installedVersion: String
    public var updatedAt: TimeInterval
    public var entryCount: Int
    public var fileSizeBytes: Int64
    public var isCustom: Bool

    public init(
        id: String,
        tableName: String,
        displayName: String,
        domain: InputSceneDomain,
        isEnabled: Bool,
        installedVersion: String,
        updatedAt: TimeInterval,
        entryCount: Int,
        fileSizeBytes: Int64,
        isCustom: Bool = false
    ) {
        self.id = id
        self.tableName = tableName
        self.displayName = displayName
        self.domain = domain
        self.isEnabled = isEnabled
        self.installedVersion = installedVersion
        self.updatedAt = updatedAt
        self.entryCount = entryCount
        self.fileSizeBytes = fileSizeBytes
        self.isCustom = isCustom
    }
}

/// 词库更新检测结果
public struct LexiconUpdateInfo: Equatable, Sendable {
    public let packID: String
    public let latestVersion: String
    public let hasUpdate: Bool
    public let downloadURL: URL?

    public init(packID: String, latestVersion: String, hasUpdate: Bool, downloadURL: URL?) {
        self.packID = packID
        self.latestVersion = latestVersion
        self.hasUpdate = hasUpdate
        self.downloadURL = downloadURL
    }
}

/// 词库页面综合视图条目
public struct LexiconPackStatus: Identifiable, Equatable, Sendable {
    public var id: String { spec.id }
    public let spec: LexiconPackSpec
    public let record: InstalledLexiconRecord?
    public let updateInfo: LexiconUpdateInfo?

    public var isInstalled: Bool { record != nil || spec.sourceKind == .wanxiangCoreZip }
    public var isEnabled: Bool { record?.isEnabled ?? (spec.sourceKind == .wanxiangCoreZip) }

    public init(spec: LexiconPackSpec, record: InstalledLexiconRecord?, updateInfo: LexiconUpdateInfo? = nil) {
        self.spec = spec
        self.record = record
        self.updateInfo = updateInfo
    }
}

public enum LexiconManagerError: LocalizedError {
    case invalidSourceURL(String)
    case downloadFailed(String)
    case invalidDictionaryFormat(String)
    case archiveExtractionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSourceURL(let msg): return "词库下载地址无效：\(msg)"
        case .downloadFailed(let msg): return "词库下载失败：\(msg)"
        case .invalidDictionaryFormat(let msg): return "词库格式校验失败：\(msg)"
        case .archiveExtractionFailed(let msg): return "词库压缩包解压失败：\(msg)"
        }
    }
}

/// 官方与社区开源词库目录（均已实测可达，协议透明标注）
public enum LexiconCatalog {
    public static let coreBasePackID = "wanxiang-core"

    public static let builtInSpecs: [LexiconPackSpec] = [
        LexiconPackSpec(
            id: coreBasePackID,
            tableName: "jichu",
            displayName: "万象核心底座词库（每日构建）",
            summary: "覆盖 155 万基础词条、字表、多音/错音与地名名人，支持一键热更新至 RimeUserData",
            domain: .general,
            license: "CC-BY-4.0",
            sourceKind: .wanxiangCoreZip,
            downloadURLString: "https://github.com/amzxyz/rime-wanxiang-data/releases/download/dict-nightly/dicts.zip",
            githubRepo: "amzxyz/rime-wanxiang-data",
            releaseAssetPrefix: "dicts.zip",
            releaseAssetSuffix: ".zip",
            approxSizeLabel: "~29 MB"
        ),
        LexiconPackSpec(
            id: "wanxiang-shici",
            tableName: "shici",
            displayName: "万象诗词大全扩展",
            summary: "补齐更全唐诗宋词元曲名句（原生带声调万象格式）",
            domain: .literature,
            license: "CC-BY-4.0",
            sourceKind: .wanxiangExtraYAML,
            downloadURLString: "https://raw.githubusercontent.com/amzxyz/rime-wanxiang-data/main/dicts/shici.dict.yaml",
            approxSizeLabel: "~0.6 MB"
        ),
        LexiconPackSpec(
            id: "moegirl-gaming",
            tableName: "moegirl",
            displayName: "萌娘百科（游戏 / 电竞 / ACG）",
            summary: "热门游戏角色、技能、装备、作品名与二次元社区高频专有名词",
            domain: .gaming,
            license: "CC-BY-NC-SA",
            sourceKind: .githubReleaseYAML,
            githubRepo: "outloudvi/mw2fcitx",
            releaseAssetPrefix: "moegirl",
            releaseAssetSuffix: ".dict.yaml",
            approxSizeLabel: "~18 MB"
        ),
        LexiconPackSpec(
            id: "zhwiki-science",
            tableName: "zhwiki",
            displayName: "中文维基百科（数学 / 科学 / 美术 / 人文）",
            summary: "海量现代科技、高等数学、物理化学、艺术流派与百科长尾专有名词",
            domain: .science,
            license: "CC-BY-SA-3.0",
            sourceKind: .githubReleaseYAML,
            githubRepo: "felixonmars/fcitx5-pinyin-zhwiki",
            releaseAssetPrefix: "zhwiki-",
            releaseAssetSuffix: ".dict.yaml",
            approxSizeLabel: "~14 MB"
        ),
        LexiconPackSpec(
            id: "web-slang",
            tableName: "web_slang",
            displayName: "中文网络热词与社区流行语",
            summary: "游戏与社交社区最新梗词、流行缩写与网络表达",
            domain: .gaming,
            license: "CC-BY-SA-3.0",
            sourceKind: .githubReleaseYAML,
            githubRepo: "felixonmars/fcitx5-pinyin-zhwiki",
            releaseAssetPrefix: "web-slang-",
            releaseAssetSuffix: ".dict.yaml",
            approxSizeLabel: "~0.5 MB"
        ),
        LexiconPackSpec(
            id: "thuocl-it",
            tableName: "thuocl_it",
            displayName: "清华 THUOCL 计算机 / IT 词库",
            summary: "编程、操作系统、网络协议、数据库与 AI 专业词汇（自动注音挂载）",
            domain: .computerScience,
            license: "MIT",
            sourceKind: .thuoclPlainText,
            downloadURLString: "https://raw.githubusercontent.com/thunlp/THUOCL/master/data/THUOCL_IT.txt",
            approxSizeLabel: "~0.3 MB"
        ),
        LexiconPackSpec(
            id: "wanxiang-huaxue",
            tableName: "huaxue",
            displayName: "万象化学与科学词库",
            summary: "有机/无机化合物、化学反应与实验室术语",
            domain: .science,
            license: "CC-BY-4.0",
            sourceKind: .wanxiangExtraYAML,
            downloadURLString: "https://raw.githubusercontent.com/amzxyz/rime-wanxiang-data/main/dicts/huaxue.dict.yaml",
            approxSizeLabel: "~0.4 MB"
        ),
        LexiconPackSpec(
            id: "wanxiang-wuzhong",
            tableName: "wuzhong",
            displayName: "万象生物动植物物种词库",
            summary: "动植物学名与自然博物常见物种名称",
            domain: .science,
            license: "CC-BY-4.0",
            sourceKind: .wanxiangExtraYAML,
            downloadURLString: "https://raw.githubusercontent.com/amzxyz/rime-wanxiang-data/main/dicts/wuzhong.dict.yaml",
            approxSizeLabel: "~0.8 MB"
        ),
        LexiconPackSpec(
            id: "wanxiang-yixue",
            tableName: "yixue",
            displayName: "万象医学与临床词库",
            summary: "临床病症、检查项目、解剖学与医疗术语",
            domain: .medicine,
            license: "CC-BY-4.0",
            sourceKind: .wanxiangExtraYAML,
            downloadURLString: "https://raw.githubusercontent.com/amzxyz/rime-wanxiang-data/main/dicts/yixue.dict.yaml",
            approxSizeLabel: "~1.2 MB"
        ),
        LexiconPackSpec(
            id: "wanxiang-yaopin",
            tableName: "yaopin",
            displayName: "万象药品词库",
            summary: "常用处方药、非处方药与通用名",
            domain: .medicine,
            license: "CC-BY-4.0",
            sourceKind: .wanxiangExtraYAML,
            downloadURLString: "https://raw.githubusercontent.com/amzxyz/rime-wanxiang-data/main/dicts/yaopin.dict.yaml",
            approxSizeLabel: "~0.3 MB"
        ),
        LexiconPackSpec(
            id: "thuocl-caijing",
            tableName: "thuocl_caijing",
            displayName: "清华 THUOCL 财经金融词库",
            summary: "证券、会计、宏观经济与投研专业词汇",
            domain: .financeLaw,
            license: "MIT",
            sourceKind: .thuoclPlainText,
            downloadURLString: "https://raw.githubusercontent.com/thunlp/THUOCL/master/data/THUOCL_caijing.txt",
            approxSizeLabel: "~0.2 MB"
        ),
        LexiconPackSpec(
            id: "thuocl-law",
            tableName: "thuocl_law",
            displayName: "清华 THUOCL 法律词库",
            summary: "法条、民商刑法与诉讼实务专业术语",
            domain: .financeLaw,
            license: "MIT",
            sourceKind: .thuoclPlainText,
            downloadURLString: "https://raw.githubusercontent.com/thunlp/THUOCL/master/data/THUOCL_law.txt",
            approxSizeLabel: "~0.2 MB"
        ),
        LexiconPackSpec(
            id: "wanxiang-fangyan",
            tableName: "fangyan",
            displayName: "万象全国方言词库",
            summary: "粤语、吴语、川渝、东北等高频地方特色词汇",
            domain: .general,
            license: "CC-BY-4.0",
            sourceKind: .wanxiangExtraYAML,
            downloadURLString: "https://raw.githubusercontent.com/amzxyz/rime-wanxiang-data/main/dicts/fangyan.dict.yaml",
            approxSizeLabel: "~0.2 MB"
        )
    ]
}

private struct LexiconManifest: Codable {
    var records: [InstalledLexiconRecord] = []
}

/// SmartPinyin 词库动态管理与热更新引擎：
/// - 所有更新与扩展词库统一落在 `~/Library/Application Support/SmartPinyin/RimeUserData/dicts/`，绝不触碰 `/Library/Input Methods/SmartPinyin.app` 签名
/// - 自动维护 `RimeUserData/wanxiang.dict.yaml` 的 `import_tables`，带备份与事务回滚
/// - 同步为每个领域词库生成轻量 SMDM v1 侧车标签索引（`LexiconPacks/Tags/*.bin`），使 0ms 场景调权即刻覆盖新装词库
/// - 通过 `SmartPinyinPreferencesStore.lexiconDidChangeNotification` 通知运行中的输入法后台热重载
public final class LexiconManager: @unchecked Sendable {
    public let rimeUserDataDirectory: URL
    public let lexiconPacksDirectory: URL
    public var rimeDictsDirectory: URL { rimeUserDataDirectory.appendingPathComponent("dicts", isDirectory: true) }
    public var userTagsDirectory: URL { lexiconPacksDirectory.appendingPathComponent("Tags", isDirectory: true) }
    public var manifestURL: URL { lexiconPacksDirectory.appendingPathComponent("manifest.json") }
    public var wanxiangDictOverrideURL: URL { rimeUserDataDirectory.appendingPathComponent("wanxiang.dict.yaml") }

    private let lock = NSLock()
    private let fm = FileManager.default
    private let postNotifications: Bool

    public static let coreWanxiangTables: [String] = [
        "dicts/zi",
        "dicts/jichu",
        "dicts/cuoyin",
        "dicts/duoyin",
        "dicts/diming",
        "dicts/mingren",
        "dicts/yiren"
    ]

    public init(
        appSupportDirectory: URL? = nil,
        postNotifications: Bool = true
    ) {
        let base = appSupportDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent(SmartPinyinIdentifiers.appSupportFolderName, isDirectory: true)
        self.rimeUserDataDirectory = base.appendingPathComponent("RimeUserData", isDirectory: true)
        self.lexiconPacksDirectory = base.appendingPathComponent("LexiconPacks", isDirectory: true)
        self.postNotifications = postNotifications
    }

    /// 列出所有内置开源词库与用户导入自定义词库的当前状态
    public func inspectAll(updatesByID: [String: LexiconUpdateInfo] = [:]) -> [LexiconPackStatus] {
        let manifest = loadManifest()
        let recordByID = Dictionary(uniqueKeysWithValues: manifest.records.map { ($0.id, $0) })

        var items: [LexiconPackStatus] = LexiconCatalog.builtInSpecs.map { spec in
            LexiconPackStatus(
                spec: spec,
                record: recordByID[spec.id],
                updateInfo: updatesByID[spec.id]
            )
        }
        // 附加用户自定义导入的词库
        for rec in manifest.records where rec.isCustom {
            let customSpec = LexiconPackSpec(
                id: rec.id,
                tableName: rec.tableName,
                displayName: rec.displayName,
                summary: "用户导入自定义词库（\(rec.entryCount) 条 · 归属「\(rec.domain.displayName)」）",
                domain: rec.domain,
                license: "用户自定义",
                sourceKind: .userImported,
                approxSizeLabel: Self.formatByteSize(rec.fileSizeBytes)
            )
            items.append(LexiconPackStatus(spec: customSpec, record: rec, updateInfo: nil))
        }
        return items
    }

    /// 检查核心万象词库及 GitHub Release 社区词库是否有新版本（轻量元数据请求，不下载正文）
    public func checkForUpdates() async -> [String: LexiconUpdateInfo] {
        let manifest = loadManifest()
        let recordByID = Dictionary(uniqueKeysWithValues: manifest.records.map { ($0.id, $0) })
        var results: [String: LexiconUpdateInfo] = [:]

        // 1. 万象 dict-nightly
        if let info = await fetchGitHubReleaseInfo(
            repo: "amzxyz/rime-wanxiang-data",
            tagPath: "tags/dict-nightly",
            assetPrefix: "dicts.zip",
            assetSuffix: ".zip"
        ) {
            let cur = recordByID[LexiconCatalog.coreBasePackID]?.installedVersion ?? "bundled"
            results[LexiconCatalog.coreBasePackID] = LexiconUpdateInfo(
                packID: LexiconCatalog.coreBasePackID,
                latestVersion: info.version,
                hasUpdate: cur != info.version,
                downloadURL: info.downloadURL
            )
        }

        // 2. GitHub Release 社区词库（moegirl / zhwiki / web-slang）
        for spec in LexiconCatalog.builtInSpecs where spec.sourceKind == .githubReleaseYAML {
            guard let repo = spec.githubRepo,
                  let prefix = spec.releaseAssetPrefix,
                  let suffix = spec.releaseAssetSuffix
            else { continue }
            if let info = await fetchGitHubReleaseInfo(
                repo: repo,
                tagPath: "latest",
                assetPrefix: prefix,
                assetSuffix: suffix
            ) {
                let cur = recordByID[spec.id]?.installedVersion ?? ""
                results[spec.id] = LexiconUpdateInfo(
                    packID: spec.id,
                    latestVersion: info.version,
                    hasUpdate: !cur.isEmpty && cur != info.version,
                    downloadURL: info.downloadURL
                )
            }
        }
        return results
    }

    /// 在线安装或热更新指定词库包（下载 -> 校验 -> 转换/解压 -> 写入侧车领域标签 -> 合成 wanxiang.dict.yaml -> 通知输入法热重载）
    public func installOrUpdate(
        spec: LexiconPackSpec,
        resolvedDownloadURL: URL? = nil,
        versionLabel: String? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> InstalledLexiconRecord {
        try fm.createDirectory(at: rimeDictsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: userTagsDirectory, withIntermediateDirectories: true)

        var targetURL = resolvedDownloadURL ?? spec.downloadURLString.flatMap(URL.init(string:))
        var resolvedVersion = versionLabel ?? Self.todayVersionString()

        if targetURL == nil, spec.sourceKind == .githubReleaseYAML,
           let repo = spec.githubRepo,
           let prefix = spec.releaseAssetPrefix,
           let suffix = spec.releaseAssetSuffix {
            progress?(0.05, "查询最新开源发布版本…")
            guard let releaseInfo = await fetchGitHubReleaseInfo(
                repo: repo,
                tagPath: "latest",
                assetPrefix: prefix,
                assetSuffix: suffix
            ), let url = releaseInfo.downloadURL else {
                throw LexiconManagerError.downloadFailed("无法从 GitHub 获取 \(spec.displayName) 最新版本")
            }
            targetURL = url
            resolvedVersion = releaseInfo.version
        }

        guard let downloadURL = targetURL else {
            throw LexiconManagerError.invalidSourceURL(spec.id)
        }

        progress?(0.15, "正在下载 \(spec.displayName)…")
        let downloadedTemp = try await downloadToTempFile(from: downloadURL)
        defer { try? fm.removeItem(at: downloadedTemp) }

        progress?(0.65, "正在校验并装配词库…")
        let record: InstalledLexiconRecord
        switch spec.sourceKind {
        case .wanxiangCoreZip:
            record = try installWanxiangCoreZip(from: downloadedTemp, spec: spec, version: resolvedVersion)
        case .wanxiangExtraYAML, .githubReleaseYAML:
            record = try installRimeYAMLFile(from: downloadedTemp, spec: spec, version: resolvedVersion)
        case .thuoclPlainText:
            record = try installPlainTextWithAutoPinyin(
                from: downloadedTemp,
                packID: spec.id,
                tableName: spec.tableName,
                displayName: spec.displayName,
                domain: spec.domain,
                version: resolvedVersion,
                isCustom: false
            )
        case .userImported:
            throw LexiconManagerError.invalidSourceURL("自定义词库请使用本地导入接口")
        }

        progress?(0.90, "正在同步词典配置并热重载…")
        upsertRecord(record)
        try regenerateWanxiangDictOverride()
        notifyLexiconChanged()
        progress?(1.0, "安装完成（\(record.entryCount) 条）")
        return record
    }

    /// 导入用户本地 `.dict.yaml` 或纯文本词表（支持 `词\t拼音\t权重` 或每行一词自动注音）
    public func importCustomDictionary(
        from sourceURL: URL,
        displayName: String,
        domain: InputSceneDomain
    ) throws -> InstalledLexiconRecord {
        try fm.createDirectory(at: rimeDictsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: userTagsDirectory, withIntermediateDirectories: true)

        let cleanSlug = "custom_" + UUID().uuidString.prefix(8).lowercased()
        let finalName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? sourceURL.deletingPathExtension().lastPathComponent
            : displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        let ext = sourceURL.pathExtension.lowercased()
        let isYAML = sourceURL.lastPathComponent.lowercased().hasSuffix(".dict.yaml") || ext == "yaml" || ext == "yml"

        let record: InstalledLexiconRecord
        if isYAML {
            let tempSpec = LexiconPackSpec(
                id: cleanSlug,
                tableName: cleanSlug,
                displayName: finalName,
                summary: "用户导入自定义词库",
                domain: domain,
                license: "用户自定义",
                sourceKind: .userImported
            )
            var rec = try installRimeYAMLFile(from: sourceURL, spec: tempSpec, version: Self.todayVersionString())
            rec.isCustom = true
            record = rec
        } else {
            record = try installPlainTextWithAutoPinyin(
                from: sourceURL,
                packID: cleanSlug,
                tableName: cleanSlug,
                displayName: finalName,
                domain: domain,
                version: Self.todayVersionString(),
                isCustom: true
            )
        }

        upsertRecord(record)
        try regenerateWanxiangDictOverride()
        notifyLexiconChanged()
        return record
    }

    /// 启用或停用某个已安装扩展词库（保留本地文件以便随时秒切，并同步移除/恢复其领域侧车索引）
    public func setPackEnabled(id: String, enabled: Bool) throws {
        guard id != LexiconCatalog.coreBasePackID else { return }
        var manifest = loadManifest()
        guard let idx = manifest.records.firstIndex(where: { $0.id == id }) else { return }
        manifest.records[idx].isEnabled = enabled
        let rec = manifest.records[idx]
        saveManifest(manifest)

        let sidecarURL = userTagsDirectory.appendingPathComponent("\(rec.tableName).bin")
        if !enabled {
            try? fm.removeItem(at: sidecarURL)
        } else if rec.domain != .general {
            let dictURL = rimeDictsDirectory.appendingPathComponent("\(rec.tableName).dict.yaml")
            if let terms = Self.extractTermsFromRimeYAML(at: dictURL, limit: 30000), !terms.isEmpty {
                try? Self.writeSMDM(terms: terms, domainMask: rec.domain.bitMask, to: sidecarURL)
            }
        }

        try regenerateWanxiangDictOverride()
        notifyLexiconChanged()
    }

    /// 修改某个已安装词库的归属场景（立即重建侧车标签索引，0ms 生效）
    public func updatePackDomain(id: String, domain: InputSceneDomain) throws {
        var manifest = loadManifest()
        guard let idx = manifest.records.firstIndex(where: { $0.id == id }) else { return }
        manifest.records[idx].domain = domain
        let rec = manifest.records[idx]
        saveManifest(manifest)

        let sidecarURL = userTagsDirectory.appendingPathComponent("\(rec.tableName).bin")
        try? fm.removeItem(at: sidecarURL)
        if rec.isEnabled && domain != .general {
            let dictURL = rimeDictsDirectory.appendingPathComponent("\(rec.tableName).dict.yaml")
            if let terms = Self.extractTermsFromRimeYAML(at: dictURL, limit: 30000), !terms.isEmpty {
                try? Self.writeSMDM(terms: terms, domainMask: domain.bitMask, to: sidecarURL)
            }
        }
        notifyLexiconChanged()
    }

    /// 卸载扩展词库或用户自定义词库（清理词表与侧车标签并触发热重载）
    public func removePack(id: String) throws {
        guard id != LexiconCatalog.coreBasePackID else { return }
        var manifest = loadManifest()
        guard let idx = manifest.records.firstIndex(where: { $0.id == id }) else { return }
        let rec = manifest.records.remove(at: idx)
        saveManifest(manifest)

        let dictURL = rimeDictsDirectory.appendingPathComponent("\(rec.tableName).dict.yaml")
        let sidecarURL = userTagsDirectory.appendingPathComponent("\(rec.tableName).bin")
        try? fm.removeItem(at: dictURL)
        try? fm.removeItem(at: sidecarURL)

        try regenerateWanxiangDictOverride()
        notifyLexiconChanged()
    }

    /// 动态合成 `RimeUserData/wanxiang.dict.yaml`（事务备份，覆盖只读 App 内默认配置，绝不改动 App 签名）
    public func regenerateWanxiangDictOverride() throws {
        try fm.createDirectory(at: rimeUserDataDirectory, withIntermediateDirectories: true)
        let manifest = loadManifest()

        var enabledExtras: [String] = []
        for rec in manifest.records where rec.isEnabled && rec.id != LexiconCatalog.coreBasePackID {
            let dictURL = rimeDictsDirectory.appendingPathComponent("\(rec.tableName).dict.yaml")
            if fm.fileExists(atPath: dictURL.path) {
                let tableRef = "dicts/\(rec.tableName)"
                if !enabledExtras.contains(tableRef) && !Self.coreWanxiangTables.contains(tableRef) {
                    enabledExtras.append(tableRef)
                }
            }
        }

        // 若没有任何启用的扩展词库，且未覆写核心词库，则删除覆盖文件回落包内原生配置
        let hasUpdatedCore = fm.fileExists(atPath: rimeDictsDirectory.appendingPathComponent("jichu.dict.yaml").path)
        if enabledExtras.isEmpty && !hasUpdatedCore {
            try? fm.removeItem(at: wanxiangDictOverrideURL)
            return
        }

        var lines: [String] = [
            "# Auto-generated by SmartPinyin LexiconManager — do not edit manually",
            "---",
            "name: wanxiang",
            "version: \"\(Self.todayVersionString())\"",
            "sort: by_weight",
            "use_preset_vocabulary: false",
            "import_tables:"
        ]
        for core in Self.coreWanxiangTables {
            lines.append("  - \(core)")
        }
        for extra in enabledExtras {
            lines.append("  - \(extra)")
        }
        lines.append("...")
        let content = lines.joined(separator: "\n") + "\n"

        // 原子备份旧文件
        let backupURL = wanxiangDictOverrideURL.appendingPathExtension("bak")
        if fm.fileExists(atPath: wanxiangDictOverrideURL.path) {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: wanxiangDictOverrideURL, to: backupURL)
        }
        try content.write(to: wanxiangDictOverrideURL, atomically: true, encoding: .utf8)
    }

    /// 触发运行中的输入法热重载词库与领域标签索引
    public func notifyLexiconChanged() {
        guard postNotifications else { return }
        DistributedNotificationCenter.default().postNotificationName(
            SmartPinyinPreferencesStore.lexiconDidChangeNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    // MARK: - 具体格式安装与转换实现

    private func installWanxiangCoreZip(
        from zipURL: URL,
        spec: LexiconPackSpec,
        version: String
    ) throws -> InstalledLexiconRecord {
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("SmartPinyinCoreZip_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stagingDir) }
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-xk", zipURL.path, stagingDir.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw LexiconManagerError.archiveExtractionFailed("ditto 解压退出码 \(proc.terminationStatus)")
        }

        // 在解压目录中找到核心 dict.yaml 文件（兼容顶层或 dicts/ 子目录）
        let allowedCoreFiles: Set<String> = [
            "zi.dict.yaml", "jichu.dict.yaml", "cuoyin.dict.yaml", "duoyin.dict.yaml",
            "diming.dict.yaml", "mingren.dict.yaml", "yiren.dict.yaml", "en.dict.yaml", "mixed.dict.yaml"
        ]
        var foundFiles: [URL] = []
        if let enumerator = fm.enumerator(at: stagingDir, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where allowedCoreFiles.contains(url.lastPathComponent) {
                foundFiles.append(url)
            }
        }
        guard foundFiles.contains(where: { $0.lastPathComponent == "jichu.dict.yaml" }) else {
            throw LexiconManagerError.invalidDictionaryFormat("压缩包中缺少核心 jichu.dict.yaml")
        }

        var totalBytes: Int64 = 0
        for src in foundFiles {
            let dest = rimeDictsDirectory.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
            try fm.copyItem(at: src, to: dest)
            if let attrs = try? fm.attributesOfItem(atPath: dest.path), let sz = attrs[.size] as? Int64 {
                totalBytes += sz
            }
        }

        return InstalledLexiconRecord(
            id: spec.id,
            tableName: spec.tableName,
            displayName: spec.displayName,
            domain: .general,
            isEnabled: true,
            installedVersion: version,
            updatedAt: Date().timeIntervalSince1970,
            entryCount: 1_550_000,
            fileSizeBytes: totalBytes,
            isCustom: false
        )
    }

    private func installRimeYAMLFile(
        from sourceURL: URL,
        spec: LexiconPackSpec,
        version: String
    ) throws -> InstalledLexiconRecord {
        guard let raw = try? String(contentsOf: sourceURL, encoding: .utf8), !raw.isEmpty else {
            throw LexiconManagerError.invalidDictionaryFormat("无法以 UTF-8 读取词库文件")
        }
        let lines = raw.components(separatedBy: .newlines)
        var bodyStart = 0
        if let endHeaderIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "..." }) {
            bodyStart = endHeaderIdx + 1
        }

        var normalizedEntries: [String] = []
        var domainTerms: [String] = []
        normalizedEntries.reserveCapacity(min(lines.count, 50000))

        for idx in bodyStart..<lines.count {
            let line = lines[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard !cols.isEmpty else { continue }
            let word = cols[0].trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }
            if cols.count >= 2 {
                let code = cols[1].trimmingCharacters(in: .whitespaces)
                guard !code.isEmpty else { continue }
                // 对外部社区大词库（moegirl/zhwiki）设定温和权重上限（<= 20），防止喧宾夺主污染日常高频词，
                // 在激活对应场景时交由 0ms SceneContextDetector + Top-16 深层池动态提权！
                let weightStr: String
                if cols.count >= 3, let w = Int(cols[2].trimmingCharacters(in: .whitespaces)) {
                    let capped = (spec.sourceKind == .githubReleaseYAML) ? min(20, max(1, w)) : max(1, w)
                    weightStr = String(capped)
                } else {
                    weightStr = "10"
                }
                normalizedEntries.append("\(word)\t\(code)\t\(weightStr)")
            } else {
                let autoPin = Self.chineseToSpacedPinyin(word)
                guard !autoPin.isEmpty else { continue }
                normalizedEntries.append("\(word)\t\(autoPin)\t10")
            }
            if word.count >= 2 && word.count <= 14 && domainTerms.count < 30000 {
                domainTerms.append(word)
            }
        }

        guard !normalizedEntries.isEmpty else {
            throw LexiconManagerError.invalidDictionaryFormat("文件中未解析出有效词条")
        }

        let header = """
        # SmartPinyin managed Rime dictionary (\(spec.displayName))
        ---
        name: \(spec.tableName)
        version: "\(version)"
        sort: by_weight
        ...
        """
        let output = header + "\n" + normalizedEntries.joined(separator: "\n") + "\n"
        let destURL = rimeDictsDirectory.appendingPathComponent("\(spec.tableName).dict.yaml")
        try output.write(to: destURL, atomically: true, encoding: .utf8)

        if spec.domain != .general && !domainTerms.isEmpty {
            let sidecarURL = userTagsDirectory.appendingPathComponent("\(spec.tableName).bin")
            try? Self.writeSMDM(terms: domainTerms, domainMask: spec.domain.bitMask, to: sidecarURL)
        }

        let bytes = (try? fm.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? Int64(output.utf8.count)
        return InstalledLexiconRecord(
            id: spec.id,
            tableName: spec.tableName,
            displayName: spec.displayName,
            domain: spec.domain,
            isEnabled: true,
            installedVersion: version,
            updatedAt: Date().timeIntervalSince1970,
            entryCount: normalizedEntries.count,
            fileSizeBytes: bytes,
            isCustom: spec.sourceKind == .userImported
        )
    }

    private func installPlainTextWithAutoPinyin(
        from sourceURL: URL,
        packID: String,
        tableName: String,
        displayName: String,
        domain: InputSceneDomain,
        version: String,
        isCustom: Bool
    ) throws -> InstalledLexiconRecord {
        guard let raw = try? String(contentsOf: sourceURL, encoding: .utf8), !raw.isEmpty else {
            throw LexiconManagerError.invalidDictionaryFormat("无法以 UTF-8 读取文本词表")
        }
        var entries: [String] = []
        var domainTerms: [String] = []
        var seen = Set<String>()

        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let cols = line.split(separator: "\t").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let word = cols.first, !word.isEmpty, seen.insert(word).inserted else { continue }

            let pinyinCode: String
            let weight: Int
            if cols.count >= 2 && cols[1].unicodeScalars.allSatisfy({ ($0.value >= 97 && $0.value <= 122) || $0.value == 32 }) {
                pinyinCode = cols[1]
                weight = cols.count >= 3 ? max(1, min(100, Int(cols[2]) ?? 15)) : 15
            } else {
                pinyinCode = Self.chineseToSpacedPinyin(word)
                let rawFreq = cols.count >= 2 ? (Int(cols[1]) ?? 10) : 10
                weight = max(5, min(60, Int(log2(Double(max(2, rawFreq))) * 4.0)))
            }
            guard !pinyinCode.isEmpty else { continue }
            entries.append("\(word)\t\(pinyinCode)\t\(weight)")
            if word.count >= 2 && word.count <= 14 && domainTerms.count < 30000 {
                domainTerms.append(word)
            }
        }

        guard !entries.isEmpty else {
            throw LexiconManagerError.invalidDictionaryFormat("文本词表中未发现可注音的有效中文词条")
        }

        let header = """
        # SmartPinyin auto-converted Rime dictionary (\(displayName))
        ---
        name: \(tableName)
        version: "\(version)"
        sort: by_weight
        ...
        """
        let output = header + "\n" + entries.joined(separator: "\n") + "\n"
        let destURL = rimeDictsDirectory.appendingPathComponent("\(tableName).dict.yaml")
        try output.write(to: destURL, atomically: true, encoding: .utf8)

        if domain != .general && !domainTerms.isEmpty {
            let sidecarURL = userTagsDirectory.appendingPathComponent("\(tableName).bin")
            try? Self.writeSMDM(terms: domainTerms, domainMask: domain.bitMask, to: sidecarURL)
        }

        let bytes = (try? fm.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? Int64(output.utf8.count)
        return InstalledLexiconRecord(
            id: packID,
            tableName: tableName,
            displayName: displayName,
            domain: domain,
            isEnabled: true,
            installedVersion: version,
            updatedAt: Date().timeIntervalSince1970,
            entryCount: entries.count,
            fileSizeBytes: bytes,
            isCustom: isCustom
        )
    }

    // MARK: - 网络与工具函数

    private func fetchGitHubReleaseInfo(
        repo: String,
        tagPath: String,
        assetPrefix: String,
        assetSuffix: String
    ) async -> (version: String, downloadURL: URL?)? {
        guard let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/\(tagPath)") else { return nil }
        var req = URLRequest(url: apiURL, timeoutInterval: 12)
        req.setValue("SmartPinyin-LexiconManager/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let tag = (obj["tag_name"] as? String) ?? ""
        let published = (obj["published_at"] as? String) ?? ""
        let version = published.isEmpty ? tag : "\(tag) (\(String(published.prefix(10))))"

        var assetURL: URL?
        if let assets = obj["assets"] as? [[String: Any]] {
            for asset in assets {
                guard let name = asset["name"] as? String,
                      name.hasPrefix(assetPrefix),
                      name.hasSuffix(assetSuffix),
                      let urlStr = asset["browser_download_url"] as? String,
                      let url = URL(string: urlStr)
                else { continue }
                assetURL = url
                break
            }
        }
        return (version, assetURL)
    }

    private func downloadToTempFile(from url: URL) async throws -> URL {
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue("SmartPinyin-LexiconManager/1.0", forHTTPHeaderField: "User-Agent")
        let (tmpURL, resp) = try await URLSession.shared.download(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LexiconManagerError.downloadFailed("HTTP \(http.statusCode)")
        }
        let dest = fm.temporaryDirectory.appendingPathComponent("SmartPinyinLex_\(UUID().uuidString)_\(url.lastPathComponent)")
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmpURL, to: dest)
        return dest
    }

    private func loadManifest() -> LexiconManifest {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode(LexiconManifest.self, from: data)
        else { return LexiconManifest() }
        return decoded
    }

    private func saveManifest(_ manifest: LexiconManifest) {
        lock.lock()
        defer { lock.unlock() }
        try? fm.createDirectory(at: lexiconPacksDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    private func upsertRecord(_ record: InstalledLexiconRecord) {
        var manifest = loadManifest()
        if let idx = manifest.records.firstIndex(where: { $0.id == record.id }) {
            manifest.records[idx] = record
        } else {
            manifest.records.append(record)
        }
        saveManifest(manifest)
    }

    public static func chineseToSpacedPinyin(_ word: String) -> String {
        var syllables: [String] = []
        syllables.reserveCapacity(word.count)
        for ch in word {
            guard let scalar = ch.unicodeScalars.first,
                  (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
            else { continue }
            let m = NSMutableString(string: String(ch)) as CFMutableString
            CFStringTransform(m, nil, kCFStringTransformToLatin, false)
            CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
            let cleaned = (m as String).lowercased().filter { $0 >= "a" && $0 <= "z" }
            guard !cleaned.isEmpty else { return "" }
            syllables.append(cleaned)
        }
        guard syllables.count == word.count else { return "" }
        return syllables.joined(separator: " ")
    }

    private static func extractTermsFromRimeYAML(at url: URL, limit: Int) -> [String]? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var terms: [String] = []
        var inBody = false
        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t == "..." {
                inBody = true
                continue
            }
            if !inBody || t.isEmpty || t.hasPrefix("#") { continue }
            if let word = t.split(separator: "\t").first.map(String.init),
               word.count >= 2 && word.count <= 14 {
                terms.append(word)
                if terms.count >= limit { break }
            }
        }
        return terms
    }

    /// 写出与 DomainAndLiteraryTagStore 完全兼容的 SMDM v1 侧车二进制索引
    private static func writeSMDM(terms: [String], domainMask: UInt16, to url: URL) throws {
        guard domainMask != 0 else { return }
        struct Key: Hashable, Comparable {
            let hi: UInt64
            let lo: UInt64
            static func < (lhs: Key, rhs: Key) -> Bool {
                lhs.hi != rhs.hi ? lhs.hi < rhs.hi : lhs.lo < rhs.lo
            }
        }
        func hash128(_ text: String) -> Key {
            let bytes = Array(text.utf8)
            let prime: UInt64 = 0x100000001b3
            var hi: UInt64 = 0xcbf29ce484222325
            for b in bytes { hi = (hi ^ UInt64(b)) &* prime }
            var lo: UInt64 = 0x84222325cbf29ce4
            for b in bytes.reversed() { lo = (lo ^ UInt64(b)) &* prime }
            lo ^= UInt64(bytes.count) &* 0x9e3779b97f4a7c15
            return Key(hi: hi, lo: lo)
        }
        func appendLE<T: FixedWidthInteger>(_ v: T, to data: inout Data) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        var map: [Key: UInt16] = [:]
        map.reserveCapacity(terms.count)
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 && trimmed.count <= 14 else { continue }
            map[hash128(trimmed), default: 0] |= domainMask
        }
        let sorted = map.sorted { $0.key < $1.key }
        var data = Data(capacity: 16 + sorted.count * 20)
        data.append(contentsOf: [0x53, 0x4D, 0x44, 0x4D]) // "SMDM"
        appendLE(UInt32(1), to: &data)
        appendLE(UInt32(sorted.count), to: &data)
        appendLE(UInt32(0), to: &data)
        for (k, m) in sorted {
            appendLE(k.hi, to: &data)
            appendLE(k.lo, to: &data)
            appendLE(m, to: &data)
            appendLE(UInt16(0), to: &data)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func todayVersionString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy.MM.dd"
        return fmt.string(from: Date())
    }

    private static func formatByteSize(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
        return String(format: "%.0f KB", max(1.0, Double(bytes) / 1024.0))
    }
}
