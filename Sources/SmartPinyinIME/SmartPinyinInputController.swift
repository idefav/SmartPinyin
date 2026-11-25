import AppKit
import Carbon
import InputMethodKit
import PinyinEngineCore
import SharedIPC
import SmartPinyinCore

/// 单个输入会话的控制器，负责桥接 macOS IMK 事件、同步 L1 引擎 + 本地自进化偏好记忆 + 文本框上下文检索 + 异步 XPC 神经增强。
@objc(SmartPinyinInputController)
public final class SmartPinyinInputController: IMKInputController {
    private static let sharedEngine: RimeEngineAdapter = {
        let bundleDataURL = Bundle.main.resourceURL?.appendingPathComponent("RimeData")
        return RimeEngineAdapter(
            bundledDataDirectory: bundleDataURL,
            initialPreferences: SmartPinyinPreferencesStore.load()
        )
    }()

    private static let sharedMemoryStore = UserMemoryStore()
    private static let sharedDocumentIndex = DocumentContextIndex()
    private static let sharedDocumentReader = DocumentContextReader()
    private static let sharedWorkingMemory = SessionWorkingMemory()
    private static let sharedTagStore = DomainAndLiteraryTagStore.loadBundled()
    private static let sharedEnglishLexicon = EnglishLexiconStore.loadBundled(
        rimeDataDirectory: Bundle.main.resourceURL?.appendingPathComponent("RimeData")
    )
    private static let lexiconReloadQueue = DispatchQueue(label: "com.smartpinyin.lexiconReload", qos: .userInitiated)
    /// 进程内共享的「英文直出模式」开关：短按 Shift 切换后，在应用内切换输入框/窗格不会意外回弹为中文
    private static var isGlobalDirectEnglish = false

    private var currentPreferences: SmartPinyinPreferences = SmartPinyinPreferencesStore.load()
    private lazy var stateMachine = InputStateMachine(
        engine: Self.sharedEngine,
        preferences: currentPreferences,
        memoryStore: Self.sharedMemoryStore,
        documentIndex: Self.sharedDocumentIndex,
        workingMemory: Self.sharedWorkingMemory,
        tagStore: Self.sharedTagStore,
        englishLexicon: Self.sharedEnglishLexicon
    )
    private let contextTracker = ContextTracker(maxLength: 2000)
    private let proofreadValidator = DraftProofreadEngine()

    private var isActiveSession = false
    private var pendingShiftDownTime: CFAbsoluteTime?
    private var pendingOptionKeyCode: UInt16?
    private var pendingOptionDownTime: CFAbsoluteTime?
    private var lastOptionTapTime: CFAbsoluteTime = 0
    private var lastOptionTapKeyCode: UInt16 = 0
    private var translateModeBeforeRightOptionTap: Bool?
    private var lastLanguageSwitchTime: CFAbsoluteTime = 0
    private var isCommittingTranslation = false
    private var commitTranslationStartedAt: CFAbsoluteTime = 0
    private var nextAsyncCommitToken: UInt64 = 0
    private var activeAsyncCommitToken: UInt64?
    private var pendingAsyncCommitFallback: (text: String, client: IMKTextInput)?
    private var bufferedEventsDuringCommit: [NormalizedKeyEvent] = []
    private var commitTranslationTask: Task<Void, Never>?
    private var modeToastHideTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var proofreadDebounceTask: Task<Void, Never>?
    private var predictionTask: Task<Void, Never>?
    private var predictionAutoHideTask: Task<Void, Never>?
    private var mouseDownMonitor: Any?
    private var preferencesObserver: NSObjectProtocol?
    private var memoryResetObserver: NSObjectProtocol?
    private var workingMemoryClearObserver: NSObjectProtocol?
    private var lexiconChangeObserver: NSObjectProtocol?
    private var lastValidAnchorRect: NSRect?

    private var ownerID: ObjectIdentifier { ObjectIdentifier(self) }

    /// 在主线程上同步执行 UI 更新，彻底消除异步 Task 乱序导致新候选窗被旧 hide() 覆盖的问题
    private func performOnMainSync(_ work: @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated(work)
            }
        }
    }

    /// 对复杂 pre-edit 支持不佳的终端应用，避免发送复杂富文本属性
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "dev.warp.Warp-Stable"
    ]

    public override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        installObservers()
    }

    deinit {
        if let obs = preferencesObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        if let obs = memoryResetObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        if let obs = workingMemoryClearObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        if let obs = lexiconChangeObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
    }

    private func installObservers() {
        let initial = SmartPinyinPreferencesStore.load()
        currentPreferences = initial
        performOnMainSync {
            CandidatePanelController.shared.candidateFontSize = CGFloat(initial.candidateFontSize)
            CandidatePanelController.shared.showSourceBadges = initial.showCandidateSourceBadges
            CandidatePanelController.shared.showLiteraryBadges = initial.showLiteraryBadges
            CandidatePanelController.shared.showDomainBadges = initial.showDomainBadges
            if initial.defaultTranslateMode {
                InferenceXPCClient.shared.prewarmTranslation()
            }
        }
        preferencesObserver = DistributedNotificationCenter.default().addObserver(
            forName: SmartPinyinPreferencesStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadPreferences()
        }
        memoryResetObserver = DistributedNotificationCenter.default().addObserver(
            forName: UserMemoryStore.didResetNotification,
            object: nil,
            queue: .main
        ) { _ in
            Self.sharedMemoryStore.reloadFromDisk()
            Self.sharedWorkingMemory.clear()
        }
        workingMemoryClearObserver = DistributedNotificationCenter.default().addObserver(
            forName: SessionWorkingMemory.didClearNotification,
            object: nil,
            queue: .main
        ) { _ in
            Self.sharedWorkingMemory.clear()
        }
        lexiconChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: SmartPinyinPreferencesStore.lexiconDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Self.sharedTagStore.reloadUserSidecarTags()
            self.stateMachine.reloadTagStoreAndScene()
            let prefs = SmartPinyinPreferencesStore.load()
            Self.lexiconReloadQueue.async {
                _ = Self.sharedEngine.reloadUserDictionaries(preferences: prefs)
            }
        }
    }

    private func reloadPreferences() {
        let previousTranslate = currentPreferences.defaultTranslateMode
        let updated = SmartPinyinPreferencesStore.load()
        currentPreferences = updated
        Self.sharedEngine.applyPreferences(updated)
        stateMachine.applyPreferences(updated)
        performOnMainSync {
            CandidatePanelController.shared.candidateFontSize = CGFloat(updated.candidateFontSize)
            CandidatePanelController.shared.showSourceBadges = updated.showCandidateSourceBadges
            CandidatePanelController.shared.showLiteraryBadges = updated.showLiteraryBadges
            CandidatePanelController.shared.showDomainBadges = updated.showDomainBadges
            if !updated.enableContinuationPrediction && CandidatePanelController.shared.isShowingPredictionsOnly {
                CandidatePanelController.shared.hide(ownerID: self.ownerID)
            }
            if updated.defaultTranslateMode && !previousTranslate {
                InferenceXPCClient.shared.prewarmTranslation()
            }
        }
    }

    public override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        isActiveSession = true
        pendingShiftDownTime = nil
        pendingOptionDownTime = nil
        pendingOptionKeyCode = nil
        lastOptionTapTime = 0
        translateModeBeforeRightOptionTap = nil
        activeAsyncCommitToken = nil
        pendingAsyncCommitFallback = nil
        isCommittingTranslation = false
        commitTranslationStartedAt = 0
        bufferedEventsDuringCommit.removeAll()
        commitTranslationTask?.cancel()
        commitTranslationTask = nil
        modeToastHideTask?.cancel()
        lastValidAnchorRect = nil
        reloadPreferences()
        stateMachine.syncDirectEnglishState(Self.isGlobalDirectEnglish)
        let client = sender as? IMKTextInput
        let clientID = client?.bundleIdentifier() ?? "unknown"
        let secure = IsSecureEventInputEnabled()
        Self.diagLog("activate app=\(clientID) mode=\(stateMachine.mode) secure=\(secure)")
        contextTracker.switchClient(identifier: clientID)
        Self.sharedDocumentReader.invalidateCachedLeftTail()

        if let client {
            syncRuntimeContext(client: client, isSecureInput: secure)
            refreshDocumentContext(client: client, isSecureInput: secure, forceAX: true)
        }

        let myOwner = ownerID
        performOnMainSync {
            CandidatePanelController.shared.claimOwnership(ownerID: myOwner)
            CandidatePanelController.shared.onSelectCandidate = { [weak self] idx in
                guard let self, let client = self.client() else { return }
                self.syncRuntimeContext(client: client, isSecureInput: IsSecureEventInputEnabled())
                let actions = self.stateMachine.selectCandidate(at: idx)
                self.execute(actions: actions, client: client)
            }
            CandidatePanelController.shared.onToggleTranslateMode = { [weak self] in
                guard let self, let client = self.client() else { return }
                let actions = self.stateMachine.toggleTranslateFromPanelBadge()
                self.execute(actions: actions, client: client)
            }
            CandidatePanelController.shared.onToggleGlobalTranslateScope = { [weak self] in
                guard let self, let client = self.client() else { return }
                let actions = self.stateMachine.toggleGlobalTranslateFromBar()
                self.execute(actions: actions, client: client)
            }
            CandidatePanelController.shared.onToggleLanguagePicker = { [weak self] in
                guard let self, let client = self.client() else { return }
                let actions = self.stateMachine.toggleLanguagePicker()
                self.execute(actions: actions, client: client)
            }
            CandidatePanelController.shared.onSelectTargetLanguage = { [weak self] lang in
                guard let self, let client = self.client() else { return }
                let actions = self.stateMachine.selectTargetLanguageFromPicker(lang)
                self.execute(actions: actions, client: client)
            }
            CandidatePanelController.shared.onCycleTargetLanguage = { [weak self] in
                guard let self else { return }
                var updated = SmartPinyinPreferencesStore.load()
                updated.defaultTargetLanguage = self.stateMachine.preferredTargetLanguage.next
                SmartPinyinPreferencesStore.save(updated)
                self.currentPreferences = updated
                self.stateMachine.applyPreferences(updated)
                self.lastLanguageSwitchTime = CFAbsoluteTimeGetCurrent()
                let actions = self.stateMachine.setTargetLanguage(updated.defaultTargetLanguage)
                Self.diagLog("panelCycleLang lang=\(updated.defaultTargetLanguage.rawValue)")
                if let client = self.client() {
                    self.execute(actions: actions, client: client)
                }
            }
            CandidatePanelController.shared.onCommitTranslation = { [weak self] in
                guard let self, let client = self.client() else { return }
                let actions = self.stateMachine.commitCurrentTranslation()
                self.execute(actions: actions, client: client)
            }
            CandidatePanelController.shared.onCommitOriginalChinese = { [weak self] in
                guard let self, let client = self.client() else { return }
                let actions = self.stateMachine.commitCurrentOriginalChinese()
                self.execute(actions: actions, client: client)
            }
            CandidatePanelController.shared.onToggleSingleCharMode = { [weak self] in
                guard let self, let client = self.client() else { return }
                let actions = self.stateMachine.toggleSingleCharMode()
                self.execute(actions: actions, client: client)
            }
            CandidatePanelController.shared.onToggleGlobalDraftScope = { [weak self] in
                guard let self, let client = self.client() else { return }
                let actions = self.stateMachine.toggleGlobalDraftScopeFromBar()
                self.execute(actions: actions, client: client)
            }
            CandidatePanelController.shared.onCommitDraftProofread = { [weak self] in
                guard let self, let client = self.client() else { return }
                let actions = self.stateMachine.commitCurrentDraftProofread()
                self.execute(actions: actions, client: client)
            }
            CandidatePanelController.shared.onCommitDraftOriginal = { [weak self] in
                guard let self, let client = self.client() else { return }
                let actions = self.stateMachine.commitCurrentDraftOriginal()
                self.execute(actions: actions, client: client)
            }
            CandidatePanelController.shared.onSelectPrediction = { [weak self] idx in
                guard let self, let client = self.client() else { return }
                self.predictionAutoHideTask?.cancel()
                let actions = self.stateMachine.acceptPrediction(at: idx)
                self.execute(actions: actions, client: client)
            }
            CandidatePanelController.shared.onClosePanel = { [weak self] in
                guard let self else { return }
                self.predictionAutoHideTask?.cancel()
                _ = self.stateMachine.dismissPredictions()
                CandidatePanelController.shared.hide(ownerID: self.ownerID)
            }
        }

        if mouseDownMonitor == nil {
            mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // 鼠标点击时清除 pendingShift 与 pendingOption，避免修饰键+点击误触发手势
                    self.pendingShiftDownTime = nil
                    self.pendingOptionDownTime = nil
                    self.pendingOptionKeyCode = nil
                    self.lastOptionTapTime = 0
                    self.translateModeBeforeRightOptionTap = nil
                    // 鼠标点击可能切换输入框或移动光标，标记需重新校准左文并延迟刷新 AX
                    self.contextTracker.markExternalEditOccurred()
                    Self.sharedDocumentReader.invalidateCachedLeftTail()
                    if let activeClient = self.client() {
                        let appID = activeClient.bundleIdentifier() ?? "unknown"
                        Self.sharedDocumentReader.schedulePostEditAXSync(
                            delayMs: 80,
                            appBundleID: appID,
                            isSecureInput: IsSecureEventInputEnabled(),
                            index: Self.sharedDocumentIndex
                        )
                    }
                    guard CandidatePanelController.shared.isOwner(self.ownerID) else { return }
                    if CandidatePanelController.shared.isShowingPredictionsOnly {
                        self.predictionAutoHideTask?.cancel()
                        _ = self.stateMachine.dismissPredictions()
                        CandidatePanelController.shared.hide(ownerID: self.ownerID)
                    }
                }
            }
        }
    }

    /// 异步收口（草稿 AI 纠偏 / 译文上屏）期间遭遇失焦、系统强制提交或熔断超时时，先将兜底文本落盘绝不丢字
    @discardableResult
    private func flushPendingAsyncCommitFallback(preferredClient: IMKTextInput?) -> Bool {
        guard let pending = pendingAsyncCommitFallback else { return false }
        activeAsyncCommitToken = nil
        pendingAsyncCommitFallback = nil
        isCommittingTranslation = false
        commitTranslationStartedAt = 0
        bufferedEventsDuringCommit.removeAll()
        commitTranslationTask?.cancel()
        commitTranslationTask = nil
        let targetClient = preferredClient ?? pending.client
        if !pending.text.isEmpty {
            stateMachine.recordAsyncCommittedText(pending.text)
            commitAtomically(text: pending.text, client: targetClient, requestPredictions: false)
        } else {
            clearMarkedText(client: targetClient)
        }
        return true
    }

    public override func deactivateServer(_ sender: Any!) {
        flushPendingAsyncCommitFallback(preferredClient: sender as? IMKTextInput)
        isActiveSession = false
        pendingShiftDownTime = nil
        pendingOptionDownTime = nil
        pendingOptionKeyCode = nil
        lastOptionTapTime = 0
        translateModeBeforeRightOptionTap = nil
        activeAsyncCommitToken = nil
        isCommittingTranslation = false
        commitTranslationStartedAt = 0
        pendingAsyncCommitFallback = nil
        bufferedEventsDuringCommit.removeAll()
        commitTranslationTask?.cancel()
        commitTranslationTask = nil
        modeToastHideTask?.cancel()
        debounceTask?.cancel()
        proofreadDebounceTask?.cancel()
        predictionTask?.cancel()
        predictionAutoHideTask?.cancel()
        Self.diagLog("deactivate")
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDownMonitor = nil
        }

        let myOwner = ownerID
        var stillOwner = false
        performOnMainSync {
            stillOwner = CandidatePanelController.shared.isOwner(myOwner)
        }
        guard stillOwner else {
            super.deactivateServer(sender)
            return
        }

        let actions = stateMachine.resetSession()
        if let client = sender as? IMKTextInput {
            clearMarkedText(client: client)
            execute(actions: actions, client: client)
        } else {
            performOnMainSync {
                InferenceXPCClient.shared.cancelAll(includeCommit: true)
                CandidatePanelController.shared.hide(ownerID: myOwner)
            }
        }
        super.deactivateServer(sender)
    }

    public override func commitComposition(_ sender: Any!) {
        let targetClient = sender as? IMKTextInput
        let flushedAsync = flushPendingAsyncCommitFallback(preferredClient: targetClient)
        activeAsyncCommitToken = nil
        isCommittingTranslation = false
        commitTranslationStartedAt = 0
        pendingAsyncCommitFallback = nil
        bufferedEventsDuringCommit.removeAll()
        commitTranslationTask?.cancel()
        commitTranslationTask = nil
        guard let client = targetClient else { return }
        if !flushedAsync {
            let actions = stateMachine.commitActiveCompositionOnSystemRequest()
            let didCommit = actions.contains {
                if case .commitText = $0 { return true }
                return false
            }
            execute(actions: actions, client: client)
            if !didCommit {
                clearMarkedText(client: client)
            }
        }
        let myOwner = ownerID
        performOnMainSync {
            CandidatePanelController.shared.hide(ownerID: myOwner)
        }
    }

    public override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    public override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }

        // 密码框/安全输入模式：完全透明交还系统，零记录零推理零读取
        if IsSecureEventInputEnabled() {
            Self.sharedDocumentIndex.clear()
            return false
        }

        if event.type == .flagsChanged {
            return handleFlagsChanged(event, client: client)
        }

        guard event.type == .keyDown else { return false }
        pendingShiftDownTime = nil
        pendingOptionDownTime = nil
        pendingOptionKeyCode = nil
        lastOptionTapTime = 0
        translateModeBeforeRightOptionTap = nil
        modeToastHideTask?.cancel()
        predictionTask?.cancel()
        predictionAutoHideTask?.cancel()
        let myOwner = ownerID
        performOnMainSync {
            CandidatePanelController.shared.claimOwnership(ownerID: myOwner)
        }

        guard let normalized = normalize(event: event) else { return false }

        // 若上一段译文正在异步落地（通常 ~100ms），暂存紧随其后的击键待上屏后再顺序重放；带 1.8s 熔断保护，绝不卡死输入
        if isCommittingTranslation {
            let elapsed = CFAbsoluteTimeGetCurrent() - commitTranslationStartedAt
            if elapsed > 1.8 {
                Self.diagLog("commitWatchdogReset elapsed=\(String(format: "%.2f", elapsed))s")
                if !flushPendingAsyncCommitFallback(preferredClient: client) {
                    activeAsyncCommitToken = nil
                    isCommittingTranslation = false
                    commitTranslationStartedAt = 0
                    bufferedEventsDuringCommit.removeAll()
                    commitTranslationTask?.cancel()
                    commitTranslationTask = nil
                    clearMarkedText(client: client)
                }
            } else if normalized.kind == .escape || isGlobalDisableTranslateShortcutEvent(normalized) {
                activeAsyncCommitToken = nil
                pendingAsyncCommitFallback = nil
                isCommittingTranslation = false
                commitTranslationStartedAt = 0
                bufferedEventsDuringCommit.removeAll()
                commitTranslationTask?.cancel()
                commitTranslationTask = nil
                clearMarkedText(client: client)
                performOnMainSync {
                    InferenceXPCClient.shared.cancelAll(includeCommit: true)
                    CandidatePanelController.shared.hide(ownerID: myOwner)
                }
                if isGlobalDisableTranslateShortcutEvent(normalized) {
                    let actions = stateMachine.disableGlobalTranslateMode()
                    execute(actions: actions, client: client)
                }
                return true
            } else if normalized.modifiers.contains(.command) || normalized.modifiers.contains(.control) {
                return false
            } else {
                if bufferedEventsDuringCommit.count < 16 {
                    bufferedEventsDuringCommit.append(normalized)
                }
                return true
            }
        }

        return processNormalizedEvent(normalized, client: client)
    }

    private func processNormalizedEvent(_ normalized: NormalizedKeyEvent, client: IMKTextInput) -> Bool {
        let myOwner = ownerID
        syncRuntimeContext(client: client, isSecureInput: false)
        let actions = stateMachine.handle(normalized)

        let nonPassThrough = actions.filter { $0 != .passThrough }
        if !nonPassThrough.isEmpty {
            execute(actions: nonPassThrough, client: client)
        }

        let passedThrough = actions.contains(.passThrough)
        Self.diagLog("key kind=\(Self.safeKindLabel(normalized.kind)) mode=\(stateMachine.mode) actions=\(actions.count) pass=\(passedThrough)")

        if passedThrough {
            if normalized.kind == .escape {
                predictionAutoHideTask?.cancel()
                performOnMainSync {
                    if CandidatePanelController.shared.isVisible {
                        CandidatePanelController.shared.hide(ownerID: myOwner)
                    }
                }
            }
            let appID = client.bundleIdentifier() ?? "unknown"
            let secure = IsSecureEventInputEnabled()

            if normalized.modifiers.contains(.command), case .character(let ch, _) = normalized.kind {
                let lower = ch.lowercased()
                if lower == "a" {
                    contextTracker.markSelectAll()
                } else if lower == "x" || lower == "v" || lower == "z" {
                    // 剪切/整段撤销前，将有效已输文本归档进短期工作记忆供后续排序与联想复用
                    if lower == "x", currentPreferences.enableWorkingMemory, !secure {
                        let retained = contextTracker.sessionText(isSecureInput: false)
                        if retained.count >= 3 {
                            Self.sharedWorkingMemory.finalizeCurrentSentence(
                                explicitText: retained,
                                appBundleID: appID,
                                isSecureInput: false
                            )
                        }
                    }
                    contextTracker.markExternalEditOccurred(clearBuffer: lower == "x")
                    Self.sharedDocumentReader.invalidateCachedLeftTail()
                    Self.sharedDocumentReader.schedulePostEditAXSync(
                        delayMs: 75,
                        appBundleID: appID,
                        isSecureInput: secure,
                        index: Self.sharedDocumentIndex
                    )
                }
            } else if normalized.kind == .backspace {
                let isBulkDelete = normalized.modifiers.contains(.option)
                    || normalized.modifiers.contains(.command)
                    || contextTracker.hasPendingSelectAll
                // 批量删词/删行/全选清空前，保留此前输入的有效词句进短期工作记忆（不与 4 秒误选单字退格纠错冲突）
                if isBulkDelete, currentPreferences.enableWorkingMemory, !secure {
                    let retained = contextTracker.sessionText(isSecureInput: false)
                    if retained.count >= 3 {
                        Self.sharedWorkingMemory.finalizeCurrentSentence(
                            explicitText: retained,
                            appBundleID: appID,
                            isSecureInput: false
                        )
                    }
                }
                contextTracker.handleBackspace(
                    isWordOrLineDelete: normalized.modifiers.contains(.option) || normalized.modifiers.contains(.command)
                )
                Self.sharedDocumentReader.invalidateCachedLeftTail()
                Self.sharedDocumentReader.schedulePostEditAXSync(
                    delayMs: 75,
                    appBundleID: appID,
                    isSecureInput: secure,
                    index: Self.sharedDocumentIndex
                )
            } else if normalized.kind == .arrowLeft || normalized.kind == .arrowRight
                        || normalized.kind == .arrowUp || normalized.kind == .arrowDown {
                contextTracker.markExternalEditOccurred()
                Self.sharedDocumentReader.invalidateCachedLeftTail()
                Self.sharedDocumentReader.schedulePostEditAXSync(
                    delayMs: 75,
                    appBundleID: appID,
                    isSecureInput: secure,
                    index: Self.sharedDocumentIndex
                )
            } else if normalized.kind == .returnKey {
                // 回车发送/换行前先把整句封存进短期工作记忆（受密码框与 SensitiveTextFilter 保护），再清空当前句精确左文！
                if currentPreferences.enableWorkingMemory, !secure {
                    let completed = contextTracker.sessionText(isSecureInput: false)
                    Self.sharedWorkingMemory.finalizeCurrentSentence(
                        explicitText: completed,
                        appBundleID: appID,
                        isSecureInput: false
                    )
                }
                contextTracker.clear()
                Self.sharedDocumentReader.invalidateCachedLeftTail()
            }
            return false
        }
        return true
    }

    // MARK: - 右上角状态栏输入法菜单与系统「打开 SmartPinyin 设置…」入口

    public override func showPreferences(_ sender: Any!) {
        launchEmbeddedSetupHelper(arguments: ["--preferences"])
    }

    public override func menu() -> NSMenu! {
        // 注意：macOS 在每次按键时都会高频调用 menu()，禁止在此做磁盘 I/O 或日志写入；
        // currentPreferences 已由 DistributedNotificationCenter 与所有菜单 handler 实时保持同步。
        let menu = NSMenu(title: "SmartPinyin")

        let isTranslate: Bool
        if case .translateOnCommit = stateMachine.mode {
            isTranslate = true
        } else {
            isTranslate = false
        }

        let spaceHint = currentPreferences.translateSpaceBehavior == .commitTranslation
            ? "空格上屏译文"
            : "回车上屏译文"
        let offBadge = currentPreferences.globalDisableTranslateShortcut.badge
        let offHint = offBadge.isEmpty ? "" : " · \(offBadge) 全局关闭"
        let toggleTranslateItem = NSMenuItem(
            title: isTranslate
                ? "✓ 翻译模式：中 → \(stateMachine.preferredTargetLanguage.shortBadge)（\(spaceHint)\(offHint)）"
                : "开启实时自动翻译模式（中 → \(stateMachine.preferredTargetLanguage.shortBadge)）",
            action: #selector(menuToggleTranslateMode(_:)),
            keyEquivalent: ""
        )
        toggleTranslateItem.target = self
        menu.addItem(toggleTranslateItem)

        let draftSpaceHint = currentPreferences.draftSpaceBehavior == .stageThenCommit
            ? "空格进草稿·再按空格上屏"
            : "回车上屏整句"
        let draftBadge = currentPreferences.draftModeToggleShortcut.badge
        let draftShortcutHint = draftBadge.isEmpty ? "" : " · \(draftBadge)"
        let toggleDraftItem = NSMenuItem(
            title: currentPreferences.defaultDraftProofreadMode
                ? "✓ 整句暂存与校对模式（\(draftSpaceHint)\(draftShortcutHint)）"
                : "开启整句暂存与校对模式\(draftBadge.isEmpty ? "" : "（\(draftBadge)）")",
            action: #selector(menuToggleDraftProofreadMode(_:)),
            keyEquivalent: ""
        )
        toggleDraftItem.target = self
        menu.addItem(toggleDraftItem)

        menu.addItem(.separator())

        // 关键约束：macOS InputMethodKit / TextInputMenuAgent 不会把嵌套 submenu 子项的点击事件路由回 IMKInputController，
        // 且跨进程会丢弃 representedObject；因此将 6 种目标语言直接平铺为一级菜单项并各绑定独立 selector，一键直达且 100% 生效！
        let langHeader = NSMenuItem(title: "翻译目标语言（点击切换）", action: nil, keyEquivalent: "")
        langHeader.isEnabled = false
        menu.addItem(langHeader)

        let langSelectors: [(TargetLanguage, Selector)] = [
            (.english, #selector(menuSelectLangEnglish(_:))),
            (.japanese, #selector(menuSelectLangJapanese(_:))),
            (.korean, #selector(menuSelectLangKorean(_:))),
            (.french, #selector(menuSelectLangFrench(_:))),
            (.german, #selector(menuSelectLangGerman(_:))),
            (.spanish, #selector(menuSelectLangSpanish(_:)))
        ]
        for (lang, sel) in langSelectors {
            let item = NSMenuItem(
                title: "\(lang.displayName) (\(lang.shortBadge))",
                action: sel,
                keyEquivalent: ""
            )
            item.target = self
            item.state = (lang == stateMachine.preferredTargetLanguage) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let directEnglishItem = NSMenuItem(
            title: "英文直出模式（短按 Shift 切换）",
            action: #selector(menuToggleDirectEnglish(_:)),
            keyEquivalent: ""
        )
        directEnglishItem.target = self
        directEnglishItem.state = (stateMachine.mode == .directEnglish) ? .on : .off
        menu.addItem(directEnglishItem)

        let autoCoding = !currentPreferences.codingModeEnabled && stateMachine.isEffectiveCodingMode
        let codingTitle = autoCoding
            ? "Coding 模式 · 英文标点（当前应用自动启用）"
            : "Coding 模式（中文输入默认英文标点）"
        let codingItem = NSMenuItem(
            title: codingTitle,
            action: #selector(menuToggleCodingMode(_:)),
            keyEquivalent: ""
        )
        codingItem.target = self
        codingItem.state = stateMachine.isEffectiveCodingMode ? .on : .off
        menu.addItem(codingItem)

        let zhPunctItem = NSMenuItem(
            title: "中文全角标点（，。！？）",
            action: #selector(menuToggleChinesePunctuation(_:)),
            keyEquivalent: ""
        )
        zhPunctItem.target = self
        zhPunctItem.state = currentPreferences.chinesePunctuation ? .on : .off
        menu.addItem(zhPunctItem)

        menu.addItem(.separator())

        let docAssistItem = NSMenuItem(
            title: "文本框上下文联动选词",
            action: #selector(menuToggleDocumentContext(_:)),
            keyEquivalent: ""
        )
        docAssistItem.target = self
        docAssistItem.state = currentPreferences.enableDocumentContextAssist ? .on : .off
        menu.addItem(docAssistItem)

        let memoryItem = NSMenuItem(
            title: "本地偏好记忆自进化排序",
            action: #selector(menuTogglePersonalMemory(_:)),
            keyEquivalent: ""
        )
        memoryItem.target = self
        memoryItem.state = currentPreferences.enablePersonalMemory ? .on : .off
        menu.addItem(memoryItem)

        let tradItem = NSMenuItem(
            title: "繁体中文输出",
            action: #selector(menuToggleTraditional(_:)),
            keyEquivalent: ""
        )
        tradItem.target = self
        tradItem.state = currentPreferences.traditionalChinese ? .on : .off
        menu.addItem(tradItem)

        let predictItem = NSMenuItem(
            title: "句末智能联想续写",
            action: #selector(menuTogglePrediction(_:)),
            keyEquivalent: ""
        )
        predictItem.target = self
        predictItem.state = currentPreferences.enableContinuationPrediction ? .on : .off
        menu.addItem(predictItem)

        // 场景词库优先级快切子菜单（自动适配 / 手动锁定游戏、数学、计算机、美术、科学等场景）
        let sceneMenu = NSMenu(title: "场景词库模式")
        let autoSceneItem = NSMenuItem(
            title: "自动智能适配（按应用与上下文）",
            action: #selector(menuSelectSceneDomain(_:)),
            keyEquivalent: ""
        )
        autoSceneItem.target = self
        autoSceneItem.representedObject = ""
        autoSceneItem.state = (currentPreferences.lockedSceneDomain == nil) ? .on : .off
        sceneMenu.addItem(autoSceneItem)
        sceneMenu.addItem(.separator())
        for domain in InputSceneDomain.specializedDomains {
            let item = NSMenuItem(
                title: "锁定：\(domain.displayName)",
                action: #selector(menuSelectSceneDomain(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = domain.rawValue
            item.state = (currentPreferences.lockedSceneDomain == domain) ? .on : .off
            sceneMenu.addItem(item)
        }
        let sceneMenuItem = NSMenuItem(title: "场景词库模式", action: nil, keyEquivalent: "")
        sceneMenuItem.submenu = sceneMenu
        menu.addItem(sceneMenuItem)

        menu.addItem(.separator())

        let prefsItem = NSMenuItem(
            title: "偏好设置（常用配置）…",
            action: #selector(menuOpenPreferences(_:)),
            keyEquivalent: ""
        )
        prefsItem.target = self
        menu.addItem(prefsItem)

        let lexiconItem = NSMenuItem(
            title: "词库与场景管理…",
            action: #selector(menuOpenLexiconManager(_:)),
            keyEquivalent: ""
        )
        lexiconItem.target = self
        menu.addItem(lexiconItem)

        let setupItem = NSMenuItem(
            title: "权限与本地模型状态…",
            action: #selector(menuOpenSetupCenter(_:)),
            keyEquivalent: ""
        )
        setupItem.target = self
        menu.addItem(setupItem)

        let uninstallItem = NSMenuItem(
            title: "卸载 SmartPinyin…",
            action: #selector(menuOpenUninstaller(_:)),
            keyEquivalent: ""
        )
        uninstallItem.target = self
        menu.addItem(uninstallItem)

        return menu
    }

    @objc public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        true
    }

    @objc private func menuToggleDirectEnglish(_ sender: Any?) {
        let nextDirectEnglish = (stateMachine.mode != .directEnglish)
        Self.isGlobalDirectEnglish = nextDirectEnglish
        let actions = stateMachine.setDirectEnglish(nextDirectEnglish)
        if let client = client() {
            execute(actions: actions, client: client)
            showBriefModeToast(client: client)
        }
        Self.diagLog("menuToggleDirectEnglish enabled=\(nextDirectEnglish)")
    }

    @objc private func menuToggleCodingMode(_ sender: Any?) {
        let nextCoding = !currentPreferences.codingModeEnabled
        applyPersistedPreferencesChange(
            translateMode: nil,
            targetLanguage: nil,
            codingMode: nextCoding,
            chinesePunctuation: nil,
            client: client(),
            showToast: true
        )
    }

    @objc private func menuToggleChinesePunctuation(_ sender: Any?) {
        let nextChinesePunct = !currentPreferences.chinesePunctuation
        applyPersistedPreferencesChange(
            translateMode: nil,
            targetLanguage: nil,
            codingMode: nil,
            chinesePunctuation: nextChinesePunct,
            client: client(),
            showToast: true
        )
    }

    @objc private func menuToggleTranslateMode(_ sender: Any?) {
        // 持久化全局翻译模式开关，跨窗口/切换 App 永不回落！
        var updated = SmartPinyinPreferencesStore.load()
        let willEnable = !updated.defaultTranslateMode
        updated.defaultTranslateMode = willEnable
        SmartPinyinPreferencesStore.save(updated)
        currentPreferences = updated
        Self.sharedEngine.applyPreferences(updated)
        if willEnable {
            Self.isGlobalDirectEnglish = false
        }
        stateMachine.applyPreferences(updated)
        let actions = stateMachine.setTranslateMode(enabled: willEnable)
        if willEnable {
            performOnMainSync {
                InferenceXPCClient.shared.prewarmTranslation()
            }
        }
        if let client = client() {
            if stateMachine.hasActiveComposition {
                execute(actions: actions, client: client)
            } else {
                showBriefModeToast(client: client)
            }
        }
        Self.diagLog("menuToggleTranslate enabled=\(willEnable) lang=\(updated.defaultTargetLanguage.rawValue)")
    }

    @objc private func menuToggleDraftProofreadMode(_ sender: Any?) {
        var updated = SmartPinyinPreferencesStore.load()
        let willEnable = !updated.defaultDraftProofreadMode
        updated.defaultDraftProofreadMode = willEnable
        if willEnable {
            updated.defaultTranslateMode = false
            Self.isGlobalDirectEnglish = false
        }
        SmartPinyinPreferencesStore.save(updated)
        currentPreferences = updated
        Self.sharedEngine.applyPreferences(updated)
        stateMachine.applyPreferences(updated)
        let actions = stateMachine.setDraftProofreadMode(enabled: willEnable)
        if let client = client() {
            if stateMachine.hasActiveComposition {
                execute(actions: actions, client: client)
            } else {
                let commitHint = updated.draftSpaceBehavior == .stageThenCommit
                    ? "␣ 进草稿 · 再按 ␣ 上屏"
                    : "␣ 拼句 · ⏎ 整体纠偏上屏"
                showBriefModeToast(
                    client: client,
                    customMessage: willEnable
                        ? "校 · 已开启整句暂存与校对模式（\(commitHint)）"
                        : "中 · 已关闭整句暂存模式（恢复即打即上屏）"
                )
            }
        }
        Self.diagLog("menuToggleDraft enabled=\(willEnable)")
    }

    @objc private func menuSelectLangEnglish(_ sender: Any?) { selectTargetLanguageFromMenu(.english) }
    @objc private func menuSelectLangJapanese(_ sender: Any?) { selectTargetLanguageFromMenu(.japanese) }
    @objc private func menuSelectLangKorean(_ sender: Any?) { selectTargetLanguageFromMenu(.korean) }
    @objc private func menuSelectLangFrench(_ sender: Any?) { selectTargetLanguageFromMenu(.french) }
    @objc private func menuSelectLangGerman(_ sender: Any?) { selectTargetLanguageFromMenu(.german) }
    @objc private func menuSelectLangSpanish(_ sender: Any?) { selectTargetLanguageFromMenu(.spanish) }

    private func selectTargetLanguageFromMenu(_ target: TargetLanguage) {
        var updated = SmartPinyinPreferencesStore.load()
        updated.defaultTargetLanguage = target
        SmartPinyinPreferencesStore.save(updated)
        currentPreferences = updated
        stateMachine.applyPreferences(updated)
        let actions = stateMachine.setTargetLanguage(target)
        if let client = client() {
            if stateMachine.hasActiveComposition {
                execute(actions: actions, client: client)
            } else {
                showBriefModeToast(
                    client: client,
                    customMessage: "中→\(target.shortBadge) · 翻译目标：\(target.displayName)"
                )
            }
        }
        Self.diagLog("menuSelectLang lang=\(target.rawValue)")
    }

    @objc private func menuToggleDocumentContext(_ sender: Any?) {
        var updated = SmartPinyinPreferencesStore.load()
        updated.enableDocumentContextAssist.toggle()
        SmartPinyinPreferencesStore.save(updated)
        reloadPreferences()
    }

    @objc private func menuTogglePersonalMemory(_ sender: Any?) {
        var updated = SmartPinyinPreferencesStore.load()
        updated.enablePersonalMemory.toggle()
        SmartPinyinPreferencesStore.save(updated)
        reloadPreferences()
    }

    @objc private func menuToggleTraditional(_ sender: Any?) {
        var updated = SmartPinyinPreferencesStore.load()
        updated.traditionalChinese.toggle()
        SmartPinyinPreferencesStore.save(updated)
        reloadPreferences()
    }

    @objc private func menuTogglePrediction(_ sender: Any?) {
        var updated = SmartPinyinPreferencesStore.load()
        updated.enableContinuationPrediction.toggle()
        SmartPinyinPreferencesStore.save(updated)
        reloadPreferences()
    }

    @objc private func menuOpenPreferences(_ sender: Any?) {
        launchEmbeddedSetupHelper(arguments: ["--preferences"], tabKey: "preferences")
    }

    @objc private func menuOpenLexiconManager(_ sender: Any?) {
        launchEmbeddedSetupHelper(arguments: ["--lexicon"], tabKey: "lexicon")
    }

    @objc private func menuSelectSceneDomain(_ sender: NSMenuItem) {
        let raw = (sender.representedObject as? String) ?? ""
        var updated = SmartPinyinPreferencesStore.load()
        if raw.isEmpty {
            updated.lockedSceneDomain = nil
            updated.enableSmartSceneAdaptation = true
        } else if let domain = InputSceneDomain(rawValue: raw) {
            updated.lockedSceneDomain = domain
        }
        SmartPinyinPreferencesStore.save(updated)
        reloadPreferences()
        if let client = client(), !stateMachine.hasActiveComposition {
            let msg = updated.lockedSceneDomain.map { "已锁定场景词库：\($0.displayName)" }
                ?? "已切换为自动智能场景适配"
            showBriefModeToast(client: client, customMessage: msg)
        }
    }

    @objc private func menuOpenSetupCenter(_ sender: Any?) {
        launchEmbeddedSetupHelper(arguments: ["--status"], tabKey: "status")
    }

    @objc private func menuOpenUninstaller(_ sender: Any?) {
        launchEmbeddedSetupHelper(arguments: ["--uninstall"], tabKey: "uninstall")
    }

    private func launchEmbeddedSetupHelper(arguments: [String], tabKey: String = "preferences") {
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications/SmartPinyin Setup.app"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/SmartPinyin Setup.app"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SmartPinyinSetup.app")
        ]
        guard let helperURL = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("\(SmartPinyinIdentifiers.appBundleID).openSetupTab"),
            object: tabKey,
            userInfo: nil,
            deliverImmediately: true
        )
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = arguments
        config.activates = true
        NSWorkspace.shared.openApplication(at: helperURL, configuration: config)
    }

    // MARK: - 动作执行器

    private func execute(actions: [InputAction], client: IMKTextInput) {
        for action in actions {
            switch action {
            case .passThrough:
                break

            case .cancelPendingInference:
                debounceTask?.cancel()
                proofreadDebounceTask?.cancel()
                performOnMainSync {
                    InferenceXPCClient.shared.cancelAll()
                }

            case .persistPreferencesChange(let translateMode, let targetLanguage, let codingMode, let chinesePunctuation):
                applyPersistedPreferencesChange(
                    translateMode: translateMode,
                    targetLanguage: targetLanguage,
                    codingMode: codingMode,
                    chinesePunctuation: chinesePunctuation,
                    client: client,
                    showToast: !stateMachine.hasActiveComposition,
                    syncStateMachine: false
                )

            case .persistDraftProofreadMode(let enabled):
                var updated = SmartPinyinPreferencesStore.load()
                updated.defaultDraftProofreadMode = enabled
                if enabled {
                    updated.defaultTranslateMode = false
                    Self.isGlobalDirectEnglish = false
                }
                SmartPinyinPreferencesStore.save(updated)
                currentPreferences = updated
                if !stateMachine.hasActiveComposition {
                    let commitHint = updated.draftSpaceBehavior == .stageThenCommit
                        ? "␣ 进草稿 · 再按 ␣ 上屏"
                        : "␣ 拼句 · ⏎ 整体纠偏上屏"
                    showBriefModeToast(
                        client: client,
                        customMessage: enabled
                            ? "校 · 已开启整句暂存与校对模式（\(commitHint)）"
                            : "中 · 已关闭整句暂存模式（恢复即打即上屏）"
                    )
                }
                Self.diagLog("persistDraftMode enabled=\(enabled)")

            case .updateUI(let snapshot):
                if snapshot.isVisible && !snapshot.preedit.isEmpty {
                    updateMarkedText(snapshot.preedit, client: client)
                } else {
                    clearMarkedText(client: client)
                }
                let anchor = cursorRect(for: client)
                let myOwner = ownerID
                performOnMainSync {
                    if snapshot.showTranslationBar && snapshot.candidates.isEmpty && snapshot.translationPreview == .hidden {
                        InferenceXPCClient.shared.prewarmTranslation()
                    }
                    CandidatePanelController.shared.update(
                        snapshot: snapshot,
                        anchorRect: anchor,
                        ownerID: myOwner
                    )
                }

            case .commitText(let text, let requestPredictions):
                commitAtomically(text: text, client: client, requestPredictions: requestPredictions)

            case .commitTranslation(let sourceText, let target, let cached):
                if let cached, !cached.isEmpty {
                    // 命中后台预翻译缓存：自动补齐词间空格后 0ms 瞬时上屏译文
                    let left = resolveLeftContext(client: client)
                    let formatted = TranslationSpacingHelper.formatForCommit(
                        translatedText: cached,
                        leftContext: left,
                        target: target,
                        autoSpaceEnabled: currentPreferences.autoSpaceTranslatedSegments
                    )
                    commitAtomically(text: formatted, client: client, requestPredictions: false)
                } else {
                    commitTranslationAsync(sourceText: sourceText, target: target, client: client)
                }

            case .commitDraftProofreadAsync(let rawDraft, let aiSourceText, let fallbackText, let requestPredictions):
                commitDraftProofreadAsync(
                    rawDraft: rawDraft,
                    aiSourceText: aiSourceText,
                    fallbackText: fallbackText,
                    requestPredictions: requestPredictions,
                    client: client
                )

            case .requestNeuralEnhancement(let token, let pinyin, let bestSentence, let candidates, let translationTarget):
                scheduleNeuralEnhancement(
                    token: token,
                    pinyin: pinyin,
                    bestSentence: bestSentence,
                    candidates: candidates,
                    translationTarget: translationTarget,
                    client: client
                )

            case .requestDraftProofread(let token, let draftText):
                scheduleDraftProofread(
                    token: token,
                    draftText: draftText,
                    client: client
                )
            }
        }
    }

    private func scheduleDraftProofread(
        token: UInt64,
        draftText: String,
        client: IMKTextInput
    ) {
        proofreadDebounceTask?.cancel()
        let leftContext = resolveLeftContext(client: client)
        proofreadDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, self.isActiveSession, self.stateMachine.sessionToken == token else { return }

            let reply = await InferenceXPCClient.shared.proofreadSentence(
                sourceText: draftText,
                leftContext: leftContext
            )
            guard !Task.isCancelled, self.isActiveSession, self.stateMachine.sessionToken == token else { return }

            if let uiAction = self.stateMachine.applyDraftProofreadResult(
                reply,
                forSourceText: draftText,
                forToken: token
            ) {
                self.execute(actions: [uiAction], client: client)
            }
        }
    }

    private func scheduleNeuralEnhancement(
        token: UInt64,
        pinyin: String,
        bestSentence: String,
        candidates: [String],
        translationTarget: TargetLanguage?,
        client: IMKTextInput
    ) {
        debounceTask?.cancel()
        let leftContext = resolveLeftContext(client: client)

        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 1. 译文模式下优先走 L3 翻译槽（档位 C 互斥控内存 <2GB，不和 L2 争抢权重加载）
            if let target = translationTarget {
                // 单字母未完成输入（如 d -> 的）延长防抖至 380ms；刚切完语种时防抖 160ms 并取消旧请求，避免连按 Shift+Tab 浪费 GPU
                let isSingleLetter = (pinyin.count == 1 && bestSentence.count == 1)
                let recentlySwitchedLang = (CFAbsoluteTimeGetCurrent() - self.lastLanguageSwitchTime) < 0.25
                if recentlySwitchedLang {
                    InferenceXPCClient.shared.cancelAll()
                }
                let delayMs = isSingleLetter ? 380 : (recentlySwitchedLang ? 160 : 90)
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled, self.isActiveSession, self.stateMachine.sessionToken == token else { return }

                // 严格隔离：绝不将输入框中已上屏的英文/无关段落作为 leftContext 喂给翻译模型
                let reply = await InferenceXPCClient.shared.translate(
                    sourceText: bestSentence,
                    leftContext: "",
                    target: target,
                    isCommitRequest: false
                )
                guard !Task.isCancelled, self.isActiveSession, self.stateMachine.sessionToken == token else { return }

                let preview: TranslationPreviewState
                if let reply, !reply.translatedText.isEmpty {
                    preview = .ready(
                        sourceText: bestSentence,
                        translatedText: reply.translatedText,
                        target: target,
                        latencyMs: reply.latencyMs
                    )
                } else {
                    preview = .failed(sourceText: bestSentence, target: target, reason: "翻译模型未就绪")
                }
                if let uiAction = self.stateMachine.applyTranslationPreview(
                    preview,
                    modelLabel: reply?.backendName,
                    forToken: token
                ) {
                    self.execute(actions: [uiAction], client: client)
                }
                return
            }

            // 2. 普通中文模式：仅在存在有效中文上文（>= 2 字且含汉字）且候选 > 1 时触发 L2 神经语境连续分重排
            let cleanLeft = leftContext.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasChineseLeft = cleanLeft.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            guard self.currentPreferences.enableNeuralRerank,
                  candidates.count > 1,
                  cleanLeft.count >= 2,
                  hasChineseLeft
            else { return }
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled, self.isActiveSession, self.stateMachine.sessionToken == token else { return }

            // 当搜索框/短文本框左文很短（< 18 字）时，附带极轻量的近期工作记忆话题背景（<= 36 字）帮助 Qwen3 准确消歧
            var enrichedLeft = cleanLeft
            if cleanLeft.count < 18, self.currentPreferences.enableWorkingMemory {
                let appID = client.bundleIdentifier() ?? "unknown"
                let topic = Self.sharedWorkingMemory.recentTopicContext(
                    forApp: appID,
                    shareAcrossApps: self.currentPreferences.shareWorkingMemoryAcrossApps,
                    currentLeftContext: cleanLeft,
                    maxChars: 36
                )
                if !topic.isEmpty && !cleanLeft.contains(topic) {
                    enrichedLeft = "\(topic)\n\(cleanLeft)"
                }
            }

            if let scored = await InferenceXPCClient.shared.rerankScored(
                leftContext: enrichedLeft,
                pinyin: pinyin,
                candidates: candidates,
                timeoutMs: 85
            ) {
                guard !Task.isCancelled, self.isActiveSession, self.stateMachine.sessionToken == token else { return }
                let actions = self.stateMachine.applyRerankedScoresWithActions(scored, forToken: token)
                if !actions.isEmpty {
                    self.execute(actions: actions, client: client)
                }
            }
        }
    }

    private func commitDraftProofreadAsync(
        rawDraft: String,
        aiSourceText: String,
        fallbackText: String,
        requestPredictions: Bool,
        client: IMKTextInput
    ) {
        let capturedToken = stateMachine.sessionToken
        let leftContext = resolveLeftContext(client: client)
        proofreadDebounceTask?.cancel()
        nextAsyncCommitToken &+= 1
        let commitToken = nextAsyncCommitToken
        activeAsyncCommitToken = commitToken
        isCommittingTranslation = true
        commitTranslationStartedAt = CFAbsoluteTimeGetCurrent()
        pendingAsyncCommitFallback = (text: fallbackText, client: client)
        bufferedEventsDuringCommit.removeAll()
        updateMarkedText("\(fallbackText) ⋯", client: client)

        commitTranslationTask?.cancel()
        commitTranslationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let reply = await InferenceXPCClient.shared.proofreadSentence(
                sourceText: aiSourceText,
                leftContext: leftContext,
                timeoutSeconds: 0.45,
                isCommitRequest: true
            )
            defer {
                if self.activeAsyncCommitToken == commitToken {
                    let queued = self.bufferedEventsDuringCommit
                    self.bufferedEventsDuringCommit.removeAll()
                    self.activeAsyncCommitToken = nil
                    self.isCommittingTranslation = false
                    self.commitTranslationStartedAt = 0
                    self.commitTranslationTask = nil
                    if self.isActiveSession, !queued.isEmpty {
                        for (idx, ev) in queued.enumerated() {
                            if self.isCommittingTranslation {
                                self.bufferedEventsDuringCommit.append(contentsOf: queued[idx...])
                                break
                            }
                            _ = self.processNormalizedEvent(ev, client: client)
                        }
                    }
                }
            }
            guard !Task.isCancelled,
                  self.activeAsyncCommitToken == commitToken,
                  self.isActiveSession,
                  self.stateMachine.sessionToken == capturedToken
            else {
                if self.activeAsyncCommitToken == commitToken {
                    if let pending = self.pendingAsyncCommitFallback {
                        self.pendingAsyncCommitFallback = nil
                        self.stateMachine.recordAsyncCommittedText(pending.text)
                        self.commitAtomically(text: pending.text, client: pending.client, requestPredictions: false)
                    } else {
                        self.clearMarkedText(client: client)
                    }
                }
                return
            }

            self.pendingAsyncCommitFallback = nil
            var finalText = fallbackText
            if let reply, !reply.correctedText.isEmpty {
                if let validated = self.proofreadValidator.validateAndBuildState(
                    source: aiSourceText,
                    candidateOutput: reply.correctedText,
                    latencyMs: reply.latencyMs,
                    backendLabel: reply.fromCache ? "缓存" : "AI"
                ), case .suggested(_, let corrected, _, _, _, _) = validated, !corrected.isEmpty {
                    finalText = corrected
                }
            }
            _ = rawDraft
            self.stateMachine.recordAsyncCommittedText(finalText)
            self.commitAtomically(text: finalText, client: client, requestPredictions: requestPredictions)
        }
    }

    private func commitTranslationAsync(
        sourceText: String,
        target: TargetLanguage,
        client: IMKTextInput
    ) {
        let capturedToken = stateMachine.sessionToken
        let leftForSpacing = resolveLeftContext(client: client)
        nextAsyncCommitToken &+= 1
        let commitToken = nextAsyncCommitToken
        activeAsyncCommitToken = commitToken
        isCommittingTranslation = true
        commitTranslationStartedAt = CFAbsoluteTimeGetCurrent()
        pendingAsyncCommitFallback = (text: sourceText, client: client)
        bufferedEventsDuringCommit.removeAll()
        updateMarkedText("\(sourceText) ⋯", client: client)

        commitTranslationTask?.cancel()
        commitTranslationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let reply = await InferenceXPCClient.shared.translate(
                sourceText: sourceText,
                leftContext: "",
                target: target,
                isCommitRequest: true
            )
            defer {
                if self.activeAsyncCommitToken == commitToken {
                    let queued = self.bufferedEventsDuringCommit
                    self.bufferedEventsDuringCommit.removeAll()
                    self.activeAsyncCommitToken = nil
                    self.isCommittingTranslation = false
                    self.commitTranslationStartedAt = 0
                    self.commitTranslationTask = nil
                    if self.isActiveSession, !queued.isEmpty {
                        for (idx, ev) in queued.enumerated() {
                            if self.isCommittingTranslation {
                                self.bufferedEventsDuringCommit.append(contentsOf: queued[idx...])
                                break
                            }
                            _ = self.processNormalizedEvent(ev, client: client)
                        }
                    }
                }
            }
            guard !Task.isCancelled,
                  self.activeAsyncCommitToken == commitToken,
                  self.isActiveSession,
                  self.stateMachine.sessionToken == capturedToken
            else {
                if self.activeAsyncCommitToken == commitToken {
                    if let pending = self.pendingAsyncCommitFallback {
                        self.pendingAsyncCommitFallback = nil
                        self.commitAtomically(text: pending.text, client: pending.client, requestPredictions: false)
                    } else {
                        self.clearMarkedText(client: client)
                    }
                }
                return
            }
            self.pendingAsyncCommitFallback = nil
            let rawTranslated = (reply?.translatedText.isEmpty == false) ? reply!.translatedText : sourceText
            let finalText = TranslationSpacingHelper.formatForCommit(
                translatedText: rawTranslated,
                leftContext: leftForSpacing,
                target: target,
                autoSpaceEnabled: self.currentPreferences.autoSpaceTranslatedSegments
            )
            self.commitAtomically(text: finalText, client: client, requestPredictions: false)
        }
    }

    private func commitAtomically(
        text: String,
        client: IMKTextInput,
        requestPredictions: Bool
    ) {
        let secure = IsSecureEventInputEnabled()
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        contextTracker.recordCommitted(text, isSecureInput: secure)
        // 立刻作废提交前的旧 AX 快照，防止 1.2 秒节流缓存把刚提交的新词倒流覆写掉！
        Self.sharedDocumentReader.invalidateCachedLeftTail()
        refreshDocumentContext(client: client, isSecureInput: secure, forceAX: false)

        let appID = client.bundleIdentifier() ?? "unknown"
        // 带提交后后缀强不变量解析权威左文（100% 保证包含刚提交的 text，彻底消灭重复联想）
        let leftContext = resolveLeftContext(client: client, isSecureInput: secure, requiredSuffix: text)
        stateMachine.updateRuntimeContext(leftContext: leftContext, appBundleID: appID, isSecureInput: secure)

        guard requestPredictions,
              currentPreferences.enableContinuationPrediction,
              !secure,
              (stateMachine.mode == .chinesePinyin || stateMachine.mode == .draftProofread)
        else { return }

        predictionTask?.cancel()
        let capturedToken = stateMachine.sessionToken
        let autoHideSecs = currentPreferences.predictionAutoHideSeconds
        let trimmedLeft = leftContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLeft.count >= 2 else { return }
        // 句末终结标点（。！？!?）刚落定时克制不硬弹联想条，减少视觉打扰
        if let lastChar = trimmedLeft.last, "。！？!?".contains(lastChar) {
            return
        }

        // 0ms 瞬时个性化续写融合：短期工作记忆 + 当前文档锚点 + 长期个人高频搭配（零等待大模型）
        var instantContinuations: [String] = []
        if currentPreferences.enableWorkingMemory {
            for item in Self.sharedWorkingMemory.immediateContinuations(
                forLeftContext: leftContext,
                appBundleID: appID,
                shareAcrossApps: currentPreferences.shareWorkingMemoryAcrossApps,
                limit: 2
            ) where !instantContinuations.contains(item) {
                instantContinuations.append(item)
            }
        }
        if currentPreferences.enableDocumentContextAssist {
            for item in Self.sharedDocumentIndex.immediateContinuations(forLeftContext: leftContext, limit: 2)
            where !instantContinuations.contains(item) {
                instantContinuations.append(item)
            }
        }
        if currentPreferences.enablePersonalMemory {
            for item in Self.sharedMemoryStore.topContinuations(forLeftContext: leftContext, limit: 2)
            where !instantContinuations.contains(item) {
                instantContinuations.append(item)
            }
        }
        let cappedInstant = PredictionPostProcessor.mergeAndRefine(
            leftContext: leftContext,
            instantMemory: instantContinuations,
            neuralSuggestions: [],
            maxSuggestions: 3
        )

        if !cappedInstant.isEmpty {
            stateMachine.cachePredictionsForInlineFusion(cappedInstant, forLeftContext: leftContext)
            if currentPreferences.predictionDisplayStyle == .barAndInlineFusion,
               let uiAction = stateMachine.applyPredictions(cappedInstant, modelLabel: "记忆续写", forToken: capturedToken) {
                execute(actions: [uiAction], client: client)
                schedulePredictionAutoHide(seconds: autoHideSecs)
            }
        }

        predictionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled, self.isActiveSession, self.stateMachine.sessionToken == capturedToken else { return }

            // 续写上下文净化：以当前输入框真实上文为准，绝不把跨应用无关内容用换行拼进去误导多分支续写；
            // 仅当左文极短（< 8 字）且同应用最近存在相关近期句时，用中文句号轻衔接。
            var predictContext = leftContext
            if leftContext.count < 8, self.currentPreferences.enableWorkingMemory {
                let topic = Self.sharedWorkingMemory.recentTopicContext(
                    forApp: appID,
                    shareAcrossApps: false,
                    currentLeftContext: leftContext,
                    maxChars: 24
                )
                if !topic.isEmpty && !leftContext.contains(topic) && !topic.hasSuffix(leftContext) {
                    let sep = topic.hasSuffix("。") || topic.hasSuffix("，") || topic.hasSuffix("！") || topic.hasSuffix("？")
                        ? ""
                        : "。"
                    predictContext = "\(topic)\(sep)\(leftContext)"
                }
            }

            let neuralItems = await InferenceXPCClient.shared.predictContinuation(
                leftContext: predictContext,
                maxSuggestions: 3
            )
            guard !Task.isCancelled, self.isActiveSession, self.stateMachine.sessionToken == capturedToken else { return }

            let capped = PredictionPostProcessor.mergeAndRefine(
                leftContext: leftContext,
                instantMemory: cappedInstant,
                neuralSuggestions: neuralItems,
                maxSuggestions: 3
            )
            guard !capped.isEmpty else { return }

            // 始终写入 6 秒静默接力缓存（即使选择「仅首字母融合」无弹窗模式，下一字母也能 0ms 融进候选栏）
            self.stateMachine.cachePredictionsForInlineFusion(capped, forLeftContext: leftContext)

            if self.currentPreferences.predictionDisplayStyle == .barAndInlineFusion,
               let uiAction = self.stateMachine.applyPredictions(capped, forToken: capturedToken) {
                self.execute(actions: [uiAction], client: client)
                self.schedulePredictionAutoHide(seconds: autoHideSecs)
            }
        }
    }

    private func schedulePredictionAutoHide(seconds: Int) {
        predictionAutoHideTask?.cancel()
        predictionAutoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            if CandidatePanelController.shared.isOwner(self.ownerID),
               CandidatePanelController.shared.isShowingPredictionsOnly {
                _ = self.stateMachine.dismissPredictions()
                CandidatePanelController.shared.hide(ownerID: self.ownerID)
            }
        }
    }

    // MARK: - 上下文同步、文档索引刷新与光标定位

    private func syncRuntimeContext(client: IMKTextInput, isSecureInput: Bool) {
        let appID = client.bundleIdentifier() ?? "unknown"
        let left = resolveLeftContext(client: client, isSecureInput: isSecureInput)
        stateMachine.updateRuntimeContext(
            leftContext: left,
            appBundleID: appID,
            isSecureInput: isSecureInput
        )
    }

    private func refreshDocumentContext(
        client: IMKTextInput,
        isSecureInput: Bool,
        forceAX: Bool
    ) {
        guard currentPreferences.enableDocumentContextAssist else {
            Self.sharedDocumentIndex.clear()
            return
        }
        let appID = client.bundleIdentifier() ?? "unknown"
        let imkSnap = Self.sharedDocumentReader.readIMKWindow(client: client, isSecureInput: isSecureInput)
        let fallbackText = contextTracker.sessionText(isSecureInput: isSecureInput)
        Self.sharedDocumentReader.refreshAsync(
            index: Self.sharedDocumentIndex,
            appBundleID: appID,
            isSecureInput: isSecureInput,
            imkSnapshot: imkSnap,
            fallbackSessionText: fallbackText,
            forceAX: forceAX
        )
    }

    private func updateMarkedText(_ text: String, client: IMKTextInput) {
        let bundleID = client.bundleIdentifier() ?? ""
        let range = NSRange(location: text.utf16.count, length: 0)
        if Self.terminalBundleIDs.contains(bundleID) {
            client.setMarkedText(text, selectionRange: range, replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }
        let attributed = NSAttributedString(
            string: text,
            attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]
        )
        client.setMarkedText(attributed, selectionRange: range, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func clearMarkedText(client: IMKTextInput) {
        client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func cursorRect(for client: IMKTextInput) -> NSRect {
        var rect = NSRect.zero
        client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        let isOnAnyScreen = NSScreen.screens.contains { $0.frame.insetBy(dx: -40, dy: -40).contains(rect.origin) }
        let isValid = rect != .zero
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && (rect.origin.x != 0 || rect.origin.y != 0)
            && isOnAnyScreen

        if isValid {
            let normalized = NSRect(
                x: rect.origin.x,
                y: rect.origin.y,
                width: max(1, rect.size.width),
                height: max(18, rect.size.height)
            )
            lastValidAnchorRect = normalized
            return normalized
        }
        if let last = lastValidAnchorRect {
            return last
        }
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y, width: 1, height: 18)
    }

    private func resolveLeftContext(
        client: IMKTextInput,
        isSecureInput: Bool = IsSecureEventInputEnabled(),
        requiredSuffix: String? = nil
    ) -> String {
        let appID = client.bundleIdentifier() ?? "unknown"
        return contextTracker.resolveAuthoritativeLeftContext(
            isSecureInput: isSecureInput,
            maxWindow: 128,
            requiredSuffix: requiredSuffix
        ) {
            let selected = client.selectedRange()
            if selected.location != NSNotFound {
                if selected.location == 0 && selected.length == 0 {
                    return ExternalLeftContextSnapshot(
                        text: "",
                        capturedAt: Date().timeIntervalSince1970,
                        isSynchronousIMK: true
                    )
                }
                if selected.location > 0 {
                    let fetchLen = min(selected.location, 128)
                    let range = NSRange(location: selected.location - fetchLen, length: fetchLen)
                    if let str = client.attributedSubstring(from: range)?.string, !str.isEmpty {
                        return ExternalLeftContextSnapshot(
                            text: str,
                            capturedAt: Date().timeIntervalSince1970,
                            isSynchronousIMK: true
                        )
                    }
                }
            }
            if let ax = Self.sharedDocumentReader.cachedLeftTailWithTimestamp(
                forApp: appID,
                isSecureInput: isSecureInput
            ) {
                return ExternalLeftContextSnapshot(
                    text: ax.text,
                    capturedAt: ax.capturedAt,
                    isSynchronousIMK: false
                )
            }
            return nil
        }
    }

    private func applyPersistedPreferencesChange(
        translateMode: Bool?,
        targetLanguage: TargetLanguage?,
        codingMode: Bool?,
        chinesePunctuation: Bool?,
        client: IMKTextInput?,
        showToast: Bool,
        syncStateMachine: Bool = true
    ) {
        var updated = SmartPinyinPreferencesStore.load()
        if let translateMode { updated.defaultTranslateMode = translateMode }
        if let targetLanguage {
            updated.defaultTargetLanguage = targetLanguage
            lastLanguageSwitchTime = CFAbsoluteTimeGetCurrent()
        }
        if let codingMode { updated.codingModeEnabled = codingMode }
        if let chinesePunctuation { updated.chinesePunctuation = chinesePunctuation }

        SmartPinyinPreferencesStore.save(updated)
        currentPreferences = updated
        Self.sharedEngine.applyPreferences(updated)
        if translateMode == true {
            Self.isGlobalDirectEnglish = false
            performOnMainSync {
                InferenceXPCClient.shared.prewarmTranslation()
            }
        }
        if syncStateMachine {
            stateMachine.applyPreferences(updated)
            if let translateMode {
                let actions = stateMachine.setTranslateMode(enabled: translateMode)
                if let client, stateMachine.hasActiveComposition {
                    execute(actions: actions, client: client)
                }
            }
            if let targetLanguage {
                let actions = stateMachine.setTargetLanguage(targetLanguage)
                if let client, stateMachine.hasActiveComposition {
                    execute(actions: actions, client: client)
                }
            }
        }
        Self.diagLog(
            "persistPref translate=\(updated.defaultTranslateMode) lang=\(updated.defaultTargetLanguage.rawValue) coding=\(updated.codingModeEnabled) zhPunct=\(updated.chinesePunctuation)"
        )
        guard showToast, let client, !stateMachine.hasActiveComposition else { return }
        if let targetLanguage {
            showBriefModeToast(client: client, customMessage: "中→\(targetLanguage.shortBadge) · 翻译目标：\(targetLanguage.displayName)")
        } else if let codingMode {
            showBriefModeToast(
                client: client,
                customMessage: codingMode
                    ? "Coding 模式已开启（中文默认英文半角标点）"
                    : "全局 Coding 模式已关闭（按应用自动适配标点）"
            )
        } else if let chinesePunctuation {
            showBriefModeToast(
                client: client,
                customMessage: chinesePunctuation ? "已切换为中文全角标点（，。！？）" : "已切换为英文半角标点（,.!?）"
            )
        } else if let translateMode {
            let badge = updated.globalDisableTranslateShortcut.badge
            let hint = badge.isEmpty ? "" : "（\(badge)）"
            showBriefModeToast(
                client: client,
                customMessage: translateMode
                    ? "中→\(updated.defaultTargetLanguage.shortBadge) · 已开启全局实时翻译"
                    : "中 · 已全局关闭翻译模式\(hint)"
            )
        }
    }

    private func handleFlagsChanged(_ event: NSEvent, client: IMKTextInput) -> Bool {
        let keyCode = event.keyCode
        let flags = event.modifierFlags

        // 1. 左/右 Shift 短按：中 / 英文直出切换
        let isShiftKey = (keyCode == 56 || keyCode == 60)
        if isShiftKey {
            pendingOptionDownTime = nil
            pendingOptionKeyCode = nil
            guard currentPreferences.shiftTapSwitchEnabled else {
                pendingShiftDownTime = nil
                return false
            }
            let otherMods: NSEvent.ModifierFlags = [.command, .control, .option]
            guard flags.intersection(otherMods).isEmpty else {
                pendingShiftDownTime = nil
                return false
            }
            if flags.contains(.shift) {
                pendingShiftDownTime = CFAbsoluteTimeGetCurrent()
                return false
            }
            if let downTime = pendingShiftDownTime {
                pendingShiftDownTime = nil
                // 仅在 450ms 内的纯粹短按才切换中英，避免长按 Shift 或 Shift+快捷键/点击误切英文模式
                guard CFAbsoluteTimeGetCurrent() - downTime <= 0.45 else { return false }
                let actions = stateMachine.handle(NormalizedKeyEvent(kind: .shiftTapToggle))
                Self.isGlobalDirectEnglish = (stateMachine.mode == .directEnglish)
                execute(actions: actions, client: client)
                showBriefModeToast(client: client)
                Self.diagLog("shiftToggle newMode=\(stateMachine.mode)")
                return true
            }
            return false
        }

        // 2. Option 修饰键手势：短按右 Option 0ms 开关翻译模式 · 双击右 Option（或双击任意 Option）弹出 1–6 语种直选条
        let isOptionKey = (keyCode == 58 || keyCode == 61)
        if isOptionKey {
            pendingShiftDownTime = nil
            let gesture = currentPreferences.translateQuickGesture
            guard gesture != .off else {
                pendingOptionDownTime = nil
                pendingOptionKeyCode = nil
                return false
            }
            if gesture == .rightOptionTap && keyCode != 61 {
                pendingOptionDownTime = nil
                pendingOptionKeyCode = nil
                return false
            }
            let otherMods: NSEvent.ModifierFlags = [.command, .control, .shift]
            guard flags.intersection(otherMods).isEmpty else {
                pendingOptionDownTime = nil
                pendingOptionKeyCode = nil
                return false
            }
            if flags.contains(.option) {
                pendingOptionDownTime = CFAbsoluteTimeGetCurrent()
                pendingOptionKeyCode = keyCode
                return false
            }
            if let downTime = pendingOptionDownTime, pendingOptionKeyCode == keyCode {
                pendingOptionDownTime = nil
                pendingOptionKeyCode = nil
                let now = CFAbsoluteTimeGetCurrent()
                guard now - downTime <= 0.40 else { return false }

                let isDoubleTap = (lastOptionTapKeyCode == keyCode) && ((now - lastOptionTapTime) <= 0.34)
                if gesture == .doubleOptionTap {
                    if isDoubleTap {
                        lastOptionTapTime = 0
                        let actions = stateMachine.openLanguagePicker()
                        execute(actions: actions, client: client)
                        Self.diagLog("optionDoubleTap -> openLanguagePicker")
                        return true
                    }
                    lastOptionTapTime = now
                    lastOptionTapKeyCode = keyCode
                    return false
                }

                // rightOptionTap：第 1 下 0ms 立即开关翻译模式，340ms 内第 2 下撤销开关并改为弹出 1–6 语种直选条！
                if isDoubleTap {
                    lastOptionTapTime = 0
                    if let prevTranslate = translateModeBeforeRightOptionTap {
                        translateModeBeforeRightOptionTap = nil
                        applyPersistedPreferencesChange(
                            translateMode: prevTranslate,
                            targetLanguage: nil,
                            codingMode: nil,
                            chinesePunctuation: nil,
                            client: client,
                            showToast: false
                        )
                    }
                    let actions = stateMachine.openLanguagePicker()
                    execute(actions: actions, client: client)
                    Self.diagLog("rightOptionDoubleTap -> openLanguagePicker")
                    return true
                }

                lastOptionTapTime = now
                lastOptionTapKeyCode = keyCode
                translateModeBeforeRightOptionTap = currentPreferences.defaultTranslateMode
                let nextTranslate = !currentPreferences.defaultTranslateMode
                applyPersistedPreferencesChange(
                    translateMode: nextTranslate,
                    targetLanguage: nil,
                    codingMode: nil,
                    chinesePunctuation: nil,
                    client: client,
                    showToast: true
                )
                Self.diagLog("rightOptionSingleTap translate=\(nextTranslate)")
                return true
            }
            return false
        }

        // 其它修饰键（Cmd / Ctrl / Fn）按下时立即清掉待定手势，绝不误触
        pendingShiftDownTime = nil
        pendingOptionDownTime = nil
        pendingOptionKeyCode = nil
        return false
    }

    private func showBriefModeToast(client: IMKTextInput, customMessage: String? = nil) {
        let label: String = customMessage ?? {
            switch stateMachine.mode {
            case .directEnglish: return "EN · 英文直出（短按 Shift 切回中文）"
            case .chinesePinyin: return "中 · 智能拼音"
            case .draftProofread:
                return currentPreferences.draftSpaceBehavior == .stageThenCommit
                    ? "校 · 整句暂存与校对（␣ 进草稿 · 再按 ␣ 上屏）"
                    : "校 · 整句暂存与校对（⏎ 上屏）"
            case .translateOnCommit(let lang): return "中→\(lang.shortBadge) · 实时翻译"
            }
        }()
        let snap = CandidatePanelSnapshot(
            isVisible: true,
            mode: stateMachine.mode,
            preedit: label,
            showTranslationBar: false
        )
        let anchor = cursorRect(for: client)
        let myOwner = ownerID
        performOnMainSync {
            CandidatePanelController.shared.update(snapshot: snap, anchorRect: anchor, ownerID: myOwner)
        }
        modeToastHideTask?.cancel()
        modeToastHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled, !self.stateMachine.hasActiveComposition else { return }
            if CandidatePanelController.shared.isOwner(self.ownerID) {
                CandidatePanelController.shared.hide(ownerID: self.ownerID)
            }
        }
    }

    private static let diagQueue = DispatchQueue(label: "com.smartpinyin.ime.diag", qos: .utility)

    private static func safeKindLabel(_ kind: NormalizedKeyEvent.Kind) -> String {
        switch kind {
        case .character: return "char"
        case .space: return "space"
        case .returnKey: return "return"
        case .backspace: return "bs"
        case .escape: return "esc"
        case .tab: return "tab"
        case .arrowUp, .arrowDown, .arrowLeft, .arrowRight: return "arrow"
        case .pageUp, .pageDown: return "page"
        case .shiftTapToggle: return "shift"
        case .other(let code): return "other(\(code))"
        }
    }

    /// 隐私安全运行日志（仅记录事件类别/模式/状态，绝不记录用户打出的文字内容）
    private static func diagLog(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        diagQueue.async {
            let fm = FileManager.default
            guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let logDir = base.appendingPathComponent("\(SmartPinyinIdentifiers.appSupportFolderName)/Logs", isDirectory: true)
            try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
            let logFile = logDir.appendingPathComponent("ime_runtime.log")
            if let attrs = try? fm.attributesOfItem(atPath: logFile.path),
               let size = attrs[.size] as? Int64, size > 131_072 {
                try? fm.removeItem(at: logFile)
            }
            if let data = line.data(using: .utf8) {
                if fm.fileExists(atPath: logFile.path),
                   let fh = try? FileHandle(forWritingTo: logFile) {
                    defer { try? fh.close() }
                    _ = try? fh.seekToEnd()
                    try? fh.write(contentsOf: data)
                } else {
                    try? data.write(to: logFile)
                }
            }
        }
    }

    private func isGlobalDisableTranslateShortcutEvent(_ event: NormalizedKeyEvent) -> Bool {
        let shortcut = currentPreferences.globalDisableTranslateShortcut
        guard shortcut != .off else { return false }
        guard case .character(let ch, let keyCode) = event.kind,
              (keyCode == 17 || ch.lowercased() == "t")
        else { return false }
        switch shortcut {
        case .controlOptionT: return event.modifiers == [.control, .option]
        case .optionShiftT: return event.modifiers == [.option, .shift]
        case .controlShiftT: return event.modifiers == [.control, .shift]
        case .off: return false
        }
    }

    private func normalize(event: NSEvent) -> NormalizedKeyEvent? {
        var mods: NormalizedKeyEvent.Modifiers = []
        if event.modifierFlags.contains(.shift) { mods.insert(.shift) }
        if event.modifierFlags.contains(.control) { mods.insert(.control) }
        if event.modifierFlags.contains(.option) { mods.insert(.option) }
        if event.modifierFlags.contains(.command) { mods.insert(.command) }

        switch event.keyCode {
        case 49: return NormalizedKeyEvent(kind: .space, modifiers: mods)
        case 36, 76: return NormalizedKeyEvent(kind: .returnKey, modifiers: mods)
        case 51: return NormalizedKeyEvent(kind: .backspace, modifiers: mods)
        case 53: return NormalizedKeyEvent(kind: .escape, modifiers: mods)
        case 48: return NormalizedKeyEvent(kind: .tab, modifiers: mods)
        case 126: return NormalizedKeyEvent(kind: .arrowUp, modifiers: mods)
        case 125: return NormalizedKeyEvent(kind: .arrowDown, modifiers: mods)
        case 123: return NormalizedKeyEvent(kind: .arrowLeft, modifiers: mods)
        case 124: return NormalizedKeyEvent(kind: .arrowRight, modifiers: mods)
        case 116: return NormalizedKeyEvent(kind: .pageUp, modifiers: mods)
        case 121: return NormalizedKeyEvent(kind: .pageDown, modifiers: mods)
        default:
            let chars = (mods.contains(.option) || mods.contains(.control))
                ? event.charactersIgnoringModifiers
                : event.characters
            if let chars, !chars.isEmpty {
                return NormalizedKeyEvent(kind: .character(chars, keyCode: event.keyCode), modifiers: mods)
            }
            return NormalizedKeyEvent(kind: .other(keyCode: event.keyCode), modifiers: mods)
        }
    }
}
