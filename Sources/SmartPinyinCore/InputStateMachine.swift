import Foundation
import PinyinEngineCore
import SharedIPC

/// 标准化后的按键事件，解耦 AppKit NSEvent，便于 100% 单元测试状态机
public struct NormalizedKeyEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case character(String, keyCode: UInt16)
        case space
        case returnKey
        case backspace
        case escape
        case tab
        case arrowUp
        case arrowDown
        case arrowLeft
        case arrowRight
        case pageUp
        case pageDown
        case shiftTapToggle
        case other(keyCode: UInt16)
    }

    public struct Modifiers: OptionSet, Equatable, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public let kind: Kind
    public let modifiers: Modifiers

    public init(kind: Kind, modifiers: Modifiers = []) {
        self.kind = kind
        self.modifiers = modifiers
    }
}

/// 状态机对外输出的副作用指令（由 IMKInputController 统一落地执行）
public enum InputAction: Equatable, Sendable {
    case passThrough
    case updateUI(CandidatePanelSnapshot)
    case commitText(text: String, requestPredictions: Bool)
    case commitTranslation(
        sourceText: String,
        target: TargetLanguage,
        cachedTranslation: String?
    )
    case requestNeuralEnhancement(
        sessionToken: UInt64,
        pinyin: String,
        bestSentence: String,
        candidates: [String],
        translationTarget: TargetLanguage?
    )
    case cancelPendingInference
    case persistPreferencesChange(
        translateMode: Bool?,
        targetLanguage: TargetLanguage?,
        codingMode: Bool?,
        chinesePunctuation: Bool?
    )
}

/// 输入法核心状态机：
/// - 同步、确定性、无 UI 阻塞
/// - 融合 L1 万象拼音 + 本地 SQLite 自进化偏好记忆 + 当前文本框拼音/简拼与锚点召回
/// - 翻译模式下采用「独立翻译栏实时展示译文 + 空格/回车直接上屏译文 + 1-9 数字键选词纠错 + Shift+回车上屏中文原文」交互
public final class InputStateMachine {
    private struct LastCommitRecord {
        let pinyin: String
        let word: String
        let leftContext: String
        let promotedPhrase: String?
        let timestamp: TimeInterval
        var remainingDeletes: Int
    }

    private struct PendingPredictionSnapshot {
        let leftContextTail: String
        let entries: [(text: String, keys: PinyinNormalizer.TermPinyinKeys)]
        let timestamp: TimeInterval
    }

    private let engine: PinyinEngineProtocol
    private let memoryStore: UserMemoryStore?
    private let documentIndex: DocumentContextIndex?
    private let workingMemory: SessionWorkingMemory?
    private let tagStore: DomainAndLiteraryTagStore?
    private let sceneDetector = SceneContextDetector()
    private let ranker: CandidateFusionRanker
    private let pinyinNormalizer = PinyinNormalizer()
    private let typoCorrector = PinyinTypoCorrector()
    private let clock: () -> TimeInterval

    public private(set) var mode: InputMode = .chinesePinyin
    public private(set) var preferredTargetLanguage: TargetLanguage = .english
    public private(set) var preferences: SmartPinyinPreferences
    public private(set) var sessionToken: UInt64 = 0
    public private(set) var currentSceneState: SceneContextState = .general

    private var activeAppBundleID: String = ""
    private var currentLeftContext: String = ""
    private var isSecureInput: Bool = false

    private var inlineOverrideTarget: TargetLanguage?
    private var inlinePrefixBuffer: String = ""
    /// 本句临时抑制全局翻译模式（由拼写态按 Tab 触发，上屏或重置后自动恢复）
    private var suppressTranslateForCurrentSentence: Bool = false
    /// 拼写态快速双击 Tab（≤ 320ms）判定时间戳与首击前的全局翻译态
    private var lastComposingTabTimestamp: TimeInterval = 0
    private var globalTranslateBeforeLastTab: Bool = false
    /// 光标处 1–6 语种直选条展开状态
    private var isLanguagePickerOpen: Bool = false
    private var languagePickerIndex: Int = 0
    /// 智能标点与 Coding 模式引擎
    private let punctuationEngine = SmartPunctuationEngine()
    /// 程序员中英混输快车道：大写开头/驼峰/下划线/Shift+空格触发的临时英文缓冲，上屏后自动无缝回中文
    private var inlineEnglishActive: Bool = false
    private var inlineEnglishAllowsSpaces: Bool = false
    private var inlineEnglishBuffer: String = ""
    private var inlineEnglishCandidates: [PinyinCandidate] = []

    /// 翻译模式下通过数字键 1-9 分段选词纠错后暂存的中文句缓冲（尚未上屏，实时驱动翻译栏）
    private var composedChineseBuffer: String = ""
    /// 当前页经融合排序（或 L2 神经重排）后的候选条目，保留 originalRimeIndex / globalRimeIndex 以便准确回写 Rime 用户词库
    private var rankedItems: [RankedCandidateItem] = []
    /// 第 1 页从深层 Top-16 召回池捞上首页展示过的候选词（翻到第 2 页时自动去重）
    private var firstPageRescuedTexts: Set<String> = []
    private var highlightedIndex: Int = 0
    private var translationPreview: TranslationPreviewState = .hidden
    private var predictions: [String] = []
    private var predictionHighlightedIndex: Int = 0
    /// 静默接力缓存：保存最近 6 秒与当前左文绑定的预联想短语，继续敲首字母时 0ms 融进候选栏首位
    private var pendingPredictionSnapshot: PendingPredictionSnapshot?
    /// 纠偏探针轻量缓存（同一纠偏拼音串在会话内 0.05ms 复用）
    private var typoProbeCache: [String: [PinyinCandidate]] = [:]
    private var activeModelLabel: String?
    private var lastCommitRecord: LastCommitRecord?

    public init(
        engine: PinyinEngineProtocol,
        preferences: SmartPinyinPreferences = .default,
        memoryStore: UserMemoryStore? = nil,
        documentIndex: DocumentContextIndex? = nil,
        workingMemory: SessionWorkingMemory? = nil,
        tagStore: DomainAndLiteraryTagStore? = nil,
        ranker: CandidateFusionRanker = CandidateFusionRanker(),
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.engine = engine
        self.preferences = preferences
        self.memoryStore = memoryStore
        self.documentIndex = documentIndex
        self.workingMemory = workingMemory
        self.tagStore = tagStore
        self.ranker = ranker
        self.clock = clock
        self.preferredTargetLanguage = preferences.defaultTargetLanguage
        self.mode = preferences.defaultTranslateMode
            ? .translateOnCommit(preferences.defaultTargetLanguage)
            : .chinesePinyin
    }

    /// 词库或用户自定义领域标签热更新后调用：刷新侧车领域索引并重置场景迟滞缓存
    public func reloadTagStoreAndScene() {
        tagStore?.reloadUserSidecarTags()
        sceneDetector.reset()
        currentSceneState = .general
    }

    /// 同步当前宿主 App、光标前文与密码框安全状态（0ms，主线程调用）
    public func updateRuntimeContext(
        leftContext: String,
        appBundleID: String,
        isSecureInput: Bool
    ) {
        if appBundleID != activeAppBundleID {
            punctuationEngine.resetQuotePairing()
        }
        self.currentLeftContext = isSecureInput ? "" : leftContext
        self.activeAppBundleID = appBundleID
        self.isSecureInput = isSecureInput
    }

    /// 当前宿主应用或全局设置下是否生效 Coding 模式（中文打字默认英文半角标点）
    public var isEffectiveCodingMode: Bool {
        SmartPunctuationEngine.isEffectiveCodingMode(
            preferences: preferences,
            appBundleID: activeAppBundleID
        )
    }

    /// 当前是否展开了 1–6 语种直选胶囊条
    public var isLanguagePickerVisible: Bool {
        isLanguagePickerOpen
    }

    private var effectiveTranslationTarget: TargetLanguage? {
        if let override = inlineOverrideTarget { return override }
        if suppressTranslateForCurrentSentence { return nil }
        return mode.translationTarget
    }

    /// 实时应用最新偏好设置（持久化的翻译模式开关跨窗口/App 始终生效）
    public func applyPreferences(_ newPreferences: SmartPinyinPreferences) {
        let oldLang = preferences.defaultTargetLanguage
        let oldDefaultTranslate = preferences.defaultTranslateMode
        if newPreferences.traditionalChinese != preferences.traditionalChinese
            || newPreferences.fuzzyNasalPinyin != preferences.fuzzyNasalPinyin
            || newPreferences.fuzzyRetroflexPinyin != preferences.fuzzyRetroflexPinyin
            || newPreferences.fuzzyNLAndFHPinyin != preferences.fuzzyNLAndFHPinyin {
            typoProbeCache.removeAll(keepingCapacity: true)
        }
        preferences = newPreferences

        if newPreferences.defaultTargetLanguage != oldLang
            || newPreferences.defaultTargetLanguage != preferredTargetLanguage {
            preferredTargetLanguage = newPreferences.defaultTargetLanguage
            if case .translateOnCommit = mode {
                mode = .translateOnCommit(preferredTargetLanguage)
            }
        }
        if newPreferences.defaultTranslateMode != oldDefaultTranslate {
            if newPreferences.defaultTranslateMode {
                mode = .translateOnCommit(preferredTargetLanguage)
            } else if case .translateOnCommit = mode {
                mode = .chinesePinyin
                translationPreview = .hidden
            }
        }
        if !newPreferences.enableContinuationPrediction {
            predictions = []
        }
    }

    /// 显式切换翻译模式（由菜单栏开关、设置面板或可选热键调用）
    public func setTranslateMode(enabled: Bool) -> [InputAction] {
        suppressTranslateForCurrentSentence = false
        inlineOverrideTarget = nil
        if enabled {
            mode = .translateOnCommit(preferredTargetLanguage)
        } else {
            mode = .chinesePinyin
            translationPreview = .hidden
        }
        return refreshAfterModeChange()
    }

    /// 展开 1–6 语种直选胶囊条（双击右 Option 或点击翻译栏 [中→EN ▾] 时调用）
    public func openLanguagePicker() -> [InputAction] {
        isLanguagePickerOpen = true
        languagePickerIndex = TargetLanguage.allCases.firstIndex(of: preferredTargetLanguage) ?? 0
        return [.updateUI(buildPanelWithLanguagePicker())]
    }

    /// 切换 1–6 语种直选胶囊条展开/收起
    public func toggleLanguagePicker() -> [InputAction] {
        if isLanguagePickerOpen {
            isLanguagePickerOpen = false
            return [refreshUIOnlyAfterPickerClose()]
        }
        return openLanguagePicker()
    }

    /// 从 1–6 语种直选条选中指定目标语种并持久化
    public func selectTargetLanguageFromPicker(_ target: TargetLanguage) -> [InputAction] {
        isLanguagePickerOpen = false
        suppressTranslateForCurrentSentence = false
        preferredTargetLanguage = target
        preferences.defaultTargetLanguage = target
        if case .translateOnCommit = mode {
            mode = .translateOnCommit(target)
        }
        if inlineOverrideTarget != nil {
            inlineOverrideTarget = target
        }
        let persist = InputAction.persistPreferencesChange(
            translateMode: nil,
            targetLanguage: target,
            codingMode: nil,
            chinesePunctuation: nil
        )
        let snap = engine.currentSnapshot()
        if snap.isComposing || !composedChineseBuffer.isEmpty {
            return [persist] + refreshAfterModeChange()
        }
        return [persist, .updateUI(.empty)]
    }

    /// 候选窗右上角模式胶囊点击：原地切换中文 ↔ 实时翻译
    public func toggleTranslateFromPanelBadge() -> [InputAction] {
        let snap = engine.currentSnapshot()
        if snap.isComposing || !composedChineseBuffer.isEmpty {
            return toggleTranslateDuringComposition(snapshot: snap)
        }
        let willEnable = (mode.translationTarget == nil)
        preferences.defaultTranslateMode = willEnable
        let actions = setTranslateMode(enabled: willEnable)
        return [.persistPreferencesChange(
            translateMode: willEnable,
            targetLanguage: nil,
            codingMode: nil,
            chinesePunctuation: nil
        )] + actions
    }

    /// 翻译栏内「本句 / 全局」状态胶囊点击：本句升格锁定为全局翻译，或一键关闭全局翻译
    public func toggleGlobalTranslateFromBar() -> [InputAction] {
        let snap = engine.currentSnapshot()
        let isCurrentlyGlobal = (mode.translationTarget != nil && !suppressTranslateForCurrentSentence)
        return setPersistentTranslateInComposition(enabled: !isCurrentlyGlobal, snapshot: snap)
    }

    /// 显式切换英文直出 / 中文模式（由菜单栏开关或跨焦点同步调用）
    public func setDirectEnglish(_ enabled: Bool) -> [InputAction] {
        if enabled {
            if case .directEnglish = mode { return [] }
            return toggleChineseEnglish()
        } else {
            if case .directEnglish = mode {
                return toggleChineseEnglish()
            }
            return []
        }
    }

    /// 静默同步进程内全局英文直出态（跨窗口/焦点切换时不弹出残留面板）
    public func syncDirectEnglishState(_ enabled: Bool) {
        guard !hasActiveComposition else { return }
        if enabled {
            mode = .directEnglish
            translationPreview = .hidden
        } else if case .directEnglish = mode {
            mode = preferences.defaultTranslateMode
                ? .translateOnCommit(preferredTargetLanguage)
                : .chinesePinyin
        }
    }

    /// 显式切换翻译目标语言（由翻译栏语言胶囊或菜单调用）
    public func setTargetLanguage(_ language: TargetLanguage) -> [InputAction] {
        preferredTargetLanguage = language
        if case .translateOnCommit = mode {
            mode = .translateOnCommit(language)
        }
        if inlineOverrideTarget != nil {
            inlineOverrideTarget = language
        }
        return refreshAfterModeChange()
    }

    /// 循环切换下一个目标语言
    public func cycleTargetLanguage() -> [InputAction] {
        setTargetLanguage(preferredTargetLanguage.next)
    }

    /// 翻译栏点击「译文」按钮直接上屏当前译文
    public func commitCurrentTranslation() -> [InputAction] {
        let snap = engine.currentSnapshot()
        let effectiveTarget = inlineOverrideTarget ?? mode.translationTarget ?? preferredTargetLanguage
        let source = fullComposedChinese(from: snap)
        guard !source.isEmpty else { return resetSession() }
        let cached = readyCachedTranslation(for: source, target: effectiveTarget)
        return finishTranslationCommit(sourceText: source, target: effectiveTarget, cached: cached)
    }

    /// 翻译栏点击「原文」按钮直接上屏当前中文原文
    public func commitCurrentOriginalChinese() -> [InputAction] {
        let snap = engine.currentSnapshot()
        let source = fullComposedChinese(from: snap)
        guard !source.isEmpty else { return resetSession() }
        return finishCommit(text: source, requestPredictions: true, recordedPinyin: activeSegmentPinyin(from: snap))
    }

    /// 当前是否处于组合态（含翻译模式下的分段中文缓冲、临时英文缓冲与语种快选条）
    public var hasActiveComposition: Bool {
        engine.currentSnapshot().isComposing
            || !composedChineseBuffer.isEmpty
            || !inlinePrefixBuffer.isEmpty
            || inlineEnglishActive
            || isLanguagePickerOpen
    }

    /// 切换客户端或失焦时重置组合态并递增令牌，防止陈旧异步回调串窗
    public func resetSession() -> [InputAction] {
        sessionToken &+= 1
        engine.clearComposition()
        inlineOverrideTarget = nil
        inlinePrefixBuffer = ""
        suppressTranslateForCurrentSentence = false
        lastComposingTabTimestamp = 0
        globalTranslateBeforeLastTab = false
        isLanguagePickerOpen = false
        languagePickerIndex = 0
        punctuationEngine.resetQuotePairing()
        inlineEnglishActive = false
        inlineEnglishAllowsSpaces = false
        inlineEnglishBuffer = ""
        inlineEnglishCandidates = []
        composedChineseBuffer = ""
        rankedItems = []
        firstPageRescuedTexts.removeAll()
        pendingPredictionSnapshot = nil
        highlightedIndex = 0
        translationPreview = .hidden
        predictions = []
        lastCommitRecord = nil
        return [.cancelPendingInference, .updateUI(.empty)]
    }

    /// 处理一次键盘输入
    public func handle(_ event: NormalizedKeyEvent) -> [InputAction] {
        // 0. 一键全局关闭翻译模式快捷键（默认 ⌃⌥T）：任意模式（含英文/拼写中）均立即全局关闭并持久化
        if matchesGlobalDisableTranslateShortcut(event) {
            lastCommitRecord = nil
            return disableGlobalTranslateMode()
        }

        // 1. 系统快捷键（Cmd / Ctrl）一律放行；若当前正展示联想框，先将其收起
        if event.modifiers.contains(.command) || event.modifiers.contains(.control) {
            lastCommitRecord = nil
            if !predictions.isEmpty {
                predictions = []
                return [.updateUI(.empty), .passThrough]
            }
            return [.passThrough]
        }

        // 2. Option 组合键：
        //    - 若当前非拼写且联想条可见，Option + 1/2/3/4 一键直选对应联想词（绝不抢普通数字键）
        //    - 其余 Option 快捷键遵循既有设置（默认不拦截）
        if event.modifiers.contains(.option) {
            let currentSnap = engine.currentSnapshot()
            if event.modifiers == [.option],
               !currentSnap.isComposing,
               composedChineseBuffer.isEmpty,
               inlinePrefixBuffer.isEmpty,
               !inlineEnglishActive,
               !predictions.isEmpty,
               let predIdx = predictionDirectPickIndex(for: event.kind),
               predictions.indices.contains(predIdx) {
                return acceptPrediction(at: predIdx)
            }
            return handleOptionShortcut(event)
        }

        // 3. 短按 Shift：中英快速切换
        if event.kind == .shiftTapToggle {
            lastCommitRecord = nil
            isLanguagePickerOpen = false
            return toggleChineseEnglish()
        }

        // 3.5 光标处 1–6 语种直选条展开态（优先于英文模式，支持数字 1–6、方向键、回车、Esc）
        if isLanguagePickerOpen {
            lastCommitRecord = nil
            if let pickerActions = handleLanguagePickerKey(event) {
                return pickerActions
            }
        }

        // 4. 直出英文模式：完全放行（若残留联想先收起）
        if case .directEnglish = mode {
            lastCommitRecord = nil
            if !predictions.isEmpty {
                predictions = []
                return [.updateUI(.empty), .passThrough]
            }
            return [.passThrough]
        }

        let current = engine.currentSnapshot()

        // 5. 未在拼写且无待译中文缓冲，但存在联想词句时：
        //    - 默认模式（digits123）：单手直接按 1/2/3 一键采纳（100% 必达 IMK，绝不被浏览器抢焦点，带数字语境智能避让）
        //    - Tab（无 Shift）：采纳第 1 条（支持 Tab 的应用零学习成本）；彻底废弃易被浏览器抢焦点的 Shift+Tab
        //    - Option+1/2/3：任意模式下均可一键直选（已在步骤 2 优先处理）
        //    - Esc：关闭联想并清除静默接力缓存；其它任意键收起联想条但保留 6 秒静默接力缓存供首字母 0ms 融入候选栏
        var dismissedPredictions = false
        if !current.isComposing && composedChineseBuffer.isEmpty && inlinePrefixBuffer.isEmpty && !inlineEnglishActive && !predictions.isEmpty {
            switch event.kind {
            case .tab where !event.modifiers.contains(.shift):
                return acceptPrediction(at: 0)
            case .character where event.modifiers.isEmpty
                && preferences.predictionSelectionShortcut == .digits123
                && !Self.isNumericContextBeforeCursor(currentLeftContext):
                if let idx = predictionDirectPickIndex(for: event.kind),
                   predictions.indices.contains(idx) {
                    return acceptPrediction(at: idx)
                }
                predictions = []
                predictionHighlightedIndex = 0
                dismissedPredictions = true
            case .escape:
                predictions = []
                predictionHighlightedIndex = 0
                pendingPredictionSnapshot = nil
                return [.updateUI(.empty)]
            default:
                predictions = []
                predictionHighlightedIndex = 0
                dismissedPredictions = true
            }
        }

        func prependDismissIfNeeded(_ actions: [InputAction]) -> [InputAction] {
            guard dismissedPredictions else { return actions }
            if actions.contains(where: { if case .updateUI = $0 { return true }; return false }) {
                return actions
            }
            return [.updateUI(.empty)] + actions
        }

        // 5.5 临时英文快车道激活态（大写/驼峰/下划线/Shift+空格触发）：直接缓冲英文并按空格/回车无缝回中文
        if inlineEnglishActive {
            lastCommitRecord = nil
            return prependDismissIfNeeded(handleInlineEnglishKey(event))
        }

        // 5.6 Shift + Space 一键开启「临时英文短句模式」（支持空格/数字/符号，回车上屏并自动回中文）
        if preferences.smartInlineEnglishEnabled,
           event.kind == .space,
           event.modifiers.contains(.shift),
           !current.isComposing,
           composedChineseBuffer.isEmpty,
           inlinePrefixBuffer.isEmpty {
            lastCommitRecord = nil
            return prependDismissIfNeeded(startInlineEnglish(initial: "", allowSpaces: true))
        }

        // 6. 行内语种切换前缀（如 `/ja `、`/en `，以及 `/e ` 临时英文短句）
        if preferences.inlineLanguagePrefixEnabled,
           !current.isComposing,
           composedChineseBuffer.isEmpty,
           let prefixActions = handleInlineLanguagePrefix(event) {
            lastCommitRecord = nil
            return prependDismissIfNeeded(prefixActions)
        }

        // 7. 组合态内控制键处理（含翻译模式下已选词待译的 composedChineseBuffer）
        if current.isComposing || !composedChineseBuffer.isEmpty {
            lastCommitRecord = nil
            return handleComposingKey(event, snapshot: current)
        }

        // 8. 非组合态：先检测 4 秒内连续退格撤销上屏词（负反馈学习）
        if event.kind == .backspace {
            handleIdleBackspaceUndoRegret()
            return prependDismissIfNeeded([.passThrough])
        }

        lastCommitRecord = nil

        // 9. 非组合态：仅拦截英文字母开启中文拼写
        return prependDismissIfNeeded(handleIdleChineseKey(event))
    }

    /// 用户手动点击候选栏中的某一条（0-based）
    public func selectCandidate(at index: Int) -> [InputAction] {
        if inlineEnglishActive {
            guard inlineEnglishCandidates.indices.contains(index) else { return [] }
            return finishInlineEnglishCommit(text: inlineEnglishCandidates[index].text)
        }
        let current = engine.currentSnapshot()
        guard current.isComposing else { return [] }
        return commitSelectedOrAdvance(index: index, snapshot: current)
    }

    /// 用户手动点击或快捷键采纳联想框中的某一条，同步反哺工作记忆与长期搭配库并衔接下一跳联想
    public func acceptPrediction(at index: Int) -> [InputAction] {
        guard predictions.indices.contains(index) else { return [.updateUI(.empty)] }
        let accepted = predictions[index]
        let prevLeft = currentLeftContext
        predictions = []
        predictionHighlightedIndex = 0
        pendingPredictionSnapshot = nil
        sessionToken &+= 1
        lastCommitRecord = nil

        if !accepted.isEmpty, !isSecureInput {
            let now = clock()
            if preferences.enableWorkingMemory, let wm = workingMemory {
                if let promoted = wm.recordCommitted(
                    text: accepted,
                    pinyin: nil,
                    leftContext: prevLeft,
                    appBundleID: activeAppBundleID,
                    isSecureInput: isSecureInput,
                    enableAutoPhrase: preferences.enableAutoPhraseLearning,
                    now: now
                ), preferences.enablePersonalMemory, preferences.enableAutoPhraseLearning {
                    memoryStore?.recordLearnedPhrase(
                        phrase: promoted.phrase,
                        fullPinyin: promoted.fullPinyin,
                        initials: promoted.initials,
                        isSecureInput: isSecureInput,
                        now: now
                    )
                }
            }
            if preferences.enablePersonalMemory {
                memoryStore?.recordSelection(
                    pinyin: "",
                    chosenWord: accepted,
                    selectedRank: 0,
                    skippedTopWord: nil,
                    chosenFeatures: nil,
                    skippedTopFeatures: nil,
                    leftContext: prevLeft,
                    appBundleID: activeAppBundleID,
                    isSecureInput: isSecureInput,
                    now: now
                )
            }
        }

        let allowChainPredict = preferences.enableContinuationPrediction
        return [
            .updateUI(.empty),
            .commitText(text: accepted, requestPredictions: allowChainPredict)
        ]
    }

    public func dismissPredictions() -> [InputAction] {
        guard !predictions.isEmpty else { return [.updateUI(.empty)] }
        predictions = []
        predictionHighlightedIndex = 0
        return [.updateUI(.empty)]
    }

    /// 缓存最近产出的句末预联想短语（6 秒有效，绑定当前左文尾段），
    /// 无论是否弹出联想条，只要用户继续敲下一个字的 1~6 个字母即可 0ms 融进候选栏首位！
    public func cachePredictionsForInlineFusion(
        _ items: [String],
        forLeftContext leftContext: String
    ) {
        guard !isSecureInput, preferences.enableContinuationPrediction else {
            pendingPredictionSnapshot = nil
            return
        }
        let trimmedLeft = leftContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLeft.count >= 2, !items.isEmpty else {
            pendingPredictionSnapshot = nil
            return
        }
        var entries: [(text: String, keys: PinyinNormalizer.TermPinyinKeys)] = []
        entries.reserveCapacity(items.count)
        for item in items.prefix(4) {
            let clean = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            let body = clean.hasPrefix("，") ? String(clean.dropFirst()) : clean
            let keys = pinyinNormalizer.keys(forChineseTerm: body)
            if !keys.fullVariants.isEmpty {
                entries.append((text: clean, keys: keys))
            }
        }
        guard !entries.isEmpty else {
            pendingPredictionSnapshot = nil
            return
        }
        pendingPredictionSnapshot = PendingPredictionSnapshot(
            leftContextTail: String(trimmedLeft.suffix(12)),
            entries: entries,
            timestamp: clock()
        )
    }

    // MARK: - 异步推理回调合入（严格校验 sessionToken）

    public func applyRerankedCandidates(
        _ orderedTexts: [String],
        forToken token: UInt64
    ) -> InputAction? {
        guard token == sessionToken else { return nil }
        let snap = engine.currentSnapshot()
        // 导航冻结锁：一旦用户通过方向键移出首位或已翻页，绝不让异步 L2 重排打断手选！
        guard snap.isComposing, snap.pageNo == 0, highlightedIndex == 0, !orderedTexts.isEmpty else { return nil }

        let base: [RankedCandidateItem]
        if !rankedItems.isEmpty {
            base = rankedItems
        } else {
            base = snap.candidates.enumerated().map { idx, cand in
                RankedCandidateItem(
                    candidate: cand,
                    originalRimeIndex: idx,
                    features: CandidateFeatureVector(rimePrior: max(0.2, 2.40 - 0.55 * log2(Double(idx) + 1.0))),
                    score: 0
                )
            }
        }
        rankedItems = ranker.mergeNeuralOrder(base: base, neuralOrderedTexts: orderedTexts)
        highlightedIndex = min(highlightedIndex, max(0, rankedItems.count - 1))
        return .updateUI(buildPanelSnapshot(from: snap))
    }

    /// 连续分融合 L2 神经重排结果（保留 L1 个人记忆/短期工作记忆/文档锚点分，优化 1–9 位整体顺序，带手选导航冻结锁）
    public func applyRerankedScores(
        _ scoredCandidates: [ScoredCandidate],
        forToken token: UInt64
    ) -> InputAction? {
        guard token == sessionToken else { return nil }
        let snap = engine.currentSnapshot()
        // 导航冻结锁：用户已手动移动高亮（highlightedIndex > 0）或已翻页（pageNo > 0）时，冻结列表绝不抢光标
        guard snap.isComposing, snap.pageNo == 0, highlightedIndex == 0, !scoredCandidates.isEmpty else { return nil }

        let base: [RankedCandidateItem]
        if !rankedItems.isEmpty {
            base = rankedItems
        } else {
            base = snap.candidates.enumerated().map { idx, cand in
                RankedCandidateItem(
                    candidate: cand,
                    originalRimeIndex: idx,
                    features: CandidateFeatureVector(rimePrior: max(0.2, 2.40 - 0.55 * log2(Double(idx) + 1.0))),
                    score: 0
                )
            }
        }
        let learnedNeuralWeight = memoryStore?.currentWeights().neuralContext ?? 0.85
        rankedItems = ranker.mergeNeuralScores(
            base: base,
            scoredCandidates: scoredCandidates,
            neuralWeight: learnedNeuralWeight
        )
        highlightedIndex = min(highlightedIndex, max(0, rankedItems.count - 1))
        return .updateUI(buildPanelSnapshot(from: snap))
    }

    public func applyTranslationPreview(
        _ preview: TranslationPreviewState,
        modelLabel: String? = nil,
        forToken token: UInt64
    ) -> InputAction? {
        guard token == sessionToken else { return nil }
        let snap = engine.currentSnapshot()
        guard snap.isComposing || !composedChineseBuffer.isEmpty else { return nil }
        translationPreview = preview
        if let modelLabel { activeModelLabel = modelLabel }
        return .updateUI(buildPanelSnapshot(from: snap))
    }

    public func applyPredictions(
        _ items: [String],
        modelLabel: String? = nil,
        forToken token: UInt64
    ) -> InputAction? {
        guard token == sessionToken else { return nil }
        guard !engine.currentSnapshot().isComposing, composedChineseBuffer.isEmpty, !items.isEmpty else { return nil }
        cachePredictionsForInlineFusion(items, forLeftContext: currentLeftContext)
        guard preferences.predictionDisplayStyle == .barAndInlineFusion else { return nil }
        predictions = items
        predictionHighlightedIndex = 0
        if let modelLabel { activeModelLabel = modelLabel }
        return .updateUI(buildPredictionPanelSnapshot())
    }

    private func buildPredictionPanelSnapshot() -> CandidatePanelSnapshot {
        let allowDirectDigits = preferences.predictionSelectionShortcut == .digits123
            && !Self.isNumericContextBeforeCursor(currentLeftContext)
        return CandidatePanelSnapshot(
            isVisible: true,
            mode: mode,
            preedit: "",
            selectedText: "",
            candidates: [],
            highlightedIndex: 0,
            pageNo: 0,
            hasNextPage: false,
            showTranslationBar: false,
            translationSourcePreview: "",
            translationPreview: .hidden,
            predictions: predictions,
            predictionHighlightedIndex: min(max(0, predictionHighlightedIndex), max(0, predictions.count - 1)),
            predictionDirectDigitSelect: allowDirectDigits,
            activeModelLabel: activeModelLabel
        )
    }

    private func matchingPendingPredictions(
        for rawPinyin: String,
        leftContext: String
    ) -> [PendingPredictionCandidate] {
        guard !isSecureInput,
              preferences.enableContinuationPrediction,
              let snap = pendingPredictionSnapshot
        else { return [] }
        let now = clock()
        guard (now - snap.timestamp) <= 6.0 else {
            pendingPredictionSnapshot = nil
            return []
        }
        let trimmedLeft = leftContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLeft.hasSuffix(snap.leftContextTail) else {
            return []
        }
        let query = rawPinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
        guard !query.isEmpty, query.count <= 12 else { return [] }

        var matched: [PendingPredictionCandidate] = []
        for (idx, entry) in snap.entries.enumerated() {
            let res = PinyinNormalizer.matchChinese(query: query, keys: entry.keys)
            guard res.strength > 0 else { continue }
            matched.append(PendingPredictionCandidate(
                text: entry.text,
                rankIndex: idx,
                matchStrength: res.strength
            ))
        }
        return matched
    }

    /// 音节级拼音自动纠偏 + Shadow Rime 探针查词（带 128 项轻量缓存与词典真实词校验，过滤生拼伪词）
    private func collectTypoCandidates(
        rawPinyin: String,
        preedit: String
    ) -> [TypoCorrectedCandidate] {
        guard preferences.enableAutoCorrection,
              !isSecureInput,
              rawPinyin.count >= 4,
              rawPinyin.count <= 20
        else { return [] }

        let suggestions = typoCorrector.suggestCorrections(
            rawPinyin: rawPinyin,
            preedit: preedit,
            enableNasalCompletion: preferences.fuzzyNasalPinyin,
            maxSuggestions: 5
        )
        guard !suggestions.isEmpty else { return [] }

        struct EvaluatedSuggestion {
            let suggestion: PinyinCorrectionSuggestion
            let exactWords: [String]
            let memoryWords: [String]
            let isSuspiciousSingleton: Bool
            let qualityScore: Double
            let effectiveEditCost: Double
        }

        var evaluated: [EvaluatedSuggestion] = []
        evaluated.reserveCapacity(suggestions.count)

        for sug in suggestions {
            let probed: [PinyinCandidate]
            if let cached = typoProbeCache[sug.correctedPinyin] {
                probed = cached
            } else {
                let fresh = engine.probeCandidates(forPinyin: sug.correctedPinyin, limit: 5)
                if typoProbeCache.count >= 128 {
                    typoProbeCache.removeAll(keepingCapacity: true)
                }
                if !fresh.isEmpty {
                    typoProbeCache[sug.correctedPinyin] = fresh
                }
                probed = fresh
            }

            // 严格校验探针返回词：必须为完整纯汉字词且拼音精确匹配 correctedPinyin，
            // 自动过滤 Rime 补全残词（如 shaiguai 返回的「晒谷」实为 shaigu）与单字降级项；
            // 同音词密度同时认可前后鼻音模糊词（如 women 伴随「我萌/我盟」），防止误伤真实高频词
            let expectedChars = sug.syllables.count
            let normalizedTargetNasal = Self.foldNasalFinals(sug.correctedPinyin)
            var exactWords: [String] = []
            var seenExact = Set<String>()
            var nasalDensityCount = 0
            for cand in probed {
                guard cand.text.count == expectedChars,
                      Self.isPureHanzi(cand.text)
                else { continue }
                let keys = pinyinNormalizer.keys(forChineseTerm: cand.text)
                if keys.fullVariants.contains(sug.correctedPinyin) {
                    if seenExact.insert(cand.text).inserted {
                        exactWords.append(cand.text)
                        nasalDensityCount += 1
                    }
                } else if keys.fullVariants.contains(where: { Self.foldNasalFinals($0) == normalizedTargetNasal }) {
                    nasalDensityCount += 1
                }
            }

            var memWords: [String] = []
            if preferences.enablePersonalMemory, let mem = memoryStore {
                for w in mem.topPreferredWords(forPinyin: sug.correctedPinyin, limit: 2)
                where w.count == expectedChars && Self.isPureHanzi(w) {
                    memWords.append(w)
                }
            }

            guard !exactWords.isEmpty || !memWords.isEmpty else { continue }

            let realWordDensity = max(exactWords.count, nasalDensityCount)
            // 2 字拼写若词典中连 2 个同音/鼻音实词都没有、无个人记忆背书且属于较高代价替换（>0.55），多为生拼单字组合（如 shaiguai -> 晒怪）；
            // 低代价单步转置/去连键（<=0.55，如 womne -> women）不受此限，即使关闭模糊音也能稳定召回「我们」
            let isSuspiciousSingleton = (expectedChars == 2 && realWordDensity < 2 && memWords.isEmpty && sug.editCost > 0.55)
            let dictBonus: Double
            if expectedChars == 2 {
                if realWordDensity >= 3 {
                    dictBonus = 0.90
                } else if realWordDensity == 2 {
                    dictBonus = 0.55
                } else {
                    dictBonus = -0.55
                }
            } else {
                dictBonus = realWordDensity >= 2 ? 0.65 : 0.20
            }
            let memBonus = memWords.isEmpty ? 0.0 : 1.10
            let qualityScore = dictBonus + memBonus - sug.editCost
            let effectiveCost = max(0.12, sug.editCost - max(0, dictBonus) * 0.45 - (memWords.isEmpty ? 0.0 : 0.30))

            evaluated.append(EvaluatedSuggestion(
                suggestion: sug,
                exactWords: exactWords,
                memoryWords: memWords,
                isSuspiciousSingleton: isSuspiciousSingleton,
                qualityScore: qualityScore,
                effectiveEditCost: effectiveCost
            ))
        }

        guard !evaluated.isEmpty else { return [] }
        let hasConfirmedRealWord = evaluated.contains { !$0.isSuspiciousSingleton }
        let filtered = hasConfirmedRealWord
            ? evaluated.filter { !$0.isSuspiciousSingleton }
            : evaluated
        let ordered = filtered.sorted { lhs, rhs in
            if abs(lhs.qualityScore - rhs.qualityScore) > 1e-6 {
                return lhs.qualityScore > rhs.qualityScore
            }
            if lhs.exactWords.count != rhs.exactWords.count {
                return lhs.exactWords.count > rhs.exactWords.count
            }
            return lhs.suggestion.correctedPinyin < rhs.suggestion.correctedPinyin
        }

        var results: [TypoCorrectedCandidate] = []
        var seenText = Set<String>()

        // 先取最优纠偏方案的 Top-1，若有第二优真实词方案再取其 Top-1，否则补最优方案 Top-2
        for eval in ordered.prefix(2) {
            let preferredPool = eval.memoryWords + eval.exactWords
            for (rankIdx, word) in preferredPool.prefix(1).enumerated() {
                guard seenText.insert(word).inserted else { continue }
                results.append(TypoCorrectedCandidate(
                    text: word,
                    correctedPinyin: eval.suggestion.correctedPinyin,
                    rankInProbe: rankIdx,
                    editCost: eval.effectiveEditCost,
                    isFragmentedSource: eval.suggestion.isFragmentedSource
                ))
            }
        }
        if results.count < 2, let best = ordered.first {
            let preferredPool = best.memoryWords + best.exactWords
            for (rankIdx, word) in preferredPool.prefix(3).enumerated() where results.count < 2 {
                guard seenText.insert(word).inserted else { continue }
                results.append(TypoCorrectedCandidate(
                    text: word,
                    correctedPinyin: best.suggestion.correctedPinyin,
                    rankInProbe: max(1, rankIdx),
                    editCost: best.effectiveEditCost,
                    isFragmentedSource: best.suggestion.isFragmentedSource
                ))
            }
        }
        return results
    }

    private static func foldNasalFinals(_ pinyin: String) -> String {
        pinyin
            .replacingOccurrences(of: "ang", with: "an")
            .replacingOccurrences(of: "eng", with: "en")
            .replacingOccurrences(of: "ing", with: "in")
    }

    private static func isPureHanzi(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isCJK = (v >= 0x4E00 && v <= 0x9FFF)
                || (v >= 0x3400 && v <= 0x4DBF)
                || (v >= 0x20000 && v <= 0x2A6DF)
            if !isCJK { return false }
        }
        return true
    }

    /// 识别光标前是否处于数字/日期/金额/版本号输入语境，避免 1/2/3 联想直选误伤正常数字输入
    public static func isNumericContextBeforeCursor(_ leftContext: String) -> Bool {
        let trimmed = leftContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        if last.isNumber { return true }
        let numericPunct: Set<Character> = [".", ":", "/", "-", "+", "#", "¥", "$", "€", "£", "%", "=", "×", "÷"]
        if numericPunct.contains(last) { return true }
        let numericSuffixes = [
            "第", "共", "约", "满", "减", "版本", "端口", "编号", "价格", "金额",
            "今年", "明年", "去年", "公元", "序号", "编号", "v", "V", "port", "Port"
        ]
        return numericSuffixes.contains { trimmed.hasSuffix($0) }
    }

    private func predictionDirectPickIndex(for kind: NormalizedKeyEvent.Kind) -> Int? {
        guard case .character(let ch, let keyCode) = kind else { return nil }
        switch keyCode {
        case 18: return 0
        case 19: return 1
        case 20: return 2
        case 21: return 3
        default: break
        }
        if ch.count == 1, let digit = Int(ch), digit >= 1 && digit <= 4 {
            return digit - 1
        }
        return nil
    }

    // MARK: - 私有处理逻辑

    private func matchesGlobalDisableTranslateShortcut(_ event: NormalizedKeyEvent) -> Bool {
        let shortcut = preferences.globalDisableTranslateShortcut
        guard shortcut != .off else { return false }
        guard case .character(let ch, let keyCode) = event.kind,
              (keyCode == 17 || ch.lowercased() == "t")
        else { return false }

        switch shortcut {
        case .controlOptionT:
            return event.modifiers == [.control, .option]
        case .optionShiftT:
            return event.modifiers == [.option, .shift]
        case .controlShiftT:
            return event.modifiers == [.control, .shift]
        case .off:
            return false
        }
    }

    /// 强制全局关闭翻译模式（绝不误开，保留正在拼写的拼音，跨窗口广播同步）
    public func disableGlobalTranslateMode() -> [InputAction] {
        preferences.defaultTranslateMode = false
        inlineOverrideTarget = nil
        suppressTranslateForCurrentSentence = false
        lastComposingTabTimestamp = 0
        globalTranslateBeforeLastTab = false
        isLanguagePickerOpen = false
        translationPreview = .hidden
        if case .translateOnCommit = mode {
            mode = .chinesePinyin
        }

        let persist = InputAction.persistPreferencesChange(
            translateMode: false,
            targetLanguage: nil,
            codingMode: nil,
            chinesePunctuation: nil
        )
        let snap = engine.currentSnapshot()
        if snap.isComposing {
            return [.cancelPendingInference, persist, .updateUI(buildPanelSnapshot(from: snap))]
        }
        if !composedChineseBuffer.isEmpty {
            let text = composedChineseBuffer
            composedChineseBuffer = ""
            rankedItems = []
            highlightedIndex = 0
            return [.cancelPendingInference, persist, .updateUI(.empty), .commitText(text: text, requestPredictions: false)]
        }
        return [.cancelPendingInference, persist, .updateUI(.empty)]
    }

    private func handleOptionShortcut(_ event: NormalizedKeyEvent) -> [InputAction] {
        switch event.kind {
        case .character(let ch, _) where ch.lowercased() == "t":
            guard preferences.enableTranslateHotkeys else { return [.passThrough] }
            let willEnable: Bool
            if case .translateOnCommit = mode {
                willEnable = false
            } else {
                willEnable = true
            }
            preferences.defaultTranslateMode = willEnable
            let actions = setTranslateMode(enabled: willEnable)
            return [.persistPreferencesChange(
                translateMode: willEnable,
                targetLanguage: nil,
                codingMode: nil,
                chinesePunctuation: nil
            )] + actions

        case .character(let ch, _) where ch.lowercased() == "l":
            guard preferences.enableTranslateHotkeys else { return [.passThrough] }
            let nextLang = preferredTargetLanguage.next
            preferences.defaultTargetLanguage = nextLang
            let actions = setTargetLanguage(nextLang)
            return [.persistPreferencesChange(
                translateMode: nil,
                targetLanguage: nextLang,
                codingMode: nil,
                chinesePunctuation: nil
            )] + actions

        case .tab:
            // 拼写态按 Option+Tab：确定性一键切换全局持续翻译开关（空态完全放行给宿主 App）
            let snap = engine.currentSnapshot()
            guard snap.isComposing || !composedChineseBuffer.isEmpty else { return [.passThrough] }
            let isCurrentlyGlobal = (mode.translationTarget != nil && !suppressTranslateForCurrentSentence)
            return setPersistentTranslateInComposition(enabled: !isCurrentlyGlobal, snapshot: snap)

        case .returnKey:
            // Option+Return：在译文模式下强制上屏中文原文
            let snap = engine.currentSnapshot()
            guard snap.isComposing || !composedChineseBuffer.isEmpty else { return [.passThrough] }
            let chinese = fullComposedChinese(from: snap)
            return finishCommit(text: chinese, requestPredictions: true, recordedPinyin: activeSegmentPinyin(from: snap))

        default:
            return [.passThrough]
        }
    }

    private func toggleChineseEnglish() -> [InputAction] {
        let snap = engine.currentSnapshot()
        var actions: [InputAction] = []
        if inlineEnglishActive {
            let pending = inlineEnglishBuffer
            inlineEnglishActive = false
            inlineEnglishAllowsSpaces = false
            inlineEnglishBuffer = ""
            inlineEnglishCandidates = []
            highlightedIndex = 0
            sessionToken &+= 1
            actions.append(.updateUI(.empty))
            if !pending.isEmpty {
                actions.append(.commitText(text: pending, requestPredictions: false))
            }
        } else if snap.isComposing || !composedChineseBuffer.isEmpty {
            let raw = composedChineseBuffer + (snap.rawInput.isEmpty ? snap.preedit : snap.rawInput)
            engine.clearComposition()
            composedChineseBuffer = ""
            rankedItems = []
            highlightedIndex = 0
            translationPreview = .hidden
            inlineOverrideTarget = nil
            sessionToken &+= 1
            actions.append(.cancelPendingInference)
            actions.append(.updateUI(.empty))
            if !raw.isEmpty {
                actions.append(.commitText(text: raw, requestPredictions: false))
            }
        }
        if case .directEnglish = mode {
            mode = preferences.defaultTranslateMode
                ? .translateOnCommit(preferredTargetLanguage)
                : .chinesePinyin
        } else {
            mode = .directEnglish
        }
        return actions.isEmpty ? [.updateUI(.empty)] : actions
    }

    private func handleInlineLanguagePrefix(_ event: NormalizedKeyEvent) -> [InputAction]? {
        if inlinePrefixBuffer.isEmpty {
            if case .character("/", _) = event.kind {
                inlinePrefixBuffer = "/"
                return [.updateUI(CandidatePanelSnapshot(
                    isVisible: true,
                    mode: mode,
                    preedit: "/  (t 译文 · en/ja/ko/fr/de/es 语种 · e 英文 · code 标点)",
                    isCodingModeActive: isEffectiveCodingMode,
                    activeModelLabel: "输入指令后按空格"
                ))]
            }
            return nil
        }

        switch event.kind {
        case .escape:
            inlinePrefixBuffer = ""
            return [.updateUI(.empty)]
        case .backspace:
            inlinePrefixBuffer.removeLast()
            if inlinePrefixBuffer.isEmpty {
                return [.updateUI(.empty)]
            }
            return [.updateUI(CandidatePanelSnapshot(
                isVisible: true,
                mode: mode,
                preedit: inlinePrefixBuffer,
                isCodingModeActive: isEffectiveCodingMode
            ))]
        case .space:
            let code = String(inlinePrefixBuffer.dropFirst()).lowercased()
            inlinePrefixBuffer = ""
            if preferences.smartInlineEnglishEnabled && code == "e" {
                return startInlineEnglish(initial: "", allowSpaces: true)
            }
            if code == "t" {
                let willEnable = (mode.translationTarget == nil)
                preferences.defaultTranslateMode = willEnable
                suppressTranslateForCurrentSentence = false
                inlineOverrideTarget = nil
                if willEnable {
                    mode = .translateOnCommit(preferredTargetLanguage)
                } else {
                    mode = .chinesePinyin
                    translationPreview = .hidden
                }
                return [
                    .persistPreferencesChange(
                        translateMode: willEnable,
                        targetLanguage: nil,
                        codingMode: nil,
                        chinesePunctuation: nil
                    ),
                    .updateUI(.empty)
                ]
            }
            if code == "code" {
                let willEnable = !preferences.codingModeEnabled
                preferences.codingModeEnabled = willEnable
                return [
                    .persistPreferencesChange(
                        translateMode: nil,
                        targetLanguage: nil,
                        codingMode: willEnable,
                        chinesePunctuation: nil
                    ),
                    .updateUI(.empty)
                ]
            }
            if code == "p" {
                let nextZhPunct = !preferences.chinesePunctuation
                preferences.chinesePunctuation = nextZhPunct
                return [
                    .persistPreferencesChange(
                        translateMode: nil,
                        targetLanguage: nil,
                        codingMode: nil,
                        chinesePunctuation: nextZhPunct
                    ),
                    .updateUI(.empty)
                ]
            }
            if let lang = TargetLanguage.fromInlinePrefix(code) {
                suppressTranslateForCurrentSentence = false
                inlineOverrideTarget = lang
                var actions: [InputAction] = []
                if preferences.inlinePrefixPersistsLanguage {
                    preferredTargetLanguage = lang
                    preferences.defaultTargetLanguage = lang
                    if case .translateOnCommit = mode {
                        mode = .translateOnCommit(lang)
                    }
                    actions.append(.persistPreferencesChange(
                        translateMode: nil,
                        targetLanguage: lang,
                        codingMode: nil,
                        chinesePunctuation: nil
                    ))
                }
                actions.append(.updateUI(CandidatePanelSnapshot(
                    isVisible: true,
                    mode: .translateOnCommit(lang),
                    preedit: "[\(lang.shortBadge)] ",
                    showTranslationBar: true,
                    translationSourcePreview: "",
                    translationPreview: .hidden,
                    isCodingModeActive: isEffectiveCodingMode,
                    activeModelLabel: "翻译目标：\(lang.displayName)"
                )))
                return actions
            }
            return [.updateUI(.empty), .commitText(text: "/\(code) ", requestPredictions: false)]
        case .character(let ch, _) where ch.count == 1 && ch.unicodeScalars.first.map({ $0.value >= 97 && $0.value <= 122 }) == true:
            // 仅收集小写指令字母（最多 4 位如 code）；大写路径 /Users 或注释 // 直接落入 default 原样放行！
            if inlinePrefixBuffer.count <= 4 {
                inlinePrefixBuffer.append(ch)
                return [.updateUI(CandidatePanelSnapshot(
                    isVisible: true,
                    mode: mode,
                    preedit: inlinePrefixBuffer,
                    isCodingModeActive: isEffectiveCodingMode,
                    activeModelLabel: "空格确认指令"
                ))]
            }
            let flush = inlinePrefixBuffer + ch
            inlinePrefixBuffer = ""
            return [.updateUI(.empty), .commitText(text: flush, requestPredictions: false)]
        case .character(let ch, _):
            let flush = inlinePrefixBuffer + ch
            inlinePrefixBuffer = ""
            return [.updateUI(.empty), .commitText(text: flush, requestPredictions: false)]
        default:
            let flush = inlinePrefixBuffer
            inlinePrefixBuffer = ""
            return [.updateUI(.empty), .commitText(text: flush, requestPredictions: false), .passThrough]
        }
    }

    private func handleComposingKey(
        _ event: NormalizedKeyEvent,
        snapshot: PinyinEngineSnapshot
    ) -> [InputAction] {
        let effectiveTarget = effectiveTranslationTarget
        let isPlainTab = (event.kind == .tab && !event.modifiers.contains(.shift))
        if !isPlainTab {
            lastComposingTabTimestamp = 0
        }

        switch event.kind {
        case .escape:
            return resetSession()

        case .tab:
            if event.modifiers.contains(.shift) {
                // Shift+Tab：拼写态原地快速切换下一个翻译目标语种并持久化（未开翻译栏时自动展开）
                let nextLang = preferredTargetLanguage.next
                preferredTargetLanguage = nextLang
                preferences.defaultTargetLanguage = nextLang
                suppressTranslateForCurrentSentence = false
                if case .translateOnCommit = mode {
                    mode = .translateOnCommit(nextLang)
                } else {
                    inlineOverrideTarget = nextLang
                }
                return [
                    .persistPreferencesChange(
                        translateMode: nil,
                        targetLanguage: nextLang,
                        codingMode: nil,
                        chinesePunctuation: nil
                    )
                ] + refreshAfterModeChange()
            }
            return toggleTranslateDuringComposition(snapshot: snapshot)

        case .returnKey:
            if let target = effectiveTarget {
                let source = fullComposedChinese(from: snapshot)
                // 翻译模式下：Shift+Return 强制上屏中文原文；普通 Return 直接上屏译文
                if event.modifiers.contains(.shift) {
                    return finishCommit(text: source, requestPredictions: true, recordedPinyin: activeSegmentPinyin(from: snapshot))
                }
                let cached = readyCachedTranslation(for: source, target: target)
                return finishTranslationCommit(sourceText: source, target: target, cached: cached)
            }
            // 普通中文模式：Shift+Return 一键译文上屏
            if preferences.shiftReturnQuickTranslate && event.modifiers.contains(.shift) {
                let target = preferredTargetLanguage
                let source = fullComposedChinese(from: snapshot)
                let cached = readyCachedTranslation(for: source, target: target)
                return finishTranslationCommit(sourceText: source, target: target, cached: cached)
            }
            switch preferences.returnKeyBehavior {
            case .commitRawInput:
                let raw = snapshot.rawInput.isEmpty ? snapshot.preedit : snapshot.rawInput
                return finishCommit(text: raw, requestPredictions: false, recordedPinyin: nil)
            case .commitFirstCandidate:
                let chosen = fullComposedChinese(from: snapshot)
                return finishCommit(text: chosen, requestPredictions: true, recordedPinyin: activeSegmentPinyin(from: snapshot))
            }

        case .space:
            // 拼写原始英文串时按 Shift+Space：直接转为带空格的临时英文短句（如 git + Shift+Space -> "git "）
            if preferences.smartInlineEnglishEnabled,
               event.modifiers.contains(.shift),
               snapshot.isComposing,
               snapshot.selectedPrefix.isEmpty,
               composedChineseBuffer.isEmpty {
                let raw = snapshot.rawInput.isEmpty ? snapshot.preedit : snapshot.rawInput
                engine.clearComposition()
                rankedItems = []
                highlightedIndex = 0
                translationPreview = .hidden
                return [.cancelPendingInference] + startInlineEnglish(initial: raw + " ", allowSpaces: true)
            }
            if let target = effectiveTarget {
                // 拼句模式下（或用户主动配置）：空格先选词拼入中文整句，回车上屏整句译文
                if preferences.translateSpaceBehavior == .composeChineseSegment, snapshot.isComposing {
                    return commitSelectedOrAdvance(index: highlightedIndex, snapshot: snapshot)
                }
                // 默认方案 B：先实时展示译文，按空格直接上屏译文，仅用数字键 1–9 选词拼句纠错
                let source = fullComposedChinese(from: snapshot)
                guard !source.isEmpty else { return [.passThrough] }
                recordImplicitAcceptanceIfTopCandidate(snapshot: snapshot)
                let cached = readyCachedTranslation(for: source, target: target)
                return finishTranslationCommit(sourceText: source, target: target, cached: cached)
            }
            return commitSelectedOrAdvance(index: highlightedIndex, snapshot: snapshot)

        case .character(let ch, _) where ch.count == 1 && ch >= "1" && ch <= "9":
            if snapshot.isComposing {
                let idx = Int(ch)! - 1
                return commitSelectedOrAdvance(index: idx, snapshot: snapshot)
            }
            // 若翻译模式下已选完中文等待上屏，输入数字直接拼入待译中文句
            if effectiveTarget != nil, !composedChineseBuffer.isEmpty {
                composedChineseBuffer.append(ch)
                return refreshComposedTranslationBuffer()
            }
            return [.passThrough]

        case .character("-", _), .pageUp:
            guard snapshot.isComposing else { return [.passThrough] }
            let nextSnap = engine.changePage(forward: false)
            return afterEngineUpdate(nextSnap)

        case .character("=", _), .pageDown:
            guard snapshot.isComposing else { return [.passThrough] }
            let nextSnap = engine.changePage(forward: true)
            return afterEngineUpdate(nextSnap)

        case .arrowDown, .arrowRight:
            guard snapshot.isComposing else { return [.passThrough] }
            return moveHighlight(delta: 1, snapshot: snapshot)

        case .arrowUp, .arrowLeft:
            guard snapshot.isComposing else { return [.passThrough] }
            return moveHighlight(delta: -1, snapshot: snapshot)

        case .backspace:
            if snapshot.isComposing {
                let (_, nextSnap) = engine.processKey(keyval: 0xff08, mask: 0) // XK_BackSpace
                if !nextSnap.isComposing && !composedChineseBuffer.isEmpty {
                    rankedItems = []
                    highlightedIndex = 0
                    return refreshComposedTranslationBuffer()
                }
                return afterEngineUpdate(nextSnap)
            }
            if !composedChineseBuffer.isEmpty {
                composedChineseBuffer.removeLast()
                if composedChineseBuffer.isEmpty {
                    return resetSession()
                }
                return refreshComposedTranslationBuffer()
            }
            return [.passThrough]

        case .character(let ch, _):
            guard let scalar = ch.unicodeScalars.first else { return [.passThrough] }
            if snapshot.isComposing {
                // 驼峰命名（如 useState / macOS / iOS）或下划线标识符（如 user_id / max_tokens）自动无感转入临时英文
                if preferences.smartInlineEnglishEnabled,
                   snapshot.selectedPrefix.isEmpty,
                   composedChineseBuffer.isEmpty,
                   ch.count == 1,
                   ((scalar.value >= 65 && scalar.value <= 90) || scalar.value == 95) {
                    let raw = snapshot.rawInput.isEmpty ? snapshot.preedit : snapshot.rawInput
                    engine.clearComposition()
                    rankedItems = []
                    highlightedIndex = 0
                    translationPreview = .hidden
                    return [.cancelPendingInference] + startInlineEnglish(initial: raw + ch, allowSpaces: false)
                }
                // 标点符号结束当前拼写段：交由 SmartPunctuationEngine 统一产出与空态 100% 一致的中文/英文标点
                if SmartPunctuationEngine.isMappedPunctuationKey(ch) {
                    let chinese = fullComposedChinese(from: snapshot)
                    if effectiveTarget != nil {
                        recordImplicitAcceptanceIfTopCandidate(snapshot: snapshot)
                        engine.clearComposition()
                        rankedItems = []
                        highlightedIndex = 0
                        let punct = punctuationEngine.mapPunctuation(
                            ch,
                            context: .init(
                                mode: mode,
                                preferences: preferences,
                                appBundleID: activeAppBundleID,
                                leftContext: currentLeftContext + chinese,
                                isInsideChineseTranslationBuffer: true
                            )
                        ) ?? ch
                        composedChineseBuffer = chinese + punct
                        return refreshComposedTranslationBuffer()
                    }
                    recordImplicitAcceptanceIfTopCandidate(snapshot: snapshot)
                    let punct = punctuationEngine.mapPunctuation(
                        ch,
                        context: .init(
                            mode: mode,
                            preferences: preferences,
                            appBundleID: activeAppBundleID,
                            leftContext: currentLeftContext + chinese
                        )
                    ) ?? ch
                    return finishCommit(
                        text: chinese + punct,
                        requestPredictions: false,
                        recordedPinyin: activeSegmentPinyin(from: snapshot)
                    )
                }
                let (_, nextSnap) = engine.processKey(keyval: Int32(scalar.value), mask: 0)
                return afterEngineUpdate(nextSnap)
            }
            // 翻译模式下已有 composedChineseBuffer，继续敲字母开启下一段中文拼写
            if scalar.value >= 97 && scalar.value <= 122 {
                let (handled, nextSnap) = engine.processKey(keyval: Int32(scalar.value), mask: 0)
                if handled {
                    return afterEngineUpdate(nextSnap)
                }
            }
            // 标点等直接追加到待译中文句中并刷新译文
            if effectiveTarget != nil, !composedChineseBuffer.isEmpty {
                let mapped = punctuationEngine.mapPunctuation(
                    ch,
                    context: .init(
                        mode: mode,
                        preferences: preferences,
                        appBundleID: activeAppBundleID,
                        leftContext: currentLeftContext + composedChineseBuffer,
                        isInsideChineseTranslationBuffer: true
                    )
                ) ?? ch
                composedChineseBuffer.append(mapped)
                return refreshComposedTranslationBuffer()
            }
            return [.passThrough]

        default:
            return [.passThrough]
        }
    }

    private func handleIdleChineseKey(_ event: NormalizedKeyEvent) -> [InputAction] {
        if event.kind == .returnKey {
            punctuationEngine.resetQuotePairing()
            return [.passThrough]
        }
        guard case .character(let ch, _) = event.kind,
              let scalar = ch.unicodeScalars.first
        else {
            return [.passThrough]
        }

        // 小写英文字母开启中文拼写；大写英文字母在开启快车道时直接进入临时英文（如 React / T3 / App.tsx）
        if scalar.value >= 97 && scalar.value <= 122 {
            let (handled, snap) = engine.processKey(keyval: Int32(scalar.value), mask: 0)
            if handled {
                return afterEngineUpdate(snap)
            }
        } else if preferences.smartInlineEnglishEnabled,
                  ch.count == 1,
                  scalar.value >= 65 && scalar.value <= 90 {
            return startInlineEnglish(initial: ch, allowSpaces: false)
        } else if SmartPunctuationEngine.isMappedPunctuationKey(ch) {
            if let mapped = punctuationEngine.mapPunctuation(
                ch,
                context: .init(
                    mode: mode,
                    preferences: preferences,
                    appBundleID: activeAppBundleID,
                    leftContext: currentLeftContext
                )
            ) {
                return [.commitText(text: mapped, requestPredictions: false)]
            }
        }
        return [.passThrough]
    }

    // MARK: - 拼写态 Tab 快切译文 & 1–6 语种直选条

    private func toggleTranslateDuringComposition(snapshot: PinyinEngineSnapshot) -> [InputAction] {
        if preferences.composingTabBehavior == .togglePersistentMode {
            let willEnable = (effectiveTranslationTarget == nil)
            return setPersistentTranslateInComposition(enabled: willEnable, snapshot: snapshot)
        }

        // 快速双击 Tab（≤ 320ms）：将本句译文直接升格锁定为全局，或彻底关闭全局翻译开关
        let now = clock()
        if preferences.doubleTabTogglesGlobalTranslate,
           lastComposingTabTimestamp > 0,
           (now - lastComposingTabTimestamp) <= 0.32 {
            lastComposingTabTimestamp = 0
            return setPersistentTranslateInComposition(enabled: !globalTranslateBeforeLastTab, snapshot: snapshot)
        }

        lastComposingTabTimestamp = now
        globalTranslateBeforeLastTab = (mode.translationTarget != nil)

        // 默认单按 Tab：仅对当前这一句临时展开/隐藏翻译栏，不修改全局持久翻译开关
        if effectiveTranslationTarget != nil {
            if inlineOverrideTarget != nil {
                inlineOverrideTarget = nil
            } else {
                suppressTranslateForCurrentSentence = true
            }
            translationPreview = .hidden
            return [.cancelPendingInference, .updateUI(buildPanelSnapshot(from: snapshot))]
        } else {
            suppressTranslateForCurrentSentence = false
            inlineOverrideTarget = preferredTargetLanguage
            return refreshAfterModeChange()
        }
    }

    private func setPersistentTranslateInComposition(
        enabled: Bool,
        snapshot: PinyinEngineSnapshot
    ) -> [InputAction] {
        let activeTarget = inlineOverrideTarget ?? preferredTargetLanguage
        preferredTargetLanguage = activeTarget
        preferences.defaultTranslateMode = enabled
        suppressTranslateForCurrentSentence = false
        inlineOverrideTarget = nil
        lastComposingTabTimestamp = 0

        let persist = InputAction.persistPreferencesChange(
            translateMode: enabled,
            targetLanguage: nil,
            codingMode: nil,
            chinesePunctuation: nil
        )
        if enabled {
            mode = .translateOnCommit(activeTarget)
            return [persist] + refreshAfterModeChange()
        } else {
            mode = .chinesePinyin
            translationPreview = .hidden
            if snapshot.isComposing {
                return [.cancelPendingInference, persist, .updateUI(buildPanelSnapshot(from: snapshot))]
            }
            if !composedChineseBuffer.isEmpty {
                let text = composedChineseBuffer
                composedChineseBuffer = ""
                rankedItems = []
                highlightedIndex = 0
                return [.cancelPendingInference, persist, .updateUI(.empty), .commitText(text: text, requestPredictions: false)]
            }
            return [.cancelPendingInference, persist, .updateUI(.empty)]
        }
    }

    private func handleLanguagePickerKey(_ event: NormalizedKeyEvent) -> [InputAction]? {
        let all = TargetLanguage.allCases
        switch event.kind {
        case .escape:
            isLanguagePickerOpen = false
            return [refreshUIOnlyAfterPickerClose()]
        case .character(let ch, _) where ch.count == 1 && ch >= "1" && ch <= "6":
            if let num = Int(ch), all.indices.contains(num - 1) {
                return selectTargetLanguageFromPicker(all[num - 1])
            }
            return nil
        case .arrowRight, .arrowDown:
            languagePickerIndex = (languagePickerIndex + 1) % all.count
            return [.updateUI(buildPanelWithLanguagePicker())]
        case .arrowLeft, .arrowUp:
            languagePickerIndex = (languagePickerIndex - 1 + all.count) % all.count
            return [.updateUI(buildPanelWithLanguagePicker())]
        case .space, .returnKey:
            let lang = all.indices.contains(languagePickerIndex) ? all[languagePickerIndex] : preferredTargetLanguage
            return selectTargetLanguageFromPicker(lang)
        default:
            // 用户直接开始敲字：自动收起语种条并交回正常输入流程
            isLanguagePickerOpen = false
            return nil
        }
    }

    private func buildPanelWithLanguagePicker() -> CandidatePanelSnapshot {
        let snap = engine.currentSnapshot()
        if snap.isComposing || !composedChineseBuffer.isEmpty {
            return buildPanelSnapshot(from: snap)
        }
        return CandidatePanelSnapshot(
            isVisible: true,
            mode: mode,
            preedit: "选择翻译目标语言（按 1–6 直选 · Esc 取消）",
            showTranslationBar: false,
            showLanguagePicker: true,
            languagePickerHighlightedIndex: languagePickerIndex,
            isCodingModeActive: isEffectiveCodingMode,
            activeModelLabel: "1–6 直选目标语种"
        )
    }

    private func refreshUIOnlyAfterPickerClose() -> InputAction {
        let snap = engine.currentSnapshot()
        if snap.isComposing || !composedChineseBuffer.isEmpty {
            return .updateUI(buildPanelSnapshot(from: snap))
        }
        return .updateUI(.empty)
    }

    // MARK: - 程序员中英混输快车道（临时英文模式）

    private func startInlineEnglish(initial: String, allowSpaces: Bool) -> [InputAction] {
        sessionToken &+= 1
        inlineEnglishActive = true
        inlineEnglishAllowsSpaces = allowSpaces
        inlineEnglishBuffer = initial
        highlightedIndex = 0
        translationPreview = .hidden
        return [.updateUI(buildInlineEnglishSnapshot())]
    }

    private func handleInlineEnglishKey(_ event: NormalizedKeyEvent) -> [InputAction] {
        switch event.kind {
        case .escape:
            return exitInlineEnglish()

        case .backspace:
            if !inlineEnglishBuffer.isEmpty {
                inlineEnglishBuffer.removeLast()
                highlightedIndex = 0
                if inlineEnglishBuffer.isEmpty && !inlineEnglishAllowsSpaces {
                    return exitInlineEnglish()
                }
                return [.updateUI(buildInlineEnglishSnapshot())]
            }
            return exitInlineEnglish()

        case .arrowDown, .arrowRight:
            guard inlineEnglishCandidates.count > 1 else {
                return [.updateUI(buildInlineEnglishSnapshot())]
            }
            highlightedIndex = min(inlineEnglishCandidates.count - 1, highlightedIndex + 1)
            return [.updateUI(buildInlineEnglishSnapshot())]

        case .arrowUp, .arrowLeft:
            guard inlineEnglishCandidates.count > 1 else {
                return [.updateUI(buildInlineEnglishSnapshot())]
            }
            highlightedIndex = max(0, highlightedIndex - 1)
            return [.updateUI(buildInlineEnglishSnapshot())]

        case .tab:
            if inlineEnglishCandidates.count > 1 {
                let targetIdx = (highlightedIndex == 0) ? 1 : highlightedIndex
                return finishInlineEnglishCommit(text: inlineEnglishCandidates[targetIdx].text)
            }
            if !inlineEnglishBuffer.isEmpty {
                return finishInlineEnglishCommit(text: inlineEnglishBuffer)
            }
            return exitInlineEnglish()

        case .returnKey:
            guard !inlineEnglishBuffer.isEmpty else { return exitInlineEnglish() }
            let chosen = selectedInlineEnglishText()
            return finishInlineEnglishCommit(text: chosen)

        case .space:
            if event.modifiers.contains(.shift) {
                if inlineEnglishAllowsSpaces {
                    return inlineEnglishBuffer.isEmpty
                        ? exitInlineEnglish()
                        : finishInlineEnglishCommit(text: selectedInlineEnglishText())
                }
                // 单词临时英文中按 Shift+Space：平滑升级为支持空格的英文短句（如 T3 + Shift+Space -> "T3 "）
                inlineEnglishAllowsSpaces = true
                inlineEnglishBuffer.append(" ")
                highlightedIndex = 0
                return [.updateUI(buildInlineEnglishSnapshot())]
            }
            if inlineEnglishAllowsSpaces {
                inlineEnglishBuffer.append(" ")
                highlightedIndex = 0
                return [.updateUI(buildInlineEnglishSnapshot())]
            }
            return finishInlineEnglishCommit(text: selectedInlineEnglishText())

        case .character(let ch, _):
            guard let scalar = ch.unicodeScalars.first else {
                return finishInlineEnglishAndPassThrough()
            }
            if inlineEnglishAllowsSpaces {
                if ch.count == 1, scalar.value >= 32 && scalar.value <= 126 {
                    inlineEnglishBuffer.append(ch)
                    highlightedIndex = 0
                    return [.updateUI(buildInlineEnglishSnapshot())]
                }
                let text = inlineEnglishBuffer + ch
                return finishInlineEnglishCommit(text: text)
            }
            if ch.count == 1, Self.isInlineEnglishWordScalar(scalar) {
                inlineEnglishBuffer.append(ch)
                highlightedIndex = 0
                return [.updateUI(buildInlineEnglishSnapshot())]
            }
            // 非标识符标点：由 SmartPunctuationEngine 智能区分代码符（如 React(）与中英混输中文标点（如 重启了T3，）
            let word = selectedInlineEnglishText()
            let mappedPunct = punctuationEngine.mapPunctuation(
                ch,
                context: .init(
                    mode: mode,
                    preferences: preferences,
                    appBundleID: activeAppBundleID,
                    leftContext: currentLeftContext,
                    isTrailingInlineEnglish: true
                )
            ) ?? ch
            return finishInlineEnglishCommit(text: word + mappedPunct)

        default:
            return finishInlineEnglishAndPassThrough()
        }
    }

    private func selectedInlineEnglishText() -> String {
        if inlineEnglishCandidates.indices.contains(highlightedIndex) {
            return inlineEnglishCandidates[highlightedIndex].text
        }
        return inlineEnglishBuffer
    }

    private func exitInlineEnglish() -> [InputAction] {
        sessionToken &+= 1
        inlineEnglishActive = false
        inlineEnglishAllowsSpaces = false
        inlineEnglishBuffer = ""
        inlineEnglishCandidates = []
        highlightedIndex = 0
        return [.updateUI(.empty)]
    }

    private func finishInlineEnglishCommit(text: String) -> [InputAction] {
        sessionToken &+= 1
        inlineEnglishActive = false
        inlineEnglishAllowsSpaces = false
        inlineEnglishBuffer = ""
        inlineEnglishCandidates = []
        highlightedIndex = 0
        lastCommitRecord = nil
        guard !text.isEmpty else { return [.updateUI(.empty)] }
        return [
            .updateUI(.empty),
            .commitText(text: text, requestPredictions: false)
        ]
    }

    private func finishInlineEnglishAndPassThrough() -> [InputAction] {
        let pending = inlineEnglishBuffer
        _ = exitInlineEnglish()
        if pending.isEmpty {
            return [.updateUI(.empty), .passThrough]
        }
        return [
            .updateUI(.empty),
            .commitText(text: pending, requestPredictions: false),
            .passThrough
        ]
    }

    private func buildInlineEnglishSnapshot() -> CandidatePanelSnapshot {
        var cands: [PinyinCandidate] = []
        if !inlineEnglishBuffer.isEmpty {
            cands.append(PinyinCandidate(index: 0, text: inlineEnglishBuffer, source: .rime))
            if !inlineEnglishAllowsSpaces,
               preferences.enableDocumentEnglishTokens,
               !isSecureInput {
                var added = Set<String>([inlineEnglishBuffer])
                if preferences.enableDocumentContextAssist, let docIndex = documentIndex {
                    for text in docIndex.matchEnglishCompletions(prefix: inlineEnglishBuffer, maxResults: 4)
                    where added.insert(text).inserted {
                        cands.append(PinyinCandidate(index: cands.count, text: text, source: .documentContext))
                    }
                }
                if preferences.enableWorkingMemory, let wm = workingMemory, cands.count < 5 {
                    let remain = 5 - cands.count
                    for text in wm.matchEnglishCompletions(
                        prefix: inlineEnglishBuffer,
                        appBundleID: activeAppBundleID,
                        shareAcrossApps: preferences.shareWorkingMemoryAcrossApps,
                        maxResults: remain,
                        now: clock()
                    ) where added.insert(text).inserted {
                        cands.append(PinyinCandidate(index: cands.count, text: text, source: .workingMemory))
                    }
                }
            }
        }
        inlineEnglishCandidates = cands
        highlightedIndex = min(highlightedIndex, max(0, cands.count - 1))

        let displayPreedit: String
        if inlineEnglishBuffer.isEmpty {
            displayPreedit = "临时英文（支持空格 · ⏎ 上屏回中文 · Esc 取消）"
        } else if inlineEnglishAllowsSpaces {
            displayPreedit = "\(inlineEnglishBuffer)  [⏎ 上屏回中文]"
        } else {
            displayPreedit = inlineEnglishBuffer
        }

        return CandidatePanelSnapshot(
            isVisible: true,
            mode: .directEnglish,
            preedit: displayPreedit,
            candidates: cands,
            highlightedIndex: highlightedIndex,
            showTranslationBar: false,
            activeModelLabel: inlineEnglishAllowsSpaces ? "临时英文短句 · ⏎ 上屏" : "临时英文 · ␣/⏎ 上屏"
        )
    }

    private static func isInlineEnglishWordScalar(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        if (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 48 && v <= 57) {
            return true
        }
        switch v {
        case 95, // _
             45, // -
             46, // .
             47, // /
             58, // :
             64, // @
             43, // +
             35, // #
             36: // $
            return true
        default:
            return false
        }
    }

    private func handleIdleBackspaceUndoRegret() {
        guard var record = lastCommitRecord else { return }
        let now = clock()
        if now - record.timestamp > 4.0 {
            lastCommitRecord = nil
            return
        }
        record.remainingDeletes -= 1
        if record.remainingDeletes <= 0 {
            if !isSecureInput {
                if preferences.enablePersonalMemory {
                    memoryStore?.recordUndoRegret(
                        pinyin: record.pinyin,
                        undoneWord: record.word,
                        promotedPhrase: record.promotedPhrase,
                        isSecureInput: isSecureInput,
                        now: now
                    )
                }
                if preferences.enableWorkingMemory {
                    workingMemory?.recordUndoRegret(
                        undoneWord: record.word,
                        leftContext: record.leftContext,
                        promotedPhrase: record.promotedPhrase,
                        now: now
                    )
                }
            }
            lastCommitRecord = nil
        } else {
            lastCommitRecord = record
        }
    }

    private func moveHighlight(delta: Int, snapshot: PinyinEngineSnapshot) -> [InputAction] {
        let count = rankedItems.isEmpty ? snapshot.candidates.count : rankedItems.count
        guard count > 0 else { return [.updateUI(buildPanelSnapshot(from: snapshot))] }
        let nextIdx = max(0, min(count - 1, highlightedIndex + delta))
        highlightedIndex = nextIdx
        _ = engine.moveHighlight(delta: delta)

        let effectiveTarget = effectiveTranslationTarget
        if let target = effectiveTarget {
            return triggerTranslationUpdate(snapshot: snapshot, target: target)
        }
        return [.updateUI(buildPanelSnapshot(from: snapshot))]
    }

    private func commitSelectedOrAdvance(
        index: Int,
        snapshot: PinyinEngineSnapshot
    ) -> [InputAction] {
        let effectiveTarget = effectiveTranslationTarget
        let segmentPinyin = activeSegmentPinyin(from: snapshot)
        let effectiveLeft = effectiveLeftContext(with: snapshot)

        // 1. 查找融合排序后的候选（含 originalRimeIndex、correctedPinyin 与特征向量）
        let chosenItem: RankedCandidateItem? = rankedItems.indices.contains(index) ? rankedItems[index] : nil
        let topItem: RankedCandidateItem? = rankedItems.first
        // 选中纠偏候选时按纠正后的正确拼音回写个人记忆与工作记忆，绝不把错拼污染进词库！
        let effectiveRecordPinyin = chosenItem?.correctedPinyin ?? segmentPinyin

        if let chosenItem, preferences.enablePersonalMemory, !isSecureInput {
            memoryStore?.recordSelection(
                pinyin: effectiveRecordPinyin,
                chosenWord: chosenItem.candidate.text,
                selectedRank: index,
                skippedTopWord: index > 0 ? topItem?.candidate.text : nil,
                chosenFeatures: chosenItem.features,
                skippedTopFeatures: topItem?.features,
                leftContext: effectiveLeft,
                appBundleID: activeAppBundleID,
                isSecureInput: isSecureInput,
                now: clock()
            )
        }

        // 2. 若该候选来自 Rime（当前页或 Top-16 深层召回池），走原生 Rime 选词接口，确保保留剩余拼音且同步更新词频！
        let rimeNextSnap: PinyinEngineSnapshot?
        if let origIdx = chosenItem?.originalRimeIndex {
            rimeNextSnap = engine.selectCandidateOnCurrentPage(index: origIdx)
        } else if let globalIdx = chosenItem?.globalRimeIndex {
            rimeNextSnap = engine.selectCandidate(globalIndex: globalIdx)
        } else if chosenItem == nil, snapshot.candidates.indices.contains(index) {
            rimeNextSnap = engine.selectCandidateOnCurrentPage(index: index)
        } else {
            rimeNextSnap = nil
        }

        if let nextSnap = rimeNextSnap {
            if let committed = nextSnap.committedText, !committed.isEmpty {
                if effectiveTarget != nil {
                    // 翻译模式方案 B：1-9 选词纠错只写入待译中文缓冲并刷新翻译栏，不提前上屏中文
                    composedChineseBuffer.append(committed)
                    rankedItems = []
                    firstPageRescuedTexts.removeAll()
                    highlightedIndex = 0
                    return refreshComposedTranslationBuffer()
                }
                return finishCommit(text: committed, requestPredictions: true, recordedPinyin: effectiveRecordPinyin)
            }
            return afterEngineUpdate(nextSnap)
        }

        // 3. 若该候选是「当前文本框索引 / 工作记忆 / 个人记忆」独立合成注入（均已通过 coversFullQuery 整段覆盖守卫）
        if let chosenItem {
            let fullWord = snapshot.selectedPrefix + chosenItem.candidate.text
            engine.clearComposition()
            rankedItems = []
            firstPageRescuedTexts.removeAll()
            highlightedIndex = 0
            if effectiveTarget != nil {
                composedChineseBuffer.append(fullWord)
                return refreshComposedTranslationBuffer()
            }
            return finishCommit(text: fullWord, requestPredictions: true, recordedPinyin: effectiveRecordPinyin)
        }

        return [.updateUI(buildPanelSnapshot(from: snapshot))]
    }

    private func recordImplicitAcceptanceIfTopCandidate(snapshot: PinyinEngineSnapshot) {
        guard snapshot.isComposing,
              preferences.enablePersonalMemory,
              !isSecureInput,
              rankedItems.indices.contains(highlightedIndex)
        else { return }
        let chosen = rankedItems[highlightedIndex]
        let top = rankedItems.first
        memoryStore?.recordSelection(
            pinyin: chosen.correctedPinyin ?? activeSegmentPinyin(from: snapshot),
            chosenWord: chosen.candidate.text,
            selectedRank: highlightedIndex,
            skippedTopWord: highlightedIndex > 0 ? top?.candidate.text : nil,
            chosenFeatures: chosen.features,
            skippedTopFeatures: top?.features,
            leftContext: effectiveLeftContext(with: snapshot),
            appBundleID: activeAppBundleID,
            isSecureInput: isSecureInput,
            now: clock()
        )
        if let origIdx = chosen.originalRimeIndex {
            _ = engine.selectCandidateOnCurrentPage(index: origIdx)
        } else if let globalIdx = chosen.globalRimeIndex {
            _ = engine.selectCandidate(globalIndex: globalIdx)
        }
    }

    private func afterEngineUpdate(_ snapshot: PinyinEngineSnapshot) -> [InputAction] {
        sessionToken &+= 1
        highlightedIndex = 0

        if let committed = snapshot.committedText, !committed.isEmpty {
            let effectiveTarget = effectiveTranslationTarget
            if effectiveTarget != nil {
                composedChineseBuffer.append(committed)
                rankedItems = []
                firstPageRescuedTexts.removeAll()
                return refreshComposedTranslationBuffer()
            }
            return finishCommit(text: committed, requestPredictions: true, recordedPinyin: activeSegmentPinyin(from: snapshot))
        }

        if !snapshot.isComposing {
            rankedItems = []
            firstPageRescuedTexts.removeAll()
            if !composedChineseBuffer.isEmpty && effectiveTranslationTarget != nil {
                return refreshComposedTranslationBuffer()
            }
            translationPreview = .hidden
            inlineOverrideTarget = nil
            suppressTranslateForCurrentSentence = false
            return [.cancelPendingInference, .updateUI(.empty)]
        }

        // L1 同步多信号融合排序（< 1.2ms，零闪烁；第 2 页+ 走纯翻页模式不重复注入记忆词）
        let segmentPinyin = activeSegmentPinyin(from: snapshot)
        let effectiveLeft = effectiveLeftContext(with: snapshot)
        let recentTerms = (preferences.enableWorkingMemory && !isSecureInput)
            ? (workingMemory?.recentChineseTerms(
                limit: 12,
                appBundleID: activeAppBundleID,
                shareAcrossApps: preferences.shareWorkingMemoryAcrossApps,
                now: clock()
            ) ?? [])
            : []
        currentSceneState = sceneDetector.evaluate(
            appBundleID: activeAppBundleID,
            leftContext: effectiveLeft,
            recentWorkingTerms: recentTerms,
            isSecureInput: isSecureInput,
            preferences: preferences,
            tagStore: tagStore,
            now: clock()
        )
        let pendingPredMatches: [PendingPredictionCandidate] = (snapshot.pageNo == 0 && snapshot.selectedPrefix.isEmpty)
            ? matchingPendingPredictions(for: segmentPinyin, leftContext: effectiveLeft)
            : []
        let typoCandidates: [TypoCorrectedCandidate] = (snapshot.pageNo == 0)
            ? collectTypoCandidates(rawPinyin: segmentPinyin, preedit: snapshot.preedit)
            : []
        rankedItems = ranker.rank(
            rimeCandidates: snapshot.candidates,
            extendedRimeCandidates: snapshot.extendedCandidates,
            pageNo: snapshot.pageNo,
            excludedFirstPageTexts: snapshot.pageNo > 0 ? firstPageRescuedTexts : [],
            pendingPredictions: pendingPredMatches,
            typoCandidates: typoCandidates,
            rawPinyin: segmentPinyin,
            leftContext: effectiveLeft,
            appBundleID: activeAppBundleID,
            memoryStore: isSecureInput ? nil : memoryStore,
            documentIndex: isSecureInput ? nil : documentIndex,
            workingMemory: isSecureInput ? nil : workingMemory,
            sceneState: currentSceneState,
            tagStore: tagStore,
            preferences: preferences,
            pageLimit: preferences.candidatePageSize
        )
        if snapshot.pageNo == 0 {
            firstPageRescuedTexts = Set(
                rankedItems
                    .filter { $0.originalRimeIndex == nil && $0.globalRimeIndex != nil }
                    .map(\.candidate.text)
            )
        }

        let effectiveTarget = effectiveTranslationTarget
        let sentence = fullComposedChinese(from: snapshot)
        let isSingleIncompleteLetter = composedChineseBuffer.isEmpty
            && segmentPinyin.count == 1
            && sentence.count == 1
        if let target = effectiveTarget {
            if isSingleIncompleteLetter {
                // 刚敲 1 个字母（如 d -> 的）时先不闪烁加载态，等待第 2 个字母或短暂停顿再翻译
                translationPreview = .hidden
            } else if readyCachedTranslation(for: sentence, target: target) == nil {
                translationPreview = .loading(sourceText: sentence, target: target)
            }
        } else {
            translationPreview = .hidden
        }

        let panel = buildPanelSnapshot(from: snapshot)
        let candidateTexts = rankedItems.prefix(preferences.candidatePageSize).map(\.candidate.text)
        let shouldRequestNeural = (effectiveTarget != nil) || (preferences.enableNeuralRerank && snapshot.pageNo == 0)
        if shouldRequestNeural {
            return [
                .updateUI(panel),
                .requestNeuralEnhancement(
                    sessionToken: sessionToken,
                    pinyin: segmentPinyin,
                    bestSentence: sentence,
                    candidates: candidateTexts,
                    translationTarget: effectiveTarget
                )
            ]
        }
        return [.updateUI(panel)]
    }

    private func triggerTranslationUpdate(
        snapshot: PinyinEngineSnapshot,
        target: TargetLanguage
    ) -> [InputAction] {
        sessionToken &+= 1
        let sentence = fullComposedChinese(from: snapshot)
        if readyCachedTranslation(for: sentence, target: target) != nil {
            return [.updateUI(buildPanelSnapshot(from: snapshot))]
        }
        translationPreview = .loading(sourceText: sentence, target: target)
        let panel = buildPanelSnapshot(from: snapshot)
        return [
            .updateUI(panel),
            .requestNeuralEnhancement(
                sessionToken: sessionToken,
                pinyin: activeSegmentPinyin(from: snapshot),
                bestSentence: sentence,
                candidates: rankedItems.prefix(preferences.candidatePageSize).map(\.candidate.text),
                translationTarget: target
            )
        ]
    }

    private func refreshComposedTranslationBuffer() -> [InputAction] {
        sessionToken &+= 1
        let snap = engine.currentSnapshot()
        let effectiveTarget = effectiveTranslationTarget
        let sentence = fullComposedChinese(from: snap)
        guard !sentence.isEmpty, let target = effectiveTarget else {
            return resetSession()
        }
        if readyCachedTranslation(for: sentence, target: target) != nil {
            return [.updateUI(buildPanelSnapshot(from: snap))]
        }
        translationPreview = .loading(sourceText: sentence, target: target)
        let panel = buildPanelSnapshot(from: snap)
        return [
            .updateUI(panel),
            .requestNeuralEnhancement(
                sessionToken: sessionToken,
                pinyin: "",
                bestSentence: sentence,
                candidates: [],
                translationTarget: target
            )
        ]
    }

    private func refreshAfterModeChange() -> [InputAction] {
        let snap = engine.currentSnapshot()
        if !snap.isComposing && composedChineseBuffer.isEmpty {
            let showBar = effectiveTranslationTarget != nil
            return [.updateUI(CandidatePanelSnapshot(
                isVisible: true,
                mode: mode,
                preedit: "",
                showTranslationBar: showBar,
                translationSourcePreview: "",
                translationPreview: .hidden,
                showLanguagePicker: isLanguagePickerOpen,
                languagePickerHighlightedIndex: languagePickerIndex,
                isCodingModeActive: isEffectiveCodingMode,
                activeModelLabel: modeBadgeHint
            ))]
        }
        if !snap.isComposing && !composedChineseBuffer.isEmpty {
            return refreshComposedTranslationBuffer()
        }
        return afterEngineUpdate(snap)
    }

    private func finishCommit(
        text: String,
        requestPredictions: Bool,
        recordedPinyin: String?
    ) -> [InputAction] {
        sessionToken &+= 1
        engine.clearComposition()
        composedChineseBuffer = ""
        rankedItems = []
        firstPageRescuedTexts.removeAll()
        pendingPredictionSnapshot = nil
        highlightedIndex = 0
        translationPreview = .hidden
        inlineOverrideTarget = nil
        suppressTranslateForCurrentSentence = false
        lastComposingTabTimestamp = 0
        globalTranslateBeforeLastTab = false
        isLanguagePickerOpen = false
        let committedLeftContext = currentLeftContext
        var promotedPhrase: String?
        if !text.isEmpty, !isSecureInput, preferences.enableWorkingMemory, let wm = workingMemory {
            let now = clock()
            if let promoted = wm.recordCommitted(
                text: text,
                pinyin: recordedPinyin,
                leftContext: committedLeftContext,
                appBundleID: activeAppBundleID,
                isSecureInput: isSecureInput,
                enableAutoPhrase: preferences.enableAutoPhraseLearning,
                now: now
            ) {
                promotedPhrase = promoted.phrase
                if preferences.enablePersonalMemory, preferences.enableAutoPhraseLearning {
                    memoryStore?.recordLearnedPhrase(
                        phrase: promoted.phrase,
                        fullPinyin: promoted.fullPinyin,
                        initials: promoted.initials,
                        isSecureInput: isSecureInput,
                        now: now
                    )
                }
            }
        }
        if let p = recordedPinyin, !p.isEmpty, !text.isEmpty, !isSecureInput {
            lastCommitRecord = LastCommitRecord(
                pinyin: p,
                word: text,
                leftContext: committedLeftContext,
                promotedPhrase: promotedPhrase,
                timestamp: clock(),
                remainingDeletes: text.count
            )
        } else {
            lastCommitRecord = nil
        }
        let allowPredict = requestPredictions && preferences.enableContinuationPrediction
        return [
            .cancelPendingInference,
            .updateUI(.empty),
            .commitText(text: text, requestPredictions: allowPredict)
        ]
    }

    private func finishTranslationCommit(
        sourceText: String,
        target: TargetLanguage,
        cached: String?
    ) -> [InputAction] {
        sessionToken &+= 1
        engine.clearComposition()
        composedChineseBuffer = ""
        rankedItems = []
        firstPageRescuedTexts.removeAll()
        pendingPredictionSnapshot = nil
        highlightedIndex = 0
        translationPreview = .hidden
        inlineOverrideTarget = nil
        suppressTranslateForCurrentSentence = false
        lastComposingTabTimestamp = 0
        globalTranslateBeforeLastTab = false
        isLanguagePickerOpen = false
        lastCommitRecord = nil
        return [
            .updateUI(.empty),
            .commitTranslation(sourceText: sourceText, target: target, cachedTranslation: cached)
        ]
    }

    private func currentSegmentSentence(from snapshot: PinyinEngineSnapshot) -> String {
        guard snapshot.isComposing else { return "" }
        if rankedItems.indices.contains(highlightedIndex) {
            let chosen = rankedItems[highlightedIndex].candidate.text
            if snapshot.selectedPrefix.isEmpty {
                return chosen
            }
            if chosen.hasPrefix(snapshot.selectedPrefix) {
                return chosen
            }
            return snapshot.selectedPrefix + chosen
        }
        return snapshot.bestSentence
    }

    private func fullComposedChinese(from snapshot: PinyinEngineSnapshot) -> String {
        composedChineseBuffer + currentSegmentSentence(from: snapshot)
    }

    private func activeSegmentPinyin(from snapshot: PinyinEngineSnapshot) -> String {
        if snapshot.selectedPrefix.isEmpty {
            let raw = snapshot.rawInput.isEmpty ? snapshot.preedit : snapshot.rawInput
            return raw.lowercased().filter { $0 >= "a" && $0 <= "z" }
        }
        let remainder: String
        if snapshot.preedit.hasPrefix(snapshot.selectedPrefix) {
            remainder = String(snapshot.preedit.dropFirst(snapshot.selectedPrefix.count))
        } else {
            remainder = snapshot.preedit
        }
        let ascii = remainder.lowercased().filter { $0 >= "a" && $0 <= "z" }
        if !ascii.isEmpty { return ascii }
        return snapshot.rawInput.lowercased().filter { $0 >= "a" && $0 <= "z" }
    }

    private func effectiveLeftContext(with snapshot: PinyinEngineSnapshot) -> String {
        currentLeftContext + composedChineseBuffer + snapshot.selectedPrefix
    }

    private func readyCachedTranslation(for source: String, target: TargetLanguage) -> String? {
        if case .ready(let s, let translated, let t, _) = translationPreview,
           s == source, t == target {
            return translated
        }
        return nil
    }

    private func buildPanelSnapshot(from snap: PinyinEngineSnapshot) -> CandidatePanelSnapshot {
        let effectiveMode: InputMode = {
            if let override = inlineOverrideTarget {
                return .translateOnCommit(override)
            }
            if suppressTranslateForCurrentSentence, case .translateOnCommit = mode {
                return .chinesePinyin
            }
            return mode
        }()
        let isTranslate = (effectiveMode.translationTarget != nil)
        let rawDisplayCandidates = rankedItems.isEmpty ? snap.candidates : rankedItems.map(\.candidate)
        let displayCandidates: [PinyinCandidate]
        if let tagStore, !rawDisplayCandidates.isEmpty {
            displayCandidates = tagStore.annotate(
                rawDisplayCandidates,
                activeScene: currentSceneState.primaryScene,
                showLiteraryBadges: preferences.showLiteraryBadges,
                showDomainBadges: preferences.showDomainBadges,
                allowTraditionalFallback: preferences.traditionalChinese
            )
        } else {
            displayCandidates = rawDisplayCandidates
        }
        let displayPreedit: String = {
            if composedChineseBuffer.isEmpty {
                return snap.preedit
            }
            if snap.preedit.isEmpty {
                return composedChineseBuffer
            }
            return composedChineseBuffer + " " + snap.preedit
        }()
        let sourcePreview = isTranslate ? fullComposedChinese(from: snap) : ""
        let visible = snap.isComposing || !composedChineseBuffer.isEmpty || isLanguagePickerOpen

        return CandidatePanelSnapshot(
            isVisible: visible,
            mode: effectiveMode,
            preedit: displayPreedit,
            selectedText: composedChineseBuffer + snap.selectedPrefix,
            candidates: displayCandidates,
            highlightedIndex: min(highlightedIndex, max(0, displayCandidates.count - 1)),
            pageNo: snap.pageNo,
            hasNextPage: snap.hasNextPage,
            showTranslationBar: isTranslate && (snap.isComposing || !composedChineseBuffer.isEmpty),
            translationSourcePreview: sourcePreview,
            translationPreview: translationPreview,
            translateSpaceCommitsTranslation: preferences.translateSpaceBehavior == .commitTranslation,
            isGlobalTranslateMode: (mode.translationTarget != nil && !suppressTranslateForCurrentSentence),
            showLanguagePicker: isLanguagePickerOpen,
            languagePickerHighlightedIndex: languagePickerIndex,
            isCodingModeActive: isEffectiveCodingMode,
            activeScene: currentSceneState.primaryScene,
            isSceneLocked: currentSceneState.isLocked,
            predictions: [],
            activeModelLabel: activeModelLabel ?? modeBadgeHint
        )
    }

    private var modeBadgeHint: String {
        switch mode {
        case .directEnglish: return "EN"
        case .chinesePinyin: return "拼 · ⇧⏎ 译英"
        case .translateOnCommit(let lang):
            return preferences.translateSpaceBehavior == .commitTranslation
                ? "中→\(lang.shortBadge) · ␣ 译文"
                : "中→\(lang.shortBadge) · ⏎ 译文"
        }
    }
}
