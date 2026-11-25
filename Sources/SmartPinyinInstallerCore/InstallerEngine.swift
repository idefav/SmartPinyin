import AppKit
import Foundation
import SharedIPC

/// 安装目标范围
public enum InstallScope: String, CaseIterable, Identifiable, Sendable {
    case allUsers
    case currentUser

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .allUsers: return "为所有用户安装至 /Library/Input Methods（推荐，系统设置可正常显示名称与图标）"
        case .currentUser: return "仅为当前用户安装至 ~/Library/Input Methods（免管理员密码）"
        }
    }

    public var inputMethodsDirectory: URL {
        switch self {
        case .currentUser:
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Input Methods", isDirectory: true)
        case .allUsers:
            return URL(fileURLWithPath: "/Library/Input Methods", isDirectory: true)
        }
    }

    public var applicationsDirectory: URL {
        switch self {
        case .currentUser:
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        case .allUsers:
            return URL(fileURLWithPath: "/Applications", isDirectory: true)
        }
    }

    public var requiresAdminPrivileges: Bool {
        self == .allUsers
    }
}

/// 卸载勾选项
public struct UninstallOptions: Equatable, Sendable {
    public var removeUserDictionaries: Bool
    public var removeLocalModels: Bool
    public var removePreferencesAndLogs: Bool

    public init(
        removeUserDictionaries: Bool = false,
        removeLocalModels: Bool = false,
        removePreferencesAndLogs: Bool = true
    ) {
        self.removeUserDictionaries = removeUserDictionaries
        self.removeLocalModels = removeLocalModels
        self.removePreferencesAndLogs = removePreferencesAndLogs
    }
}

/// 卸载前磁盘占用明细
public struct DiskUsageReport: Equatable, Sendable {
    public let inputMethodBytes: Int64
    public let setupAppBytes: Int64
    public let preferencesAndLogsBytes: Int64
    public let userDictionaryBytes: Int64
    public let localModelsBytes: Int64
    public let installedAppPaths: [URL]
    public let installedSetupAppPaths: [URL]

    public init(
        inputMethodBytes: Int64,
        setupAppBytes: Int64,
        preferencesAndLogsBytes: Int64 = 0,
        userDictionaryBytes: Int64,
        localModelsBytes: Int64,
        installedAppPaths: [URL],
        installedSetupAppPaths: [URL]
    ) {
        self.inputMethodBytes = inputMethodBytes
        self.setupAppBytes = setupAppBytes
        self.preferencesAndLogsBytes = preferencesAndLogsBytes
        self.userDictionaryBytes = userDictionaryBytes
        self.localModelsBytes = localModelsBytes
        self.installedAppPaths = installedAppPaths
        self.installedSetupAppPaths = installedSetupAppPaths
    }

    public var totalRemovableAppBytes: Int64 { inputMethodBytes + setupAppBytes }
}

/// 安装与自卸载过程中的可观测步骤
public struct LifecycleProgress: Sendable {
    public let step: Int
    public let totalSteps: Int
    public let message: String

    public init(step: Int, totalSteps: Int, message: String) {
        self.step = step
        self.totalSteps = totalSteps
        self.message = message
    }
}

public enum InstallerEngineError: LocalizedError, Equatable {
    case payloadNotFound(String)
    case unsafeDeletionPath(String)
    case privilegedOperationFailed(String)
    case fileOperationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .payloadNotFound(let p): return "找不到待安装的输入法包：\(p)"
        case .unsafeDeletionPath(let p): return "出于安全保护，拒绝删除白名单之外的路径：\(p)"
        case .privilegedOperationFailed(let m): return "管理员授权操作未完成：\(m)"
        case .fileOperationFailed(let m): return "文件操作失败：\(m)"
        }
    }
}

/// 强白名单路径校验器：严防路径穿越或误删系统/用户无关文件
public struct DeletionPathValidator: Sendable {
    private let homePath: String
    private let sandboxRootPath: String?

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        sandboxRoot: URL? = nil
    ) {
        self.homePath = homeDirectory.standardizedFileURL.path
        self.sandboxRootPath = sandboxRoot?.standardizedFileURL.path
    }

    public func isAllowedToDelete(_ url: URL) -> Bool {
        let raw = url.path
        // 拒绝包含未规范化穿越片段的路径
        if raw.split(separator: "/").contains("..") {
            return false
        }
        let path = url.standardizedFileURL.path
        guard path != "/", !path.isEmpty, path != homePath else { return false }

        let baseHome = sandboxRootPath ?? homePath
        let allowedExactPaths: Set<String> = [
            "\(baseHome)/Library/Input Methods/SmartPinyin.app",
            "\(baseHome)/Applications/SmartPinyin Setup.app",
            "\(baseHome)/Applications/SmartPinyin.app",
            "\(baseHome)/Library/Application Support/SmartPinyin",
            "\(baseHome)/Library/Application Support/SmartPinyin/RimeUserData",
            "\(baseHome)/Library/Application Support/SmartPinyin/LexiconPacks",
            "\(baseHome)/Library/Application Support/SmartPinyin/user_memory.sqlite3",
            "\(baseHome)/Library/Application Support/SmartPinyin/user_memory.sqlite3-wal",
            "\(baseHome)/Library/Application Support/SmartPinyin/user_memory.sqlite3-shm",
            "\(baseHome)/Library/Application Support/SmartPinyin/preferences.json",
            "\(baseHome)/Library/Application Support/SmartPinyin/Logs",
            "\(baseHome)/Library/Application Support/SmartPinyin/Models",
            "\(baseHome)/Library/Caches/\(SmartPinyinIdentifiers.appBundleID)",
            "\(baseHome)/Library/Caches/\(SmartPinyinIdentifiers.appBundleID).Setup",
            "\(baseHome)/Library/HTTPStorages/\(SmartPinyinIdentifiers.appBundleID)",
            "\(baseHome)/Library/HTTPStorages/\(SmartPinyinIdentifiers.appBundleID).Setup",
            "\(baseHome)/Library/Preferences/\(SmartPinyinIdentifiers.appBundleID).plist",
            "\(baseHome)/Library/Preferences/\(SmartPinyinIdentifiers.appBundleID).Setup.plist",
            "/Library/Input Methods/SmartPinyin.app",
            "/Library/Application Support/SmartPinyin/BundledModels",
            "/Applications/SmartPinyin Setup.app"
        ]
        if allowedExactPaths.contains(path) {
            return true
        }
        // 允许删除嵌在 SmartPinyin.app 内部的子路径（如 Helpers/SmartPinyinSetup.app）
        if path.hasPrefix("\(baseHome)/Library/Input Methods/SmartPinyin.app/")
            || path.hasPrefix("/Library/Input Methods/SmartPinyin.app/") {
            return true
        }
        return false
    }
}

/// 负责 SmartPinyin 的安装部署、状态探测以及 6 步零残留「卸载自己」流水线。
/// 支持通过自定义根目录注入，便于自动化单元测试在临时沙箱中完整跑通安装与卸载。
public final class InstallerEngine: @unchecked Sendable {
    public let homeDirectory: URL
    public let systemInputMethodsDirectory: URL
    public let systemApplicationsDirectory: URL
    public let validator: DeletionPathValidator
    public let skipSystemIntegration: Bool

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemInputMethodsDirectory: URL = URL(fileURLWithPath: "/Library/Input Methods", isDirectory: true),
        systemApplicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        sandboxRootForValidation: URL? = nil,
        skipSystemIntegration: Bool = false
    ) {
        self.homeDirectory = homeDirectory
        self.systemInputMethodsDirectory = systemInputMethodsDirectory
        self.systemApplicationsDirectory = systemApplicationsDirectory
        self.validator = DeletionPathValidator(
            homeDirectory: homeDirectory,
            sandboxRoot: sandboxRootForValidation
        )
        self.skipSystemIntegration = skipSystemIntegration
    }

    public var appSupportDirectory: URL {
        homeDirectory.appendingPathComponent("Library/Application Support/\(SmartPinyinIdentifiers.appSupportFolderName)", isDirectory: true)
    }

    public var userInputMethodURL: URL {
        homeDirectory.appendingPathComponent("Library/Input Methods/SmartPinyin.app", isDirectory: true)
    }

    public var systemInputMethodURL: URL {
        systemInputMethodsDirectory.appendingPathComponent("SmartPinyin.app", isDirectory: true)
    }

    public var userSetupAppURL: URL {
        homeDirectory.appendingPathComponent("Applications/SmartPinyin Setup.app", isDirectory: true)
    }

    public var systemSetupAppURL: URL {
        systemApplicationsDirectory.appendingPathComponent("SmartPinyin Setup.app", isDirectory: true)
    }

    /// 定位安装包内置的 SmartPinyin.app 载荷路径
    public static func locateEmbeddedPayload(in bundle: Bundle = .main) -> URL? {
        let fm = FileManager.default
        let candidates: [URL?] = [
            bundle.resourceURL?.appendingPathComponent("Payload/SmartPinyin.app"),
            bundle.resourceURL?.appendingPathComponent("SmartPinyin.app"),
            bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("SmartPinyin.app")
        ]
        for case let url? in candidates where fm.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    /// 扫描当前系统中已安装的 SmartPinyin 本体及各数据目录磁盘占用（优先系统级路径在前）
    public func inspectDiskUsage() -> DiskUsageReport {
        let fm = FileManager.default
        let imeCandidates = [systemInputMethodURL, userInputMethodURL].filter { fm.fileExists(atPath: $0.path) }
        let setupCandidates = [systemSetupAppURL, userSetupAppURL].filter { fm.fileExists(atPath: $0.path) }

        let imeBytes = imeCandidates.reduce(Int64(0)) { $0 + Self.directorySize(at: $1) }
        let setupBytes = setupCandidates.reduce(Int64(0)) { $0 + Self.directorySize(at: $1) }
        let prefsAndLogsBytes = Self.directorySize(at: appSupportDirectory.appendingPathComponent("Logs"))
            + Self.directorySize(at: appSupportDirectory.appendingPathComponent("preferences.json"))
            + Self.directorySize(at: homeDirectory.appendingPathComponent("Library/Caches/\(SmartPinyinIdentifiers.appBundleID)"))
            + Self.directorySize(at: homeDirectory.appendingPathComponent("Library/Caches/\(SmartPinyinIdentifiers.appBundleID).Setup"))
            + Self.directorySize(at: homeDirectory.appendingPathComponent("Library/HTTPStorages/\(SmartPinyinIdentifiers.appBundleID)"))
            + Self.directorySize(at: homeDirectory.appendingPathComponent("Library/HTTPStorages/\(SmartPinyinIdentifiers.appBundleID).Setup"))
        let rimeDataBytes = Self.directorySize(at: appSupportDirectory.appendingPathComponent("RimeUserData"))
            + Self.directorySize(at: appSupportDirectory.appendingPathComponent("LexiconPacks"))
            + Self.directorySize(at: appSupportDirectory.appendingPathComponent("user_memory.sqlite3"))
            + Self.directorySize(at: appSupportDirectory.appendingPathComponent("user_memory.sqlite3-wal"))
            + Self.directorySize(at: appSupportDirectory.appendingPathComponent("user_memory.sqlite3-shm"))
        let modelsBytes = Self.directorySize(at: appSupportDirectory.appendingPathComponent("Models"))

        return DiskUsageReport(
            inputMethodBytes: imeBytes,
            setupAppBytes: setupBytes,
            preferencesAndLogsBytes: prefsAndLogsBytes,
            userDictionaryBytes: rimeDataBytes,
            localModelsBytes: modelsBytes,
            installedAppPaths: imeCandidates,
            installedSetupAppPaths: setupCandidates
        )
    }

    /// 执行安装部署（支持覆盖升级）
    public func install(
        payloadAppURL: URL,
        scope: InstallScope,
        setupAppBundleURL: URL? = nil,
        bundledModelsDir: URL? = nil,
        onProgress: ((LifecycleProgress) -> Void)? = nil
    ) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: payloadAppURL.path) else {
            throw InstallerEngineError.payloadNotFound(payloadAppURL.path)
        }

        let targetIMEDir = (scope == .currentUser)
            ? homeDirectory.appendingPathComponent("Library/Input Methods", isDirectory: true)
            : systemInputMethodsDirectory
        let targetAppDir = (scope == .currentUser)
            ? homeDirectory.appendingPathComponent("Applications", isDirectory: true)
            : systemApplicationsDirectory

        let destIME = targetIMEDir.appendingPathComponent("SmartPinyin.app", isDirectory: true)
        let destSetup = targetAppDir.appendingPathComponent("SmartPinyin Setup.app", isDirectory: true)
        let isUpgrade = fm.fileExists(atPath: destIME.path)

        onProgress?(LifecycleProgress(step: 1, totalSteps: 4, message: "正在停止旧版输入法进程…"))
        if !skipSystemIntegration {
            terminateIMEProcesses()
        }

        onProgress?(LifecycleProgress(step: 2, totalSteps: 4, message: "正在安装 SmartPinyin.app 到 \(targetIMEDir.path)…"))
        if scope.requiresAdminPrivileges && !skipSystemIntegration {
            try installWithAdminPrivileges(
                payloadAppURL: payloadAppURL,
                destIME: destIME,
                setupAppBundleURL: setupAppBundleURL,
                destSetup: destSetup
            )
            // 若旧版曾装在 ~/Library/Input Methods/ 或 ~/Applications/ 下，先注销 LaunchServices 再移除重复副本，防止系统设置与启动台冲突
            if fm.fileExists(atPath: userInputMethodURL.path),
               userInputMethodURL.standardizedFileURL != destIME.standardizedFileURL {
                unregisterLaunchServices(for: userInputMethodURL)
                try? fm.removeItem(at: userInputMethodURL)
            }
            if fm.fileExists(atPath: userSetupAppURL.path),
               userSetupAppURL.standardizedFileURL != destSetup.standardizedFileURL {
                unregisterLaunchServices(for: userSetupAppURL)
                try? fm.removeItem(at: userSetupAppURL)
            }
        } else {
            // 若已存在系统级副本而用户切换到当前用户级安装，阻断双副本共存并明确指引
            if !skipSystemIntegration,
               scope == .currentUser,
               fm.fileExists(atPath: systemInputMethodURL.path),
               systemInputMethodURL.standardizedFileURL != destIME.standardizedFileURL {
                throw InstallerEngineError.fileOperationFailed(
                    "检测到系统目录已存在 \(systemInputMethodURL.path)。为避免输入法双副本冲突，请选择「为所有用户安装」覆盖升级，或先卸载旧版后再安装至当前用户目录。"
                )
            }
            try fm.createDirectory(at: targetIMEDir, withIntermediateDirectories: true)
            try atomicReplaceBundle(from: payloadAppURL, to: destIME)
            clearQuarantineIfNeeded(at: destIME)

            if let setupURL = setupAppBundleURL,
               fm.fileExists(atPath: setupURL.path),
               setupURL.standardizedFileURL != destSetup.standardizedFileURL {
                try fm.createDirectory(at: targetAppDir, withIntermediateDirectories: true)
                try atomicReplaceBundle(from: setupURL, to: destSetup)
                clearQuarantineIfNeeded(at: destSetup)
            }
        }

        onProgress?(LifecycleProgress(step: 3, totalSteps: 4, message: "正在初始化应用支持目录与离线模型…"))
        try fm.createDirectory(at: appSupportDirectory.appendingPathComponent("Models"), withIntermediateDirectories: true)
        if let modelsDir = bundledModelsDir, fm.fileExists(atPath: modelsDir.path) {
            let provisioner = ModelProvisioner(
                targetModelsDirectory: appSupportDirectory.appendingPathComponent("Models"),
                extraSearchDirectories: [modelsDir]
            )
            for item in provisioner.inspectAll() {
                if case .discoverable(let src, _) = item.availability {
                    onProgress?(LifecycleProgress(step: 3, totalSteps: 4, message: "正在导入内置离线模型：\(item.spec.displayName)…"))
                    do {
                        _ = try provisioner.importModel(from: src, for: item.spec, preferSymlink: false)
                    } catch {
                        throw InstallerEngineError.fileOperationFailed("内置模型 \(item.spec.displayName) 导入失败：\(error.localizedDescription)")
                    }
                }
            }
        }

        onProgress?(LifecycleProgress(step: 4, totalSteps: 4, message: "正在向系统注册并尝试启用输入源…"))
        if !skipSystemIntegration {
            clearStaleIntlDataCaches()
            refreshLaunchServices(for: destIME)
            if fm.fileExists(atPath: destSetup.path) {
                refreshLaunchServices(for: destSetup)
            }
            _ = InputSourceManager.registerAndEnable(bundleURL: destIME)
            refreshTextInputMenuAgent(launchingIMEAt: destIME, restartIMKAgent: !isUpgrade)
        }
        return destIME
    }

    /// 6 步零残留自卸载流水线。
    /// 返回已删除路径、需要退出后清理的用户级自删路径，以及卸载完成后是否应自动退出当前进程。
    public struct UninstallResult: Equatable, Sendable {
        public let removedPaths: [URL]
        public let deferredSelfDeletePaths: [URL]
        public let selfDeleteScriptURL: URL?
        public let removedCurrentProcessBundle: Bool

        public var shouldTerminateAfterUninstall: Bool {
            removedCurrentProcessBundle || !deferredSelfDeletePaths.isEmpty
        }

        public init(
            removedPaths: [URL],
            deferredSelfDeletePaths: [URL],
            selfDeleteScriptURL: URL?,
            removedCurrentProcessBundle: Bool = false
        ) {
            self.removedPaths = removedPaths
            self.deferredSelfDeletePaths = deferredSelfDeletePaths
            self.selfDeleteScriptURL = selfDeleteScriptURL
            self.removedCurrentProcessBundle = removedCurrentProcessBundle
        }
    }

    public func uninstall(
        options: UninstallOptions,
        currentProcessBundleURL: URL? = Bundle.main.bundleURL,
        launchDeferredScript: Bool = true,
        onProgress: ((LifecycleProgress) -> Void)? = nil
    ) throws -> UninstallResult {
        let fm = FileManager.default
        let currentPath = currentProcessBundleURL?.standardizedFileURL.path

        onProgress?(LifecycleProgress(step: 1, totalSteps: 6, message: "正在收集待清理目录并执行安全白名单校验…"))
        var candidateTargets: [URL] = [
            userInputMethodURL,
            systemInputMethodURL,
            userSetupAppURL,
            systemSetupAppURL,
            URL(fileURLWithPath: "/Library/Application Support/SmartPinyin/BundledModels", isDirectory: true)
        ]

        if options.removePreferencesAndLogs {
            candidateTargets.append(homeDirectory.appendingPathComponent("Library/Caches/\(SmartPinyinIdentifiers.appBundleID)"))
            candidateTargets.append(homeDirectory.appendingPathComponent("Library/Caches/\(SmartPinyinIdentifiers.appBundleID).Setup"))
            candidateTargets.append(homeDirectory.appendingPathComponent("Library/HTTPStorages/\(SmartPinyinIdentifiers.appBundleID)"))
            candidateTargets.append(homeDirectory.appendingPathComponent("Library/HTTPStorages/\(SmartPinyinIdentifiers.appBundleID).Setup"))
            candidateTargets.append(homeDirectory.appendingPathComponent("Library/Preferences/\(SmartPinyinIdentifiers.appBundleID).plist"))
            candidateTargets.append(homeDirectory.appendingPathComponent("Library/Preferences/\(SmartPinyinIdentifiers.appBundleID).Setup.plist"))
            candidateTargets.append(appSupportDirectory.appendingPathComponent("preferences.json"))
            candidateTargets.append(appSupportDirectory.appendingPathComponent("Logs"))
        }
        if options.removeUserDictionaries {
            candidateTargets.append(appSupportDirectory.appendingPathComponent("RimeUserData"))
            candidateTargets.append(appSupportDirectory.appendingPathComponent("LexiconPacks"))
            candidateTargets.append(appSupportDirectory.appendingPathComponent("user_memory.sqlite3"))
            candidateTargets.append(appSupportDirectory.appendingPathComponent("user_memory.sqlite3-wal"))
            candidateTargets.append(appSupportDirectory.appendingPathComponent("user_memory.sqlite3-shm"))
        }
        if options.removeLocalModels {
            candidateTargets.append(appSupportDirectory.appendingPathComponent("Models"))
        }
        if options.removeUserDictionaries && options.removeLocalModels && options.removePreferencesAndLogs {
            candidateTargets.append(appSupportDirectory)
        }

        // 只保留实际存在且通过强白名单校验的路径
        var existingValidated: [URL] = []
        for url in candidateTargets {
            guard fm.fileExists(atPath: url.path) else { continue }
            guard validator.isAllowedToDelete(url) else {
                throw InstallerEngineError.unsafeDeletionPath(url.path)
            }
            if !existingValidated.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                existingValidated.append(url.standardizedFileURL)
            }
        }

        // 区分系统级特权路径（在 UI 存活期间同步单次提权删除，用户取消可无损中止）与用户级路径（仅运行中的用户级 App 走无密码延迟自删）
        var immediateUserPaths: [URL] = []
        var immediatePrivilegedPaths: [URL] = []
        var deferredSelfPaths: [URL] = []
        var privilegedContainsCurrentProcess = false

        for url in existingValidated {
            let p = url.path
            let isPrivileged = p.hasPrefix("/Library/") || p.hasPrefix("/Applications/")
            let containsCurrent = currentPath.map { $0 == p || $0.hasPrefix(p + "/") } ?? false
            if isPrivileged {
                immediatePrivilegedPaths.append(url)
                if containsCurrent {
                    privilegedContainsCurrentProcess = true
                }
            } else if containsCurrent {
                deferredSelfPaths.append(url)
            } else {
                immediateUserPaths.append(url)
            }
        }

        let intactIMEBeforeUninstall = [systemInputMethodURL, userInputMethodURL].first { fm.fileExists(atPath: $0.path) }

        onProgress?(LifecycleProgress(step: 2, totalSteps: 6, message: "正在切换回系统英文键盘并停止输入法进程…"))
        if !skipSystemIntegration {
            InputSourceManager.disableAllAndSwitchToSafeKeyboard()
            terminateIMEProcesses()
            for url in existingValidated where url.pathExtension == "app" {
                unregisterLaunchServices(for: url)
            }
        }

        var removed: [URL] = []
        onProgress?(LifecycleProgress(step: 3, totalSteps: 6, message: "正在移除系统级输入法组件…"))
        if !immediatePrivilegedPaths.isEmpty {
            if skipSystemIntegration {
                for url in immediatePrivilegedPaths where fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                    removed.append(url)
                }
            } else {
                do {
                    try removeWithAdminPrivileges(paths: immediatePrivilegedPaths)
                    removed.append(contentsOf: immediatePrivilegedPaths)
                } catch {
                    // 用户取消管理员授权或提权失败：用户词库/模型/偏好尚未触动，恢复原输入法注册与拉起，防止进入半卸载损坏态！
                    if let intactIME = intactIMEBeforeUninstall, fm.fileExists(atPath: intactIME.path) {
                        refreshLaunchServices(for: intactIME)
                        _ = InputSourceManager.registerAndEnable(bundleURL: intactIME)
                        runSilentProcess("/usr/bin/open", arguments: ["-g", intactIME.path])
                    }
                    throw error
                }
            }
        }

        onProgress?(LifecycleProgress(step: 4, totalSteps: 6, message: "正在移除用户级文件与缓存…"))
        for url in immediateUserPaths {
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
                removed.append(url)
            }
        }

        onProgress?(LifecycleProgress(step: 5, totalSteps: 6, message: "正在清理系统偏好与权限缓存…"))
        if !skipSystemIntegration {
            if options.removePreferencesAndLogs {
                runSilentProcess("/usr/bin/defaults", arguments: ["delete", SmartPinyinIdentifiers.appBundleID])
                runSilentProcess("/usr/bin/defaults", arguments: ["delete", "\(SmartPinyinIdentifiers.appBundleID).Setup"])
            }
            // 尽力清理辅助功能 TCC 残留条目（受系统权限限制时静默容错）
            runSilentProcess("/usr/bin/tccutil", arguments: ["reset", "Accessibility", SmartPinyinIdentifiers.appBundleID])
        }

        onProgress?(LifecycleProgress(step: 6, totalSteps: 6, message: "正在刷新输入法缓存并完成卸载…"))
        if !skipSystemIntegration {
            clearStaleIntlDataCaches()
            refreshTextInputMenuAgent(launchingIMEAt: nil)
        }
        var scriptURL: URL?
        if !deferredSelfPaths.isEmpty {
            let script = try createSelfDeleteScript(targets: deferredSelfPaths, requiresAdmin: false)
            scriptURL = script
            if launchDeferredScript && !skipSystemIntegration {
                try spawnDetachedSelfDelete(scriptURL: script)
            }
        }

        return UninstallResult(
            removedPaths: removed,
            deferredSelfDeletePaths: deferredSelfPaths,
            selfDeleteScriptURL: scriptURL,
            removedCurrentProcessBundle: privilegedContainsCurrentProcess
        )
    }

    /// 生成严格转义、脱离会话的一次性自删脚本（便于退出自身进程后彻底抹除残留 .app）
    public func createSelfDeleteScript(targets: [URL], requiresAdmin: Bool = false) throws -> URL {
        for url in targets {
            guard validator.isAllowedToDelete(url) else {
                throw InstallerEngineError.unsafeDeletionPath(url.path)
            }
        }

        let scriptName = "smartpinyin-selfclean-\(UUID().uuidString).sh"
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent(scriptName)
        let pid = ProcessInfo.processInfo.processIdentifier

        var lines: [String] = [
            "#!/bin/sh",
            "set -u",
            "# 等待卸载器进程退出后再执行文件清理",
            "i=0",
            "while kill -0 \(pid) 2>/dev/null && [ \"$i\" -lt 30 ]; do",
            "  sleep 0.2",
            "  i=$((i + 1))",
            "done",
            "sleep 0.3"
        ]

        if requiresAdmin {
            let quotedTargets = targets.map { Self.shellSingleQuote($0.standardizedFileURL.path) }.joined(separator: " ")
            let cmd = "rm -rf -- \(quotedTargets) && { rm -f /System/Library/Caches/com.apple.IntlDataCache* 2>/dev/null || true; }"
            let escapedForAppleScript = cmd
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("/usr/bin/osascript -e \"do shell script \\\"\(escapedForAppleScript)\\\" with administrator privileges\"")
        } else {
            for url in targets {
                let q = Self.shellSingleQuote(url.standardizedFileURL.path)
                lines.append("rm -rf -- \(q)")
            }
        }

        lines.append("rm -f -- \"$0\"")
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    // MARK: - 私有系统操作辅助

    private func spawnDetachedSelfDelete(scriptURL: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        proc.arguments = ["/bin/sh", scriptURL.path]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }

    private func terminateIMEProcesses() {
        runSilentProcess("/usr/bin/pkill", arguments: ["-x", "SmartPinyin"])
        runSilentProcess("/usr/bin/pkill", arguments: ["-x", "SmartPinyinInference"])
        // 关闭除当前进程之外的其他 SmartPinyin Setup 实例（如从 DMG 覆盖升级或卸载时，避免后台旧 Setup 窗口驻留）
        let myPID = ProcessInfo.processInfo.processIdentifier
        let setupApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: "\(SmartPinyinIdentifiers.appBundleID).Setup"
        )
        for app in setupApps where app.processIdentifier != myPID {
            if !app.terminate() {
                _ = app.forceTerminate()
            }
        }
        Thread.sleep(forTimeInterval: 0.25)
    }

    private func installWithAdminPrivileges(
        payloadAppURL: URL,
        destIME: URL,
        setupAppBundleURL: URL?,
        destSetup: URL
    ) throws {
        // 使用就地 rsync -a --delete 覆盖同步，保留 SmartPinyin.app 目录 inode 以稳定维持已授予的辅助功能 TCC 权限
        // 非关键清理命令使用 { ... || true; } 包裹，防止 POSIX && / || 同级左结合意外吞掉前面关键步骤的失败
        let srcIME = Self.shellSingleQuote(payloadAppURL.path + "/")
        let dstIME = Self.shellSingleQuote(destIME.path + "/")
        let dstIMEPath = Self.shellSingleQuote(destIME.path)
        var commands: [String] = [
            "mkdir -p \(dstIMEPath)",
            "/usr/bin/rsync -ac --delete \(srcIME) \(dstIME)",
            "chown -R root:wheel \(dstIMEPath)",
            "chmod -R a+rX \(dstIMEPath)",
            "{ xattr -dr com.apple.quarantine \(dstIMEPath) 2>/dev/null || true; }",
            "{ rm -f /System/Library/Caches/com.apple.IntlDataCache* 2>/dev/null || true; }",
            "{ \(Self.shellSingleQuote(destIME.appendingPathComponent("Contents/MacOS/SmartPinyin").path)) --register-system-cache 2>/dev/null || true; }"
        ]
        if let setupURL = setupAppBundleURL,
           FileManager.default.fileExists(atPath: setupURL.path),
           setupURL.standardizedFileURL != destSetup.standardizedFileURL {
            let srcSetup = Self.shellSingleQuote(setupURL.path + "/")
            let dstSetup = Self.shellSingleQuote(destSetup.path + "/")
            let dstSetupPath = Self.shellSingleQuote(destSetup.path)
            commands.append("mkdir -p \(dstSetupPath)")
            commands.append("/usr/bin/rsync -ac --delete \(srcSetup) \(dstSetup)")
            commands.append("chown -R root:wheel \(dstSetupPath)")
            commands.append("chmod -R a+rX \(dstSetupPath)")
            commands.append("{ xattr -dr com.apple.quarantine \(dstSetupPath) 2>/dev/null || true; }")
        }
        try runPrivilegedShell(commands.joined(separator: " && "))
    }

    private func removeWithAdminPrivileges(paths: [URL]) throws {
        let quoted = paths.map { Self.shellSingleQuote($0.standardizedFileURL.path) }.joined(separator: " ")
        let cmd = [
            "rm -rf -- \(quoted)",
            "{ rmdir '/Library/Application Support/SmartPinyin' 2>/dev/null || true; }",
            "{ rm -f /System/Library/Caches/com.apple.IntlDataCache* 2>/dev/null || true; }",
            "{ /usr/sbin/pkgutil --forget com.smartpinyin.inputmethod.SmartPinyin.pkg 2>/dev/null || true; }"
        ].joined(separator: " && ")
        try runPrivilegedShell(cmd)
    }

    private func runPrivilegedShell(_ shellCommand: String) throws {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "授权已取消"
            throw InstallerEngineError.privilegedOperationFailed(errText)
        }
    }

    private func atomicReplaceBundle(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            // 覆盖升级时优先就地 rsync（-c 按校验和比对，避免同秒同字节文件漏更新）保留目录 inode，防止辅助功能 TCC 授权失效
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
            proc.arguments = ["-ac", "--delete", source.path + "/", destination.path + "/"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                return
            }
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).staging-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }

    private func refreshLaunchServices(for bundleURL: URL) {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        runSilentProcess(lsregister, arguments: ["-f", bundleURL.path])
    }

    private func unregisterLaunchServices(for bundleURL: URL) {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        runSilentProcess(lsregister, arguments: ["-u", bundleURL.path])
    }

    /// 清理当前用户缓存目录与系统设置键盘扩展沙盒下陈旧的 IntlDataCache，
    /// 避免覆盖升级或变更安装目录后，系统设置继续读取旧的输入法图标与名称缓存。
    private func clearStaleIntlDataCaches() {
        let fm = FileManager.default
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/getconf")
        proc.arguments = ["DARWIN_USER_CACHE_DIR"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return }
        proc.waitUntilExit()
        let rawPath = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawPath.isEmpty else { return }

        let cacheRoot = URL(fileURLWithPath: rawPath, isDirectory: true)
        let dirs = [
            cacheRoot,
            cacheRoot.appendingPathComponent("com.apple.Keyboard-Settings.extension", isDirectory: true),
            cacheRoot.appendingPathComponent("com.apple.TextInputUI.xpc.CursorUIViewService", isDirectory: true)
        ]
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.lastPathComponent.hasPrefix("com.apple.IntlDataCache") {
                try? fm.removeItem(at: item)
            }
        }
    }

    private func refreshTextInputMenuAgent(launchingIMEAt bundleURL: URL? = nil, restartIMKAgent: Bool = true) {
        // 绝不强杀 imklaunchagent，避免打断其他正在使用输入法的终端/编辑器连接；仅温和刷新菜单栏输入源代理
        InputSourceManager.invalidateUIOrderCache()
        if restartIMKAgent {
            runSilentProcess("/usr/bin/pkill", arguments: ["-x", "TextInputMenuAgent"])
        }
        if let bundleURL, FileManager.default.fileExists(atPath: bundleURL.path) {
            Thread.sleep(forTimeInterval: 0.25)
            runSilentProcess("/usr/bin/open", arguments: ["-g", bundleURL.path])
        }
    }

    private func clearQuarantineIfNeeded(at url: URL) {
        guard !skipSystemIntegration else { return }
        runSilentProcess("/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", url.path])
    }

    private func runSilentProcess(_ path: String, arguments: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    public static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int64) ?? 0
        }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let sz = values.fileSize
            else { continue }
            total += Int64(sz)
        }
        return total
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        return formatter.string(fromByteCount: bytes)
    }
}
