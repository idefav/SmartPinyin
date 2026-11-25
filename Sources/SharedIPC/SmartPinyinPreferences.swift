import Foundation

/// 中文模式下按下 Return 键的提交语义
public enum ReturnKeyBehavior: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 提交原始输入的英文字母/拼音串（macOS 主流中文输入法习惯）
    case commitRawInput
    /// 直接提交当前高亮的中文候选词
    case commitFirstCandidate

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .commitRawInput: return "提交原始英文 / 拼音"
        case .commitFirstCandidate: return "提交当前高亮中文候选"
        }
    }
}

/// 翻译模式下按下空格键的交互策略
public enum TranslateSpaceBehavior: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 方案 B（默认）：空格直接上屏译文，数字键 1–9 选词拼接中文句
    case commitTranslation
    /// 拼句模式：空格选词拼接中文整句，回车上屏整句译文
    case composeChineseSegment

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .commitTranslation: return "直接上屏译文（1–9 选词拼句）"
        case .composeChineseSegment: return "选词拼接中文句（回车上屏整句译文）"
        }
    }
}

/// 整句暂存与校对模式下按下空格键的交互策略
public enum DraftSpaceBehavior: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 两段空格（默认）：拼写态按空格选词进草稿校对，确认无误后再按一次空格一次性上屏整句
    case stageThenCommit
    /// 传统拼句：拼写态按空格选词进草稿，非拼写态按空格补空格，按回车上屏整句
    case composeChineseSegment

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .stageThenCommit: return "选词进草稿，再按空格上屏整句（推荐）"
        case .composeChineseSegment: return "选词进草稿，空态补空格（回车上屏整句）"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case Self.composeChineseSegment.rawValue:
            self = .composeChineseSegment
        default:
            // 向后兼容旧值（含过渡值 commitDraft），默认回落为两段空格策略
            self = .stageThenCommit
        }
    }
}

/// 空态快速切换翻译模式 / 目标语言的修饰键手势
public enum TranslateQuickGesture: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 短按右 Option 0ms 开关翻译 · 双击右 Option 弹出 1–6 语种直选条（左 Option 完全不动）
    case rightOptionTap
    /// 双击左/右 Option 弹出 1–6 语种直选条（单击不触发）
    case doubleOptionTap
    /// 关闭修饰键手势
    case off

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rightOptionTap: return "短按右 Option 开关翻译 · 双击选语种（推荐）"
        case .doubleOptionTap: return "双击左/右 Option 弹出 1–6 语种直选条"
        case .off: return "关闭（仅用拼写态 Tab / 菜单 / 行内指令）"
        }
    }
}

/// 拼写组合态下按 Tab 键的译文切换作用域
public enum ComposingTabBehavior: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 仅对当前这一句临时展开/隐藏翻译栏，不修改全局翻译开关（推荐）
    case toggleCurrentSentence
    /// 直接翻转全局持续翻译模式
    case togglePersistentMode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .toggleCurrentSentence: return "本句临时展开/隐藏翻译栏（推荐）"
        case .togglePersistentMode: return "直接切换全局持续翻译模式"
        }
    }
}

/// 一键全局关闭翻译模式快捷键（立即关闭所有窗口的全局翻译模式并持久化，绝不误开）
public enum GlobalDisableTranslateShortcut: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Control + Option + T（⌃⌥T，推荐，零 IDE/终端/系统冲突）
    case controlOptionT
    /// Option + Shift + T（⌥⇧T）
    case optionShiftT
    /// Control + Shift + T（⌃⇧T）
    case controlShiftT
    /// 关闭该快捷键
    case off

    public var id: String { rawValue }

    public var badge: String {
        switch self {
        case .controlOptionT: return "⌃⌥T"
        case .optionShiftT: return "⌥⇧T"
        case .controlShiftT: return "⌃⇧T"
        case .off: return ""
        }
    }

    public var displayName: String {
        switch self {
        case .controlOptionT: return "Control + Option + T（⌃⌥T，推荐）"
        case .optionShiftT: return "Option + Shift + T（⌥⇧T）"
        case .controlShiftT: return "Control + Shift + T（⌃⇧T）"
        case .off: return "关闭快捷键"
        }
    }
}

/// 一键全局开关「整句暂存与校对模式」快捷键
public enum DraftModeToggleShortcut: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Control + Option + D（⌃⌥D，推荐，与 ⌃⌥T 对称且零热键冲突）
    case controlOptionD
    /// Option + Shift + D（⌥⇧D）
    case optionShiftD
    /// 关闭快捷键
    case off

    public var id: String { rawValue }

    public var badge: String {
        switch self {
        case .controlOptionD: return "⌃⌥D"
        case .optionShiftD: return "⌥⇧D"
        case .off: return ""
        }
    }

    public var displayName: String {
        switch self {
        case .controlOptionD: return "Control + Option + D（⌃⌥D，推荐）"
        case .optionShiftD: return "Option + Shift + D（⌥⇧D）"
        case .off: return "关闭快捷键"
        }
    }
}

/// 句末智能联想的展示与接入方式
public enum PredictionDisplayStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 停顿浮现紧凑联想条 + 不停顿敲首字母 0ms 融入候选栏首位（推荐）
    case barAndInlineFusion
    /// 静默模式：不弹独立联想浮窗，仅在继续打首字母时 0ms 融入候选栏首位
    case inlineFusionOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .barAndInlineFusion: return "联想条 + 首字母融合（推荐）"
        case .inlineFusionOnly: return "仅首字母融合（无独立弹窗，最安静）"
        }
    }
}

/// 联想条直选快捷键风格（均 100% 必达 IMK，绝不被浏览器抢焦点）
public enum PredictionSelectionShortcut: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 联想条可见时按 1/2/3 单手直选（智能避让数字语境，兼支持 Tab / ⌥1~3 / 点击）
    case digits123
    /// 仅 Option+1/2/3 直选（兼支持 Tab / 点击，完全不拦截普通数字键）
    case optionDigits123

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .digits123: return "数字键 1 / 2 / 3（推荐，防浏览器抢焦点）"
        case .optionDigits123: return "Option + 1 / 2 / 3（零数字误触）"
        }
    }
}

/// SmartPinyin 全局用户偏好设置（在输入法、XPC 推理服务与设置中心之间实时同步）
public struct SmartPinyinPreferences: Codable, Equatable, Sendable {
    // 1. 拼音与候选习惯
    public var candidatePageSize: Int
    public var candidateFontSize: Double
    public var shiftTapSwitchEnabled: Bool
    /// 程序员中英混输快车道：大写字母/驼峰/下划线自动进入临时英文，Shift+空格输入带空格的英文短句后回车自动回中文
    public var smartInlineEnglishEnabled: Bool
    public var returnKeyBehavior: ReturnKeyBehavior
    public var chinesePunctuation: Bool
    /// 智能标点：数字后小数点/冒号自动半角、中式引号自动配对、中英混输自动适配
    public var smartPunctuationEnabled: Bool
    /// 全局 Coding 模式：中文输入时默认使用英文半角标点
    public var codingModeEnabled: Bool
    /// 在 IDE / 终端 / T3 Code 等开发工具中自动进入 Coding 模式（切回微信/浏览器自动恢复中文标点）
    public var autoCodingModeForDevApps: Bool
    public var traditionalChinese: Bool
    public var enableEmojiCandidates: Bool
    public var enableAbbrevPinyin: Bool
    /// 智能拼音自动纠错（覆盖邻键误触、跨排错键、字母倒序、漏键与多敲连键；兼控英文拼写纠错）
    public var enableAutoCorrection: Bool
    /// 中英文混输、离线英文词典补全与英文拼写纠错（如 gitdiz -> git地址、wodegit -> 我的git、dokcer -> Docker）
    public var enableMixedBilingualAssist: Bool
    /// 前后鼻音模糊容错（an↔ang、en↔eng、in↔ing、ian↔iang、uan↔uang）
    public var fuzzyNasalPinyin: Bool
    /// 平翘舌模糊容错（zh↔z、ch↔c、sh↔s）
    public var fuzzyRetroflexPinyin: Bool
    /// 鼻边音与唇齿音模糊容错（n↔l、f↔h）
    public var fuzzyNLAndFHPinyin: Bool
    /// 超长输入或找不到匹配内容时自动切入单字逐选模式（支持逐字挑选、翻页与音节边界微调）
    public var enableAutoSingleCharFallback: Bool

    // 1.5 整句暂存与整体错字纠偏模式
    /// 全局「整句暂存与校对模式」：底栏实时错字纠偏，默认空格直接上屏整句，1–9 选词拼句
    public var defaultDraftProofreadMode: Bool
    /// 整句暂存与校对模式下按下空格键的行为（默认直接上屏整句，可切换为选词拼句）
    public var draftSpaceBehavior: DraftSpaceBehavior
    /// 暂存模式下自动使用本地 Qwen3-0.6B 进行整句语义错字纠偏（100% 离线，复用 .light 槽）
    public var enableAIDraftProofread: Bool
    /// 一键全局开关「整句暂存与校对模式」快捷键（默认 ⌃⌥D）
    public var draftModeToggleShortcut: DraftModeToggleShortcut

    // 2. 本地偏好记忆、文档联动与小模型增强（Qwen3-0.6B）
    public var enablePersonalMemory: Bool
    /// 自动记忆前面输入的文字（跨换行、30 分钟衰减），用于后续候选排序与 0ms 推荐
    public var enableWorkingMemory: Bool
    /// 允许跨应用共享短期输入工作记忆（已过滤密码框、密钥与长数字，跨应用权重 0.75x）
    public var shareWorkingMemoryAcrossApps: Bool
    /// 连续选词拼出的高频短语（出现 >= 2 次）自动沉淀进长期 SQLite 个人词库
    public var enableAutoPhraseLearning: Bool
    /// 在候选词条旁显示来源微标（✦ AI / 记 记忆 / 文 文档 / 纠 纠错）
    public var showCandidateSourceBadges: Bool
    /// 在候选词条旁显示诗词 / 成语分类微胶囊（诗 / 成）
    public var showLiteraryBadges: Bool
    /// 在激活专业场景时于命中的专业词条旁显示领域微标（游 / 数 / 计 / 美 / 科 / 医 / 财）
    public var showDomainBadges: Bool
    /// 智能场景自适应词库优先级（自动识别游戏 / 数学 / 计算机 / 美术 / 科学等语境，0ms 抬升对应领域词）
    public var enableSmartSceneAdaptation: Bool
    /// 手动锁定的专业场景（nil 表示自动智能识别）
    public var lockedSceneDomain: InputSceneDomain?
    /// 分场景词库优先级倍率（key 为 InputSceneDomain.rawValue，默认 1.0；范围 0.0~2.0）
    public var scenePriorityMultipliers: [String: Double]
    /// 打开管理中心时自动检查开源词库新版本提示
    public var checkLexiconUpdatesOnSetupLaunch: Bool
    public var enableDocumentContextAssist: Bool
    public var enableDocumentEnglishTokens: Bool
    public var enableNeuralRerank: Bool
    public var enableContinuationPrediction: Bool
    public var predictionDisplayStyle: PredictionDisplayStyle
    public var predictionSelectionShortcut: PredictionSelectionShortcut
    public var predictionAutoHideSeconds: Int

    // 3. 实时翻译（HY-MT1.5-1.8B）
    public var defaultTargetLanguage: TargetLanguage
    /// 全局持久化的「翻译模式」开关（开启后弹窗自动显示实时翻译栏，跨窗口/App 保持生效）
    public var defaultTranslateMode: Bool
    /// 翻译模式下按下空格键的行为（默认直接上屏译文，可切换为选词拼句）
    public var translateSpaceBehavior: TranslateSpaceBehavior
    /// 连续分段翻译上屏时，为空格分词目标语（英/法/德/西/韩）自动补词间空格
    public var autoSpaceTranslatedSegments: Bool
    /// 空态修饰键快切翻译/语种手势（默认右 Option 单击开关翻译、双击弹 1–6 语种直选条）
    public var translateQuickGesture: TranslateQuickGesture
    /// 拼写组合态下按 Tab 键的译文切换行为
    public var composingTabBehavior: ComposingTabBehavior
    /// 拼写组合态下 320ms 内快速双击 Tab 切换全局持续翻译开关（单按 Tab 仍为本句临时译文）
    public var doubleTabTogglesGlobalTranslate: Bool
    /// 一键全局关闭翻译模式快捷键（默认 ⌃⌥T，立即全局关闭所有窗口的翻译模式）
    public var globalDisableTranslateShortcut: GlobalDisableTranslateShortcut
    /// 行内语种前缀（/ja /en /ko 等）触发时是否同时记住为默认目标语言
    public var inlinePrefixPersistsLanguage: Bool
    /// 是否启用 Option+T / Option+L 固定快捷键切换翻译模式（默认关闭，避免抢占应用热键）
    public var enableTranslateHotkeys: Bool
    public var shiftReturnQuickTranslate: Bool
    public var inlineLanguagePrefixEnabled: Bool

    // 4. 内存与性能（< 2GB 档位 C）
    public var idleUnloadSeconds: Int

    public init(
        candidatePageSize: Int = 7,
        candidateFontSize: Double = 15,
        shiftTapSwitchEnabled: Bool = true,
        smartInlineEnglishEnabled: Bool = true,
        returnKeyBehavior: ReturnKeyBehavior = .commitRawInput,
        chinesePunctuation: Bool = true,
        smartPunctuationEnabled: Bool = true,
        codingModeEnabled: Bool = false,
        autoCodingModeForDevApps: Bool = true,
        traditionalChinese: Bool = false,
        enableEmojiCandidates: Bool = true,
        enableAbbrevPinyin: Bool = true,
        enableAutoCorrection: Bool = true,
        enableMixedBilingualAssist: Bool = true,
        fuzzyNasalPinyin: Bool = true,
        fuzzyRetroflexPinyin: Bool = false,
        fuzzyNLAndFHPinyin: Bool = false,
        enableAutoSingleCharFallback: Bool = true,
        defaultDraftProofreadMode: Bool = false,
        draftSpaceBehavior: DraftSpaceBehavior = .stageThenCommit,
        enableAIDraftProofread: Bool = true,
        draftModeToggleShortcut: DraftModeToggleShortcut = .controlOptionD,
        enablePersonalMemory: Bool = true,
        enableWorkingMemory: Bool = true,
        shareWorkingMemoryAcrossApps: Bool = true,
        enableAutoPhraseLearning: Bool = true,
        showCandidateSourceBadges: Bool = true,
        showLiteraryBadges: Bool = true,
        showDomainBadges: Bool = false,
        enableSmartSceneAdaptation: Bool = true,
        lockedSceneDomain: InputSceneDomain? = nil,
        scenePriorityMultipliers: [String: Double] = [:],
        checkLexiconUpdatesOnSetupLaunch: Bool = true,
        enableDocumentContextAssist: Bool = true,
        enableDocumentEnglishTokens: Bool = true,
        enableNeuralRerank: Bool = true,
        enableContinuationPrediction: Bool = true,
        predictionDisplayStyle: PredictionDisplayStyle = .barAndInlineFusion,
        predictionSelectionShortcut: PredictionSelectionShortcut = .digits123,
        predictionAutoHideSeconds: Int = 8,
        defaultTargetLanguage: TargetLanguage = .english,
        defaultTranslateMode: Bool = false,
        translateSpaceBehavior: TranslateSpaceBehavior = .commitTranslation,
        autoSpaceTranslatedSegments: Bool = true,
        translateQuickGesture: TranslateQuickGesture = .rightOptionTap,
        composingTabBehavior: ComposingTabBehavior = .toggleCurrentSentence,
        doubleTabTogglesGlobalTranslate: Bool = true,
        globalDisableTranslateShortcut: GlobalDisableTranslateShortcut = .controlOptionT,
        inlinePrefixPersistsLanguage: Bool = true,
        enableTranslateHotkeys: Bool = false,
        shiftReturnQuickTranslate: Bool = true,
        inlineLanguagePrefixEnabled: Bool = true,
        idleUnloadSeconds: Int = 180
    ) {
        self.candidatePageSize = min(9, max(5, candidatePageSize))
        self.candidateFontSize = min(19, max(12, candidateFontSize))
        self.shiftTapSwitchEnabled = shiftTapSwitchEnabled
        self.smartInlineEnglishEnabled = smartInlineEnglishEnabled
        self.returnKeyBehavior = returnKeyBehavior
        self.chinesePunctuation = chinesePunctuation
        self.smartPunctuationEnabled = smartPunctuationEnabled
        self.codingModeEnabled = codingModeEnabled
        self.autoCodingModeForDevApps = autoCodingModeForDevApps
        self.traditionalChinese = traditionalChinese
        self.enableEmojiCandidates = enableEmojiCandidates
        self.enableAbbrevPinyin = enableAbbrevPinyin
        self.enableAutoCorrection = enableAutoCorrection
        self.enableMixedBilingualAssist = enableMixedBilingualAssist
        self.fuzzyNasalPinyin = fuzzyNasalPinyin
        self.fuzzyRetroflexPinyin = fuzzyRetroflexPinyin
        self.fuzzyNLAndFHPinyin = fuzzyNLAndFHPinyin
        self.enableAutoSingleCharFallback = enableAutoSingleCharFallback
        self.defaultDraftProofreadMode = defaultDraftProofreadMode
        self.draftSpaceBehavior = draftSpaceBehavior
        self.enableAIDraftProofread = enableAIDraftProofread
        self.draftModeToggleShortcut = draftModeToggleShortcut
        self.enablePersonalMemory = enablePersonalMemory
        self.enableWorkingMemory = enableWorkingMemory
        self.shareWorkingMemoryAcrossApps = shareWorkingMemoryAcrossApps
        self.enableAutoPhraseLearning = enableAutoPhraseLearning
        self.showCandidateSourceBadges = showCandidateSourceBadges
        self.showLiteraryBadges = showLiteraryBadges
        self.showDomainBadges = showDomainBadges
        self.enableSmartSceneAdaptation = enableSmartSceneAdaptation
        self.lockedSceneDomain = lockedSceneDomain
        self.scenePriorityMultipliers = scenePriorityMultipliers
        self.checkLexiconUpdatesOnSetupLaunch = checkLexiconUpdatesOnSetupLaunch
        self.enableDocumentContextAssist = enableDocumentContextAssist
        self.enableDocumentEnglishTokens = enableDocumentEnglishTokens
        self.enableNeuralRerank = enableNeuralRerank
        self.enableContinuationPrediction = enableContinuationPrediction
        self.predictionDisplayStyle = predictionDisplayStyle
        self.predictionSelectionShortcut = predictionSelectionShortcut
        self.predictionAutoHideSeconds = min(30, max(3, predictionAutoHideSeconds))
        self.defaultTargetLanguage = defaultTargetLanguage
        self.defaultTranslateMode = defaultTranslateMode
        self.translateSpaceBehavior = translateSpaceBehavior
        self.autoSpaceTranslatedSegments = autoSpaceTranslatedSegments
        self.translateQuickGesture = translateQuickGesture
        self.composingTabBehavior = composingTabBehavior
        self.doubleTabTogglesGlobalTranslate = doubleTabTogglesGlobalTranslate
        self.globalDisableTranslateShortcut = globalDisableTranslateShortcut
        self.inlinePrefixPersistsLanguage = inlinePrefixPersistsLanguage
        self.enableTranslateHotkeys = enableTranslateHotkeys
        self.shiftReturnQuickTranslate = shiftReturnQuickTranslate
        self.inlineLanguagePrefixEnabled = inlineLanguagePrefixEnabled
        self.idleUnloadSeconds = min(1800, max(30, idleUnloadSeconds))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SmartPinyinPreferences.default
        self.init(
            candidatePageSize: try c.decodeIfPresent(Int.self, forKey: .candidatePageSize) ?? d.candidatePageSize,
            candidateFontSize: try c.decodeIfPresent(Double.self, forKey: .candidateFontSize) ?? d.candidateFontSize,
            shiftTapSwitchEnabled: try c.decodeIfPresent(Bool.self, forKey: .shiftTapSwitchEnabled) ?? d.shiftTapSwitchEnabled,
            smartInlineEnglishEnabled: try c.decodeIfPresent(Bool.self, forKey: .smartInlineEnglishEnabled) ?? d.smartInlineEnglishEnabled,
            returnKeyBehavior: try c.decodeIfPresent(ReturnKeyBehavior.self, forKey: .returnKeyBehavior) ?? d.returnKeyBehavior,
            chinesePunctuation: try c.decodeIfPresent(Bool.self, forKey: .chinesePunctuation) ?? d.chinesePunctuation,
            smartPunctuationEnabled: try c.decodeIfPresent(Bool.self, forKey: .smartPunctuationEnabled) ?? d.smartPunctuationEnabled,
            codingModeEnabled: try c.decodeIfPresent(Bool.self, forKey: .codingModeEnabled) ?? d.codingModeEnabled,
            autoCodingModeForDevApps: try c.decodeIfPresent(Bool.self, forKey: .autoCodingModeForDevApps) ?? d.autoCodingModeForDevApps,
            traditionalChinese: try c.decodeIfPresent(Bool.self, forKey: .traditionalChinese) ?? d.traditionalChinese,
            enableEmojiCandidates: try c.decodeIfPresent(Bool.self, forKey: .enableEmojiCandidates) ?? d.enableEmojiCandidates,
            enableAbbrevPinyin: try c.decodeIfPresent(Bool.self, forKey: .enableAbbrevPinyin) ?? d.enableAbbrevPinyin,
            enableAutoCorrection: try c.decodeIfPresent(Bool.self, forKey: .enableAutoCorrection) ?? d.enableAutoCorrection,
            enableMixedBilingualAssist: try c.decodeIfPresent(Bool.self, forKey: .enableMixedBilingualAssist) ?? d.enableMixedBilingualAssist,
            fuzzyNasalPinyin: try c.decodeIfPresent(Bool.self, forKey: .fuzzyNasalPinyin) ?? d.fuzzyNasalPinyin,
            fuzzyRetroflexPinyin: try c.decodeIfPresent(Bool.self, forKey: .fuzzyRetroflexPinyin) ?? d.fuzzyRetroflexPinyin,
            fuzzyNLAndFHPinyin: try c.decodeIfPresent(Bool.self, forKey: .fuzzyNLAndFHPinyin) ?? d.fuzzyNLAndFHPinyin,
            enableAutoSingleCharFallback: try c.decodeIfPresent(Bool.self, forKey: .enableAutoSingleCharFallback) ?? d.enableAutoSingleCharFallback,
            defaultDraftProofreadMode: try c.decodeIfPresent(Bool.self, forKey: .defaultDraftProofreadMode) ?? d.defaultDraftProofreadMode,
            draftSpaceBehavior: try c.decodeIfPresent(DraftSpaceBehavior.self, forKey: .draftSpaceBehavior) ?? d.draftSpaceBehavior,
            enableAIDraftProofread: try c.decodeIfPresent(Bool.self, forKey: .enableAIDraftProofread) ?? d.enableAIDraftProofread,
            draftModeToggleShortcut: try c.decodeIfPresent(DraftModeToggleShortcut.self, forKey: .draftModeToggleShortcut) ?? d.draftModeToggleShortcut,
            enablePersonalMemory: try c.decodeIfPresent(Bool.self, forKey: .enablePersonalMemory) ?? d.enablePersonalMemory,
            enableWorkingMemory: try c.decodeIfPresent(Bool.self, forKey: .enableWorkingMemory) ?? d.enableWorkingMemory,
            shareWorkingMemoryAcrossApps: try c.decodeIfPresent(Bool.self, forKey: .shareWorkingMemoryAcrossApps) ?? d.shareWorkingMemoryAcrossApps,
            enableAutoPhraseLearning: try c.decodeIfPresent(Bool.self, forKey: .enableAutoPhraseLearning) ?? d.enableAutoPhraseLearning,
            showCandidateSourceBadges: try c.decodeIfPresent(Bool.self, forKey: .showCandidateSourceBadges) ?? d.showCandidateSourceBadges,
            showLiteraryBadges: try c.decodeIfPresent(Bool.self, forKey: .showLiteraryBadges) ?? d.showLiteraryBadges,
            showDomainBadges: try c.decodeIfPresent(Bool.self, forKey: .showDomainBadges) ?? d.showDomainBadges,
            enableSmartSceneAdaptation: try c.decodeIfPresent(Bool.self, forKey: .enableSmartSceneAdaptation) ?? d.enableSmartSceneAdaptation,
            lockedSceneDomain: try c.decodeIfPresent(InputSceneDomain.self, forKey: .lockedSceneDomain) ?? d.lockedSceneDomain,
            scenePriorityMultipliers: try c.decodeIfPresent([String: Double].self, forKey: .scenePriorityMultipliers) ?? d.scenePriorityMultipliers,
            checkLexiconUpdatesOnSetupLaunch: try c.decodeIfPresent(Bool.self, forKey: .checkLexiconUpdatesOnSetupLaunch) ?? d.checkLexiconUpdatesOnSetupLaunch,
            enableDocumentContextAssist: try c.decodeIfPresent(Bool.self, forKey: .enableDocumentContextAssist) ?? d.enableDocumentContextAssist,
            enableDocumentEnglishTokens: try c.decodeIfPresent(Bool.self, forKey: .enableDocumentEnglishTokens) ?? d.enableDocumentEnglishTokens,
            enableNeuralRerank: try c.decodeIfPresent(Bool.self, forKey: .enableNeuralRerank) ?? d.enableNeuralRerank,
            enableContinuationPrediction: try c.decodeIfPresent(Bool.self, forKey: .enableContinuationPrediction) ?? d.enableContinuationPrediction,
            predictionDisplayStyle: try c.decodeIfPresent(PredictionDisplayStyle.self, forKey: .predictionDisplayStyle) ?? d.predictionDisplayStyle,
            predictionSelectionShortcut: try c.decodeIfPresent(PredictionSelectionShortcut.self, forKey: .predictionSelectionShortcut) ?? d.predictionSelectionShortcut,
            predictionAutoHideSeconds: try c.decodeIfPresent(Int.self, forKey: .predictionAutoHideSeconds) ?? d.predictionAutoHideSeconds,
            defaultTargetLanguage: try c.decodeIfPresent(TargetLanguage.self, forKey: .defaultTargetLanguage) ?? d.defaultTargetLanguage,
            defaultTranslateMode: try c.decodeIfPresent(Bool.self, forKey: .defaultTranslateMode) ?? d.defaultTranslateMode,
            translateSpaceBehavior: try c.decodeIfPresent(TranslateSpaceBehavior.self, forKey: .translateSpaceBehavior) ?? d.translateSpaceBehavior,
            autoSpaceTranslatedSegments: try c.decodeIfPresent(Bool.self, forKey: .autoSpaceTranslatedSegments) ?? d.autoSpaceTranslatedSegments,
            translateQuickGesture: try c.decodeIfPresent(TranslateQuickGesture.self, forKey: .translateQuickGesture) ?? d.translateQuickGesture,
            composingTabBehavior: try c.decodeIfPresent(ComposingTabBehavior.self, forKey: .composingTabBehavior) ?? d.composingTabBehavior,
            doubleTabTogglesGlobalTranslate: try c.decodeIfPresent(Bool.self, forKey: .doubleTabTogglesGlobalTranslate) ?? d.doubleTabTogglesGlobalTranslate,
            globalDisableTranslateShortcut: try c.decodeIfPresent(GlobalDisableTranslateShortcut.self, forKey: .globalDisableTranslateShortcut) ?? d.globalDisableTranslateShortcut,
            inlinePrefixPersistsLanguage: try c.decodeIfPresent(Bool.self, forKey: .inlinePrefixPersistsLanguage) ?? d.inlinePrefixPersistsLanguage,
            enableTranslateHotkeys: try c.decodeIfPresent(Bool.self, forKey: .enableTranslateHotkeys) ?? d.enableTranslateHotkeys,
            shiftReturnQuickTranslate: try c.decodeIfPresent(Bool.self, forKey: .shiftReturnQuickTranslate) ?? d.shiftReturnQuickTranslate,
            inlineLanguagePrefixEnabled: try c.decodeIfPresent(Bool.self, forKey: .inlineLanguagePrefixEnabled) ?? d.inlineLanguagePrefixEnabled,
            idleUnloadSeconds: try c.decodeIfPresent(Int.self, forKey: .idleUnloadSeconds) ?? d.idleUnloadSeconds
        )
    }

    public static let `default` = SmartPinyinPreferences()

    /// 获取指定场景的优先级倍率（默认 1.0，范围 0.0~2.0）
    public func priorityMultiplier(for domain: InputSceneDomain) -> Double {
        guard domain != .general else { return 1.0 }
        let raw = scenePriorityMultipliers[domain.rawValue] ?? 1.0
        return min(2.0, max(0.0, raw))
    }
}

/// 跨进程共享配置存储：
/// 同步写入 JSON 文件（无 cfprefsd 延迟）与 UserDefaults 域，并发送分布式通知即时生效。
public enum SmartPinyinPreferencesStore {
    public static let didChangeNotification = Notification.Name(
        "\(SmartPinyinIdentifiers.appBundleID).preferencesDidChange"
    )
    /// 词库安装 / 启停 / 更新后发送此通知，触发运行中 SmartPinyin 后台安全热重载 Rime 与领域标签索引
    public static let lexiconDidChangeNotification = Notification.Name(
        "\(SmartPinyinIdentifiers.appBundleID).lexiconDidChange"
    )

    private static let defaultsKey = "SmartPinyinPreferencesJSON"

    public static func preferencesFileURL(
        baseDirectory: URL? = nil
    ) -> URL {
        let dir = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent(SmartPinyinIdentifiers.appSupportFolderName, isDirectory: true)
        return dir.appendingPathComponent("preferences.json")
    }

    public static func load(baseDirectory: URL? = nil) -> SmartPinyinPreferences {
        let fileURL = preferencesFileURL(baseDirectory: baseDirectory)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(SmartPinyinPreferences.self, from: data) {
            return decoded
        }
        if baseDirectory == nil,
           let defaults = UserDefaults(suiteName: SmartPinyinIdentifiers.appBundleID),
           let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(SmartPinyinPreferences.self, from: data) {
            return decoded
        }
        return .default
    }

    public static func save(
        _ preferences: SmartPinyinPreferences,
        baseDirectory: URL? = nil,
        postNotification: Bool = true
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(preferences) else { return }

        let fileURL = preferencesFileURL(baseDirectory: baseDirectory)
        let dirURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)

        if baseDirectory == nil,
           let defaults = UserDefaults(suiteName: SmartPinyinIdentifiers.appBundleID) {
            defaults.set(data, forKey: defaultsKey)
            defaults.synchronize()
        }

        if postNotification {
            DistributedNotificationCenter.default().postNotificationName(
                didChangeNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }
}
