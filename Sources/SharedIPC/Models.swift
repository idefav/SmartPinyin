import Foundation

/// 支持的实时翻译目标语言
public enum TargetLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"

    public var shortBadge: String {
        switch self {
        case .english: return "EN"
        case .japanese: return "JA"
        case .korean: return "KO"
        case .french: return "FR"
        case .german: return "DE"
        case .spanish: return "ES"
        }
    }

    public var displayName: String {
        switch self {
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        }
    }

    public var promptLanguageName: String {
        switch self {
        case .english: return "English"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .french: return "French"
        case .german: return "German"
        case .spanish: return "Spanish"
        }
    }

    /// 腾讯 HY-MT1.5 官方汉译外指令要求的中文语种名
    public var chinesePromptName: String {
        switch self {
        case .english: return "英语"
        case .japanese: return "日语"
        case .korean: return "韩语"
        case .french: return "法语"
        case .german: return "德语"
        case .spanish: return "西班牙语"
        }
    }

    /// 是否属于词/句间需要空格分隔的目标语种
    public var usesWordSpacing: Bool {
        switch self {
        case .english, .french, .german, .spanish, .korean:
            return true
        case .japanese:
            return false
        }
    }

    public var next: TargetLanguage {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return .english }
        return all[(idx + 1) % all.count]
    }

    public static func fromInlinePrefix(_ prefix: String) -> TargetLanguage? {
        Self(rawValue: prefix.lowercased())
    }
}

/// 当前输入法的工作模式
public enum InputMode: Equatable, Codable, Sendable {
    case directEnglish
    case chinesePinyin
    case draftProofread
    case translateOnCommit(TargetLanguage)

    public var isChineseActive: Bool {
        switch self {
        case .directEnglish: return false
        case .chinesePinyin, .draftProofread, .translateOnCommit: return true
        }
    }

    public var isDraftProofread: Bool {
        if case .draftProofread = self { return true }
        return false
    }

    public var translationTarget: TargetLanguage? {
        if case .translateOnCommit(let lang) = self {
            return lang
        }
        return nil
    }
}

/// 候选词来源标注
public enum CandidateSource: String, Codable, Sendable {
    case rime
    case userMemory
    case workingMemory
    case documentContext
    case neuralReranked
    case neuralPrediction
    case typoCorrected
    case mixedBilingual
}

/// 智能场景定义（支持自动感知或用户手动锁定，驱动 0ms 词库动态优先级调度）
public enum InputSceneDomain: String, CaseIterable, Codable, Identifiable, Sendable {
    case general          // 日常通用
    case computerScience  // 计算机 / 编程
    case gaming           // 游戏 / 电竞 / ACG
    case mathematics      // 数学 / 算法
    case science          // 物理 / 化学 / 生物科学
    case artDesign        // 美术 / 设计 / 摄影 / 3D
    case literature       // 文学 / 诗词 / 成语
    case medicine         // 医学 / 医药
    case financeLaw       // 财经 / 金融 / 法律

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .general: return "日常通用"
        case .computerScience: return "计算机 / 编程"
        case .gaming: return "游戏 / ACG"
        case .mathematics: return "数学 / 统计"
        case .science: return "自然科学"
        case .artDesign: return "美术 / 设计"
        case .literature: return "文学 / 诗词"
        case .medicine: return "医学 / 健康"
        case .financeLaw: return "财经 / 法律"
        }
    }

    /// 候选窗右上角模式胶囊短标签（如 拼 · 游戏 / 拼 · 数学）
    public var panelShortLabel: String {
        switch self {
        case .general: return ""
        case .computerScience: return "计算机"
        case .gaming: return "游戏"
        case .mathematics: return "数学"
        case .science: return "科学"
        case .artDesign: return "美术"
        case .literature: return "文学"
        case .medicine: return "医学"
        case .financeLaw: return "财经"
        }
    }

    /// 与二进制 domain_tags.bin 对齐的位掩码
    public var bitMask: UInt16 {
        switch self {
        case .general: return 0
        case .computerScience: return 1 << 0
        case .gaming: return 1 << 1
        case .mathematics: return 1 << 2
        case .science: return 1 << 3
        case .artDesign: return 1 << 4
        case .literature: return 1 << 5
        case .medicine: return 1 << 6
        case .financeLaw: return 1 << 7
        }
    }

    /// 行内快速切换短别名（如 /sc game、/sc math、/sc art、/sc auto）
    public static func fromInlineAlias(_ alias: String) -> InputSceneDomain? {
        switch alias.lowercased() {
        case "general", "normal", "default": return .general
        case "cs", "code", "dev", "it", "tech": return .computerScience
        case "game", "gaming", "acg": return .gaming
        case "math", "mathematics": return .mathematics
        case "sci", "science", "phy", "chem", "bio": return .science
        case "art", "design", "ui", "draw": return .artDesign
        case "lit", "poem", "poetry", "literature": return .literature
        case "med", "medicine": return .medicine
        case "fin", "finance", "law": return .financeLaw
        default: return nil
        }
    }

    /// 除 general 外的全部专业领域场景
    public static let specializedDomains: [InputSceneDomain] = [
        .computerScience, .gaming, .mathematics, .science, .artDesign, .literature, .medicine, .financeLaw
    ]
}

/// 候选词语义与领域分类标注（与排序来源 CandidateSource 正交解耦）
public enum CandidateCategory: String, Codable, Sendable {
    case idiom            // 成语（微胶囊：成）
    case poetry           // 诗词名句（微胶囊：诗）
    case computerScience  // 计算机（可选微标：计）
    case gaming           // 游戏（可选微标：游）
    case mathematics      // 数学（可选微标：数）
    case science          // 科学（可选微标：科）
    case artDesign        // 美术（可选微标：美）
    case medicine         // 医学（可选微标：医）
    case financeLaw       // 财经/法律（可选微标：财）

    public var isLiterary: Bool {
        self == .idiom || self == .poetry
    }

    public var shortBadge: String {
        switch self {
        case .idiom: return "成"
        case .poetry: return "诗"
        case .computerScience: return "计"
        case .gaming: return "游"
        case .mathematics: return "数"
        case .science: return "科"
        case .artDesign: return "美"
        case .medicine: return "医"
        case .financeLaw: return "财"
        }
    }

    public var correspondingScene: InputSceneDomain {
        switch self {
        case .idiom, .poetry: return .literature
        case .computerScience: return .computerScience
        case .gaming: return .gaming
        case .mathematics: return .mathematics
        case .science: return .science
        case .artDesign: return .artDesign
        case .medicine: return .medicine
        case .financeLaw: return .financeLaw
        }
    }

    public static func fromSceneDomain(_ domain: InputSceneDomain) -> CandidateCategory? {
        switch domain {
        case .computerScience: return .computerScience
        case .gaming: return .gaming
        case .mathematics: return .mathematics
        case .science: return .science
        case .artDesign: return .artDesign
        case .medicine: return .medicine
        case .financeLaw: return .financeLaw
        case .general, .literature: return nil
        }
    }
}

/// L2 神经重排带连续得分的候选条目（用于与 L1 融合总分做连续加权融合）
public struct ScoredCandidate: Equatable, Codable, Sendable {
    public let text: String
    public let score: Double

    public init(text: String, score: Double) {
        self.text = text
        self.score = score
    }
}

/// 单个候选词条
public struct PinyinCandidate: Equatable, Codable, Identifiable, Sendable {
    public let id: String
    public let index: Int
    public let text: String
    public let comment: String?
    public let source: CandidateSource
    public let category: CandidateCategory?

    public init(
        index: Int,
        text: String,
        comment: String? = nil,
        source: CandidateSource = .rime,
        category: CandidateCategory? = nil
    ) {
        self.id = "\(index)-\(text)"
        self.index = index
        self.text = text
        self.comment = comment
        self.source = source
        self.category = category
    }
}

/// 实时译文预览状态
public enum TranslationPreviewState: Equatable, Codable, Sendable {
    case hidden
    case loading(sourceText: String, target: TargetLanguage)
    case ready(sourceText: String, translatedText: String, target: TargetLanguage, latencyMs: Double)
    case failed(sourceText: String, target: TargetLanguage, reason: String)
}

/// 整句校对字符级 Diff 片段（供候选窗底栏高亮展示错字纠偏位置）
public struct ProofreadDiffSegment: Equatable, Codable, Sendable {
    public let text: String
    public let isChanged: Bool
    public let originalText: String?

    public init(text: String, isChanged: Bool, originalText: String? = nil) {
        self.text = text
        self.isChanged = isChanged
        self.originalText = originalText
    }
}

/// 整句暂存与整体错字纠偏状态
public enum DraftProofreadState: Equatable, Codable, Sendable {
    case idle
    case checking(sourceText: String)
    case clean(sourceText: String, latencyMs: Double, backendLabel: String)
    case suggested(
        sourceText: String,
        correctedText: String,
        segments: [ProofreadDiffSegment],
        changeCount: Int,
        latencyMs: Double,
        backendLabel: String
    )
    case unavailable(sourceText: String)
}

/// 候选窗渲染快照（主线程只读消费）
public struct CandidatePanelSnapshot: Equatable, Sendable {
    public let isVisible: Bool
    public let mode: InputMode
    public let preedit: String
    public let selectedText: String
    public let candidates: [PinyinCandidate]
    public let highlightedIndex: Int
    public let pageNo: Int
    public let hasNextPage: Bool
    public let showTranslationBar: Bool
    public let translationSourcePreview: String
    public let translationPreview: TranslationPreviewState
    public let translateSpaceCommitsTranslation: Bool
    public let isGlobalTranslateMode: Bool
    public let showDraftBar: Bool
    public let draftSourcePreview: String
    public let draftCommittedLength: Int
    public let draftProofreadState: DraftProofreadState
    public let draftSpaceCommitsDraft: Bool
    public let isGlobalDraftMode: Bool
    public let isSingleCharMode: Bool
    public let singleCharProgressHint: String
    public let canToggleSingleCharMode: Bool
    public let showLanguagePicker: Bool
    public let languagePickerHighlightedIndex: Int
    public let isCodingModeActive: Bool
    /// 当前智能识别或手动锁定的专业场景（如游戏/数学/美术/科学；.general 表示通用）
    public let activeScene: InputSceneDomain
    /// 当前场景是否由用户手动锁定
    public let isSceneLocked: Bool
    public let predictions: [String]
    public let predictionHighlightedIndex: Int
    /// 联想条当前是否允许直接按 1/2/3 单手直选（false 时展示 ⌥1/⌥2/⌥3 提示）
    public let predictionDirectDigitSelect: Bool
    public let activeModelLabel: String?

    public init(
        isVisible: Bool = false,
        mode: InputMode = .chinesePinyin,
        preedit: String = "",
        selectedText: String = "",
        candidates: [PinyinCandidate] = [],
        highlightedIndex: Int = 0,
        pageNo: Int = 0,
        hasNextPage: Bool = false,
        showTranslationBar: Bool = false,
        translationSourcePreview: String = "",
        translationPreview: TranslationPreviewState = .hidden,
        translateSpaceCommitsTranslation: Bool = true,
        isGlobalTranslateMode: Bool = false,
        showDraftBar: Bool = false,
        draftSourcePreview: String = "",
        draftCommittedLength: Int = 0,
        draftProofreadState: DraftProofreadState = .idle,
        draftSpaceCommitsDraft: Bool = true,
        isGlobalDraftMode: Bool = false,
        isSingleCharMode: Bool = false,
        singleCharProgressHint: String = "",
        canToggleSingleCharMode: Bool = false,
        showLanguagePicker: Bool = false,
        languagePickerHighlightedIndex: Int = 0,
        isCodingModeActive: Bool = false,
        activeScene: InputSceneDomain = .general,
        isSceneLocked: Bool = false,
        predictions: [String] = [],
        predictionHighlightedIndex: Int = 0,
        predictionDirectDigitSelect: Bool = true,
        activeModelLabel: String? = nil
    ) {
        self.isVisible = isVisible
        self.mode = mode
        self.preedit = preedit
        self.selectedText = selectedText
        self.candidates = candidates
        self.highlightedIndex = highlightedIndex
        self.pageNo = pageNo
        self.hasNextPage = hasNextPage
        self.showTranslationBar = showTranslationBar
        self.translationSourcePreview = translationSourcePreview
        self.translationPreview = translationPreview
        self.translateSpaceCommitsTranslation = translateSpaceCommitsTranslation
        self.isGlobalTranslateMode = isGlobalTranslateMode
        self.showDraftBar = showDraftBar
        self.draftSourcePreview = draftSourcePreview
        self.draftCommittedLength = draftCommittedLength
        self.draftProofreadState = draftProofreadState
        self.draftSpaceCommitsDraft = draftSpaceCommitsDraft
        self.isGlobalDraftMode = isGlobalDraftMode
        self.isSingleCharMode = isSingleCharMode
        self.singleCharProgressHint = singleCharProgressHint
        self.canToggleSingleCharMode = canToggleSingleCharMode
        self.showLanguagePicker = showLanguagePicker
        self.languagePickerHighlightedIndex = languagePickerHighlightedIndex
        self.isCodingModeActive = isCodingModeActive
        self.activeScene = activeScene
        self.isSceneLocked = isSceneLocked
        self.predictions = predictions
        self.predictionHighlightedIndex = predictionHighlightedIndex
        self.predictionDirectDigitSelect = predictionDirectDigitSelect
        self.activeModelLabel = activeModelLabel
    }

    public static let empty = CandidatePanelSnapshot()
}

/// 推理服务运行状态与内存遥测
public struct InferenceServiceStatus: Codable, Sendable {
    public let activeSlot: String
    public let activeModelName: String
    public let physicalFootprintMB: Double
    public let memoryBudgetMB: Double
    public let cachedTranslations: Int

    public init(
        activeSlot: String,
        activeModelName: String,
        physicalFootprintMB: Double,
        memoryBudgetMB: Double,
        cachedTranslations: Int
    ) {
        self.activeSlot = activeSlot
        self.activeModelName = activeModelName
        self.physicalFootprintMB = physicalFootprintMB
        self.memoryBudgetMB = memoryBudgetMB
        self.cachedTranslations = cachedTranslations
    }
}
