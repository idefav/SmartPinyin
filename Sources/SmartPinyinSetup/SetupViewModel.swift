import AppKit
import Foundation
import SharedIPC
import SmartPinyinInstallerCore
import UniformTypeIdentifiers

public enum SetupTab: String, CaseIterable, Identifiable {
    case preferences = "常用配置"
    case lexicon = "词库与场景"
    case onboarding = "安装引导"
    case status = "权限与模型"
    case uninstall = "卸载自己"

    public var id: String { rawValue }
}

public enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcomeInstall = 0
    case enableInputSource = 1
    case permissionsAndModels = 2
    case liveSandbox = 3

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .welcomeInstall: return "安装输入法"
        case .enableInputSource: return "开通输入源"
        case .permissionsAndModels: return "权限与模型"
        case .liveSandbox: return "试打验收"
        }
    }

    public var iconName: String {
        switch self {
        case .welcomeInstall: return "arrow.down.app.fill"
        case .enableInputSource: return "keyboard.fill"
        case .permissionsAndModels: return "cpu.fill"
        case .liveSandbox: return "checkmark.seal.fill"
        }
    }
}

@MainActor
public final class SetupViewModel: ObservableObject {
    @Published public var activeTab: SetupTab = .onboarding
    @Published public var step: OnboardingStep = .welcomeInstall

    @Published public var preferences: SmartPinyinPreferences = SmartPinyinPreferencesStore.load() {
        didSet {
            guard !isSyncingPreferences, preferences != oldValue else { return }
            SmartPinyinPreferencesStore.save(preferences)
            preferencesSavedHint = "已保存并实时生效"
        }
    }
    @Published public var preferencesSavedHint: String?
    @Published public var memorySummary: UserMemorySummary = UserMemoryInspector.inspect()
    @Published public var showClearMemoryConfirm: Bool = false

    @Published public var installScope: InstallScope = .allUsers
    @Published public var isBusy: Bool = false
    @Published public var progressMessage: String = ""
    @Published public var errorMessage: String?
    @Published public var infoBanner: String?

    @Published public var hasEmbeddedPayload: Bool = false
    @Published public var installedBundlePath: String?
    @Published public var inputSourceStatus: InputSourceStatus = .init(
        isRegistered: false, isEnabled: false, isSelected: false, matchedSourceIDs: []
    )
    @Published public var isAccessibilityTrusted: Bool = false

    @Published public var modelItems: [ModelInspectionItem] = []
    @Published public var downloadingModelID: String?
    @Published public var downloadProgress: Double = 0
    @Published public var downloadDetailText: String = ""

    @Published public var lexiconItems: [LexiconPackStatus] = []
    @Published public var isCheckingLexiconUpdates: Bool = false
    @Published public var hasAutoCheckedLexiconUpdates: Bool = false
    @Published public var busyLexiconPackID: String?
    @Published public var lexiconProgress: Double = 0
    @Published public var lexiconStatusText: String = ""
    @Published public var lexiconBanner: String?
    @Published public var lexiconError: String?

    @Published public var diskUsage: DiskUsageReport?
    @Published public var uninstallOptions = UninstallOptions()
    @Published public var showUninstallConfirm = false
    @Published public var uninstallCompleted = false
    @Published public var sandboxText: String = ""

    private let engine = InstallerEngine()
    private let provisioner = ModelProvisioner()
    private let lexiconManager = LexiconManager()
    private var lexiconUpdatesByID: [String: LexiconUpdateInfo] = [:]
    private var pollTimer: Timer?
    private var activeDownloadTask: Task<Void, Never>?
    private var isProbingAccessibility = false
    private var isSyncingPreferences = false
    private var notificationObservers: [NSObjectProtocol] = []

    public var hasMultipleInstalledCopies: Bool {
        (diskUsage?.installedAppPaths.count ?? 0) > 1
    }

    public init(arguments: [String] = CommandLine.arguments) {
        self.hasEmbeddedPayload = (InstallerEngine.locateEmbeddedPayload() != nil)
        refreshAllState()

        if arguments.contains("--uninstall") {
            activeTab = .uninstall
        } else if arguments.contains("--lexicon") || arguments.contains("--dictionaries") {
            activeTab = .lexicon
        } else if arguments.contains("--preferences") || arguments.contains("--settings") {
            activeTab = .preferences
        } else if arguments.contains("--status") {
            activeTab = .status
        } else if arguments.contains("--post-pkg") {
            activeTab = .onboarding
            step = .enableInputSource
            autoRegisterAndEnableIfInstalled()
        } else if !hasEmbeddedPayload && installedBundlePath != nil {
            // 从已安装的 Helpers / Applications 打开时默认进入「常用配置」
            activeTab = .preferences
        } else {
            activeTab = .onboarding
            step = .welcomeInstall
        }

        setupInstantRefreshObservers()
        startStatusPolling()
    }

    public func resetPreferencesToDefaults() {
        preferences = .default
        preferencesSavedHint = "已恢复默认配置并实时生效"
    }

    public func refreshMemorySummary() {
        memorySummary = UserMemoryInspector.inspect()
    }

    public func clearLocalMemory() {
        UserMemoryInspector.resetAll(postNotification: true)
        UserMemoryInspector.clearWorkingMemory()
        memorySummary = UserMemoryInspector.inspect()
        preferencesSavedHint = "已清空本地偏好记忆、短期工作记忆与自适应排序权重"
    }

    public func clearWorkingMemoryOnly() {
        UserMemoryInspector.clearWorkingMemory()
        preferencesSavedHint = "已清空本次会话的近期输入工作记忆（长期个人词库保留）"
    }

    deinit {
        pollTimer?.invalidate()
        for obs in notificationObservers {
            NotificationCenter.default.removeObserver(obs)
            DistributedNotificationCenter.default().removeObserver(obs)
        }
    }

    public func refreshAllState() {
        let usage = engine.inspectDiskUsage()
        diskUsage = usage
        installedBundlePath = usage.installedAppPaths.first?.path
        inputSourceStatus = InputSourceManager.currentStatus()
        modelItems = provisioner.inspectAll()
        lexiconItems = lexiconManager.inspectAll(updatesByID: lexiconUpdatesByID)
        memorySummary = UserMemoryInspector.inspect()
        refreshAccessibilityAsync()
    }

    public func refreshAccessibilityAsync() {
        guard !isProbingAccessibility else { return }
        isProbingAccessibility = true
        let installedURL = diskUsage?.installedAppPaths.first
        Task.detached(priority: .userInitiated) {
            let trusted = PermissionChecker.isAccessibilityTrusted(installedAppURL: installedURL)
            await MainActor.run { [weak self] in
                self?.isAccessibilityTrusted = trusted
                self?.isProbingAccessibility = false
            }
        }
    }

    private func setupInstantRefreshObservers() {
        // 1. 监听 macOS 辅助功能权限实时变更分布式通知
        let axObs = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                self?.refreshAccessibilityAsync()
            }
        }
        notificationObservers.append(axObs)

        // 2. 用户从「系统设置」切回引导窗口的瞬间立即刷新全部权限与输入源状态
        let activeObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllState()
            }
        }
        notificationObservers.append(activeObs)

        // 3. 同步状态栏菜单中修改的偏好设置
        let prefObs = DistributedNotificationCenter.default().addObserver(
            forName: SmartPinyinPreferencesStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let latest = SmartPinyinPreferencesStore.load()
                if latest != self.preferences {
                    self.isSyncingPreferences = true
                    self.preferences = latest
                    self.isSyncingPreferences = false
                }
            }
        }
        notificationObservers.append(prefObs)

        // 4. 若设置中心已打开，支持从状态栏菜单直达对应标签页并前置窗口
        let tabObs = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("\(SmartPinyinIdentifiers.appBundleID).openSetupTab"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let tabKey = note.object as? String
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch tabKey {
                case "preferences": self.activeTab = .preferences
                case "lexicon": self.activeTab = .lexicon
                case "status": self.activeTab = .status
                case "uninstall": self.activeTab = .uninstall
                case "onboarding": self.activeTab = .onboarding
                default: break
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        notificationObservers.append(tabObs)
    }

    public var isAllModelsReady: Bool {
        !modelItems.isEmpty && modelItems.allSatisfy {
            if case .ready = $0.availability { return true }
            return false
        }
    }

    public func isStepCompleted(_ targetStep: OnboardingStep) -> Bool {
        switch targetStep {
        case .welcomeInstall:
            return installedBundlePath != nil
        case .enableInputSource:
            return inputSourceStatus.isEnabled
        case .permissionsAndModels:
            return isAllModelsReady
        case .liveSandbox:
            return !sandboxText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public func navigateToStep(_ targetStep: OnboardingStep) {
        if targetStep != .welcomeInstall && installedBundlePath == nil {
            errorMessage = "请先点击「安装并继续」完成第 1 步安装。"
            step = .welcomeInstall
            return
        }
        errorMessage = nil
        step = targetStep
    }

    // MARK: - Step 1: 安装部署

    public func performInstall() {
        guard let payloadURL = InstallerEngine.locateEmbeddedPayload() else {
            errorMessage = "当前运行包未内嵌 SmartPinyin.app 载荷，请通过完整安装包（.dmg/.pkg）运行安装。"
            return
        }
        errorMessage = nil
        infoBanner = nil
        isBusy = true
        progressMessage = "准备安装 SmartPinyin…"

        // 优先把未携带载荷的精简版 Setup App 拷贝到 Applications，若在 DMG 里运行则拷贝载荷中内置的 Helpers/SmartPinyinSetup.app
        let helperInPayload = payloadURL.appendingPathComponent("Contents/Helpers/SmartPinyinSetup.app")
        let setupToCopy = FileManager.default.fileExists(atPath: helperInPayload.path) ? helperInPayload : nil
        let bundledModels = Bundle.main.resourceURL?.appendingPathComponent("Models")
        let chosenScope = installScope

        Task.detached(priority: .userInitiated) { [engine] in
            do {
                let installedURL = try engine.install(
                    payloadAppURL: payloadURL,
                    scope: chosenScope,
                    setupAppBundleURL: setupToCopy,
                    bundledModelsDir: bundledModels
                ) { progress in
                    Task { @MainActor [weak self] in
                        self?.progressMessage = "[\(progress.step)/\(progress.totalSteps)] \(progress.message)"
                    }
                }
                await MainActor.run {
                    self.isBusy = false
                    self.progressMessage = ""
                    self.infoBanner = "已安装至 \(installedURL.path)"
                    self.refreshAllState()
                    self.step = .enableInputSource
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.progressMessage = ""
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Step 2: 注册并启用输入源

    public func autoRegisterAndEnableIfInstalled() {
        guard let path = diskUsage?.installedAppPaths.first ?? engine.inspectDiskUsage().installedAppPaths.first else {
            errorMessage = "尚未检测到已安装的 SmartPinyin.app，请先完成第 1 步安装。"
            return
        }
        errorMessage = nil
        infoBanner = "正在向系统注册并启用 SmartPinyin 输入源…"
        Task { @MainActor [weak self] in
            let status = await InputSourceManager.registerAndEnableAsync(bundleURL: path)
            InputSourceManager.refreshSystemInputMenu()
            guard let self else { return }
            self.inputSourceStatus = status
            if status.isEnabled {
                self.infoBanner = "SmartPinyin 输入源已成功注册并启用！"
            } else {
                self.infoBanner = "已向系统注册输入法。如系统未自动勾选，请点击下方按钮在「键盘 → 输入源」中点击「+」添加 SmartPinyin。"
            }
        }
    }

    public func openKeyboardInputSourcesSettings() {
        PermissionChecker.openSystemSettings(.keyboardInputSources)
    }

    // MARK: - Step 3: 权限与本地模型

    public func requestAccessibilityPermission() {
        let installedURL = diskUsage?.installedAppPaths.first
        Task.detached(priority: .userInitiated) {
            let trusted = PermissionChecker.requestAccessibilityPermission(installedAppURL: installedURL)
            await MainActor.run { [weak self] in
                self?.isAccessibilityTrusted = trusted
            }
        }
    }

    public func openAccessibilitySettings() {
        PermissionChecker.openSystemSettings(.accessibility)
    }

    public func importDiscoveredModel(_ item: ModelInspectionItem) {
        guard case .discoverable(let src, _) = item.availability else { return }
        importModelFile(src, for: item.spec)
    }

    public func pickAndImportLocalModel(for spec: LocalModelSpec) {
        let panel = NSOpenPanel()
        panel.title = "选择本地 \(spec.filename)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let ggufType = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [ggufType, .data]
        }
        if panel.runModal() == .OK, let url = panel.url {
            importModelFile(url, for: spec)
        }
    }

    private func importModelFile(_ url: URL, for spec: LocalModelSpec) {
        errorMessage = nil
        isBusy = true
        progressMessage = "正在校验并导入 \(spec.displayName)…"
        Task.detached(priority: .userInitiated) { [provisioner] in
            do {
                let dest = try provisioner.importModel(from: url, for: spec, preferSymlink: false)
                await MainActor.run {
                    self.isBusy = false
                    self.progressMessage = ""
                    self.infoBanner = "模型已导入至 \(dest.lastPathComponent)"
                    self.refreshAllState()
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.progressMessage = ""
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func downloadModel(_ spec: LocalModelSpec) {
        guard downloadingModelID == nil else { return }
        errorMessage = nil
        infoBanner = nil
        downloadingModelID = spec.id
        downloadProgress = 0
        downloadDetailText = "连接下载源…"

        activeDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await provisioner.downloadModel(spec) { fraction, written, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloadingModelID == spec.id else { return }
                        self.downloadProgress = fraction
                        let w = InstallerEngine.formatBytes(written)
                        let t = total > 0 ? InstallerEngine.formatBytes(total) : "\(spec.expectedSizeMB) MB"
                        self.downloadDetailText = "\(w) / \(t) (\(Int(fraction * 100))%)"
                    }
                }
                self.activeDownloadTask = nil
                self.downloadingModelID = nil
                self.downloadDetailText = ""
                self.infoBanner = "\(spec.displayName) 已下载并通过 GGUF 完整性校验，无需重启即可生效。"
                self.refreshAllState()
            } catch is CancellationError {
                self.activeDownloadTask = nil
                self.downloadingModelID = nil
                self.downloadProgress = 0
                self.downloadDetailText = ""
                self.infoBanner = "已取消 \(spec.displayName) 下载。"
            } catch {
                self.activeDownloadTask = nil
                self.downloadingModelID = nil
                self.downloadDetailText = ""
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func cancelModelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
    }

    // MARK: - 词库动态管理与场景优先级

    public func refreshLexicons() {
        lexiconItems = lexiconManager.inspectAll(updatesByID: lexiconUpdatesByID)
    }

    public func resetScenePriorityMultipliers() {
        preferences.scenePriorityMultipliers = [:]
        preferencesSavedHint = "已重置各场景词库优先级倍率为标准 (1.0×)"
    }

    public func checkLexiconUpdates() {
        guard !isCheckingLexiconUpdates else { return }
        isCheckingLexiconUpdates = true
        lexiconError = nil
        lexiconBanner = nil
        Task {
            let updates = await lexiconManager.checkForUpdates()
            self.lexiconUpdatesByID = updates
            self.isCheckingLexiconUpdates = false
            self.refreshLexicons()
            let availableCount = updates.values.filter(\.hasUpdate).count
            if availableCount > 0 {
                self.lexiconBanner = "检测到 \(availableCount) 个开源词库有新版本，可点击一键热更新。"
            } else if !updates.isEmpty {
                self.lexiconBanner = "已同步最新开源发布元数据（共检测 \(updates.count) 个更新源）。"
            } else {
                self.lexiconBanner = "当前网络无法访问 GitHub 发布元数据，离线词库不受影响。"
            }
        }
    }

    public func installOrUpdateLexicon(_ item: LexiconPackStatus) {
        guard busyLexiconPackID == nil else { return }
        busyLexiconPackID = item.spec.id
        lexiconProgress = 0.05
        lexiconStatusText = "准备拉取 \(item.spec.displayName)…"
        lexiconError = nil
        lexiconBanner = nil
        let resolvedURL = item.updateInfo?.downloadURL
        let resolvedVer = item.updateInfo?.latestVersion

        Task {
            do {
                let rec = try await lexiconManager.installOrUpdate(
                    spec: item.spec,
                    resolvedDownloadURL: resolvedURL,
                    versionLabel: resolvedVer
                ) { frac, msg in
                    Task { @MainActor [weak self] in
                        self?.lexiconProgress = frac
                        self?.lexiconStatusText = msg
                    }
                }
                self.busyLexiconPackID = nil
                self.lexiconStatusText = ""
                self.lexiconBanner = "「\(rec.displayName)」已安装并通知输入法后台热重载（\(rec.entryCount) 条）。"
                self.refreshLexicons()
            } catch {
                self.busyLexiconPackID = nil
                self.lexiconStatusText = ""
                self.lexiconError = error.localizedDescription
            }
        }
    }

    public func toggleLexiconEnabled(_ item: LexiconPackStatus, enabled: Bool) {
        lexiconError = nil
        do {
            try lexiconManager.setPackEnabled(id: item.spec.id, enabled: enabled)
            lexiconBanner = "已\(enabled ? "启用" : "停用")「\(item.spec.displayName)」，输入法正在后台热重载。"
            refreshLexicons()
        } catch {
            lexiconError = error.localizedDescription
        }
    }

    public func updateLexiconDomain(_ item: LexiconPackStatus, domain: InputSceneDomain) {
        lexiconError = nil
        do {
            try lexiconManager.updatePackDomain(id: item.spec.id, domain: domain)
            lexiconBanner = "已将「\(item.spec.displayName)」归属场景调整为「\(domain.displayName)」（0ms 生效）。"
            refreshLexicons()
        } catch {
            lexiconError = error.localizedDescription
        }
    }

    public func removeLexicon(_ item: LexiconPackStatus) {
        lexiconError = nil
        do {
            try lexiconManager.removePack(id: item.spec.id)
            lexiconBanner = "已移除词库「\(item.spec.displayName)」并触发热重载。"
            refreshLexicons()
        } catch {
            lexiconError = error.localizedDescription
        }
    }

    public func pickAndImportCustomLexicon(domain: InputSceneDomain) {
        let panel = NSOpenPanel()
        panel.title = "选择本地词库文件（.dict.yaml 或每行一词的 .txt）"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var allowed: [UTType] = [.plainText, .data]
        if let yamlType = UTType(filenameExtension: "yaml") {
            allowed.insert(yamlType, at: 0)
        }
        panel.allowedContentTypes = allowed
        guard panel.runModal() == .OK, let url = panel.url else { return }

        busyLexiconPackID = "custom-import"
        lexiconProgress = 0.25
        lexiconStatusText = "正在解析并注音导入 \(url.lastPathComponent)…"
        lexiconError = nil
        lexiconBanner = nil
        let name = url.deletingPathExtension().lastPathComponent

        Task.detached(priority: .userInitiated) { [lexiconManager] in
            do {
                let rec = try lexiconManager.importCustomDictionary(from: url, displayName: name, domain: domain)
                await MainActor.run {
                    self.busyLexiconPackID = nil
                    self.lexiconStatusText = ""
                    self.lexiconBanner = "自定义词库「\(rec.displayName)」已导入（\(rec.entryCount) 条，归属「\(domain.displayName)」）并触发热重载。"
                    self.refreshLexicons()
                }
            } catch {
                await MainActor.run {
                    self.busyLexiconPackID = nil
                    self.lexiconStatusText = ""
                    self.lexiconError = error.localizedDescription
                }
            }
        }
    }

    public func openLexiconFolderInFinder() {
        try? FileManager.default.createDirectory(at: lexiconManager.rimeDictsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([lexiconManager.rimeDictsDirectory])
    }

    // MARK: - 卸载自己 (6 步零残留流水线)

    public func executeSelfUninstall() {
        errorMessage = nil
        infoBanner = nil
        isBusy = true
        progressMessage = "正在执行安全卸载…"
        let opts = uninstallOptions
        let currentURL = Bundle.main.bundleURL

        Task.detached(priority: .userInitiated) { [engine] in
            do {
                let result = try engine.uninstall(
                    options: opts,
                    currentProcessBundleURL: currentURL,
                    launchDeferredScript: true
                ) { progress in
                    Task { @MainActor [weak self] in
                        self?.progressMessage = "[\(progress.step)/\(progress.totalSteps)] \(progress.message)"
                    }
                }
                await MainActor.run {
                    self.isBusy = false
                    self.progressMessage = ""
                    self.uninstallCompleted = true
                    self.refreshAllState()
                    if result.shouldTerminateAfterUninstall {
                        self.infoBanner = "SmartPinyin 及系统组件已移除，2 秒后自动退出卸载器。"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            NSApplication.shared.terminate(nil)
                        }
                    } else {
                        self.infoBanner = "SmartPinyin 已彻底从系统移除，无输入源残留。"
                    }
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.progressMessage = ""
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func startStatusPolling() {
        pollTimer?.invalidate()
        // 仅在输入源开通/权限体检页且窗口活跃时低频轮询；其余时刻由 com.apple.accessibility.api 与 didBecomeActive 即时驱动，避免空转频繁 spawn 子进程
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isBusy,
                      !self.uninstallCompleted,
                      NSApp.isActive
                else { return }
                let needsInputSourcePoll = (self.activeTab == .onboarding && self.step == .enableInputSource)
                    || (self.activeTab == .status && !self.inputSourceStatus.isEnabled)
                let needsAccessibilityPoll = !self.isAccessibilityTrusted && (
                    (self.activeTab == .onboarding && self.step == .permissionsAndModels)
                        || self.activeTab == .status
                )
                if needsInputSourcePoll {
                    self.inputSourceStatus = InputSourceManager.currentStatus()
                }
                if needsAccessibilityPoll {
                    self.refreshAccessibilityAsync()
                }
            }
        }
    }
}
