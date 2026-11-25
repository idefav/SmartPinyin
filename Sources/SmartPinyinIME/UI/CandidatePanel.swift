import AppKit
import SharedIPC

/// 纯 AppKit 原生毛玻璃悬浮候选窗（NSVisualEffectView + NSStackView）：
/// - 同一帧同步计算精确宽高，彻底消除 SwiftUI @Published 异步测尺寸导致的左右裁切、换行与直角阴影问题
/// - 翻译模式下自动挂载独立圆角「翻译栏」卡片：先实时展示译文，支持点击切换语种、空格/点击上屏译文、Shift+回车/点击上屏中文原文
/// - 具备 ownerID 归属保护，免疫 Electron 焦点失序 deactivateServer 误关窗口
/// - 兼容全屏 App Space 与多显示器边缘防溢出
@MainActor
public final class CandidatePanelController {
    public static let shared = CandidatePanelController()

    private let panel: NSPanel
    private let glassView: NSVisualEffectView
    private let rootStack: NSStackView

    private let headerRow = NSStackView()
    private let preeditLabel = NSTextField(labelWithString: "")
    private let modeBadgeButton = PillButton()

    private let candidatesRow = NSStackView()

    // 独立圆角翻译栏卡片
    private let translationCard = ClickableContainerView()
    private let translationCardStack = NSStackView()
    private let translationBarTopRow = NSStackView()
    private let translationLangButton = PillButton()
    private let translationScopeButton = PillButton()
    private let translationSourceLabel = NSTextField(labelWithString: "")
    private let translationMetaLabel = NSTextField(labelWithString: "")
    private let commitOriginalButton = PillButton()
    private let commitTranslationButton = PillButton()
    private let translationTextLabel = NSTextField(wrappingLabelWithString: "")

    // 1–6 语种直选胶囊条（双击右 Option 或点击 [中→EN ▾] 原地展开）
    private let languagePickerRow = NSStackView()

    private let predictionRow = NSStackView()

    private var headerWidthConstraint: NSLayoutConstraint?
    private var candidatesWidthConstraint: NSLayoutConstraint?
    private var translationWidthConstraint: NSLayoutConstraint?
    private var languagePickerWidthConstraint: NSLayoutConstraint?
    private var predictionWidthConstraint: NSLayoutConstraint?

    private var currentSnapshot: CandidatePanelSnapshot = .empty
    private var currentOwnerID: ObjectIdentifier?

    public var onSelectCandidate: ((Int) -> Void)?
    public var onToggleTranslateMode: (() -> Void)?
    public var onToggleGlobalTranslateScope: (() -> Void)?
    public var onToggleLanguagePicker: (() -> Void)?
    public var onSelectTargetLanguage: ((TargetLanguage) -> Void)?
    public var onCycleTargetLanguage: (() -> Void)?
    public var onCommitTranslation: (() -> Void)?
    public var onCommitOriginalChinese: (() -> Void)?
    public var onSelectPrediction: ((Int) -> Void)?
    public var onClosePanel: (() -> Void)?

    public var candidateFontSize: CGFloat = 15 {
        didSet {
            preeditLabel.font = NSFont.monospacedSystemFont(ofSize: max(11, candidateFontSize - 2), weight: .medium)
            translationTextLabel.font = NSFont.systemFont(ofSize: max(13, candidateFontSize - 1), weight: .medium)
        }
    }
    public var showSourceBadges: Bool = true
    public var showLiteraryBadges: Bool = true
    public var showDomainBadges: Bool = false

    public var isVisible: Bool { panel.isVisible }

    public var isShowingPredictionsOnly: Bool {
        panel.isVisible
            && currentSnapshot.candidates.isEmpty
            && currentSnapshot.preedit.isEmpty
            && !currentSnapshot.showTranslationBar
            && !currentSnapshot.showLanguagePicker
            && !currentSnapshot.predictions.isEmpty
    }

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        self.panel = panel

        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 11
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.75
        glass.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        glass.autoresizingMask = [.width, .height]
        self.glassView = glass

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.detachesHiddenViews = true
        root.spacing = 6
        root.edgeInsets = NSEdgeInsets(top: 8, left: 11, bottom: 8, right: 11)
        root.translatesAutoresizingMaskIntoConstraints = false
        self.rootStack = root

        // 1. 顶部行（拼音 preedit + 模式胶囊）
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10
        preeditLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        preeditLabel.textColor = .labelColor
        preeditLabel.lineBreakMode = .byTruncatingMiddle
        preeditLabel.usesSingleLineMode = true
        preeditLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        modeBadgeButton.toolTip = "点击一键开关实时翻译（拼写时可按 Tab）"
        modeBadgeButton.onTap = {
            CandidatePanelController.shared.onToggleTranslateMode?()
        }
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true

        headerRow.addArrangedSubview(preeditLabel)
        headerRow.addArrangedSubview(headerSpacer)
        headerRow.addArrangedSubview(modeBadgeButton)

        // 2. 候选词行
        candidatesRow.orientation = .horizontal
        candidatesRow.alignment = .centerY
        candidatesRow.spacing = 4

        // 3. 独立圆角翻译栏卡片
        translationCard.wantsLayer = true
        translationCard.layer?.cornerRadius = 8
        translationCard.layer?.borderWidth = 0.75
        translationCard.onTap = {
            CandidatePanelController.shared.onCommitTranslation?()
        }

        translationCardStack.orientation = .vertical
        translationCardStack.alignment = .leading
        translationCardStack.spacing = 5
        translationCardStack.edgeInsets = NSEdgeInsets(top: 7, left: 9, bottom: 7, right: 9)
        translationCardStack.translatesAutoresizingMaskIntoConstraints = false

        translationBarTopRow.orientation = .horizontal
        translationBarTopRow.alignment = .centerY
        translationBarTopRow.spacing = 6

        translationLangButton.toolTip = "点击展开 1–6 语种直选条（拼写时可按 Shift+Tab）"
        translationLangButton.onTap = {
            if let toggle = CandidatePanelController.shared.onToggleLanguagePicker {
                toggle()
            } else {
                CandidatePanelController.shared.onCycleTargetLanguage?()
            }
        }

        translationScopeButton.toolTip = "点击切换「本句临时」与「全局翻译」（⌥Tab / 双击 Tab）"
        translationScopeButton.onTap = {
            CandidatePanelController.shared.onToggleGlobalTranslateScope?()
        }

        translationSourceLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        translationSourceLabel.textColor = .secondaryLabelColor
        translationSourceLabel.lineBreakMode = .byTruncatingMiddle
        translationSourceLabel.usesSingleLineMode = true
        translationSourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        translationMetaLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        translationMetaLabel.textColor = .tertiaryLabelColor
        translationMetaLabel.usesSingleLineMode = true
        translationMetaLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        commitOriginalButton.toolTip = "上屏中文原文 (Shift+Return)"
        commitOriginalButton.onTap = {
            CandidatePanelController.shared.onCommitOriginalChinese?()
        }

        commitTranslationButton.toolTip = "直接上屏译文 (Space / Return)"
        commitTranslationButton.onTap = {
            CandidatePanelController.shared.onCommitTranslation?()
        }

        let transHeaderSpacer = NSView()
        transHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        transHeaderSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 6).isActive = true

        translationBarTopRow.addArrangedSubview(translationLangButton)
        translationBarTopRow.addArrangedSubview(translationScopeButton)
        translationBarTopRow.addArrangedSubview(translationSourceLabel)
        translationBarTopRow.addArrangedSubview(transHeaderSpacer)
        translationBarTopRow.addArrangedSubview(translationMetaLabel)
        translationBarTopRow.addArrangedSubview(commitOriginalButton)
        translationBarTopRow.addArrangedSubview(commitTranslationButton)

        translationTextLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        translationTextLabel.textColor = .labelColor
        translationTextLabel.alignment = .left
        translationTextLabel.maximumNumberOfLines = 3
        translationTextLabel.preferredMaxLayoutWidth = 560
        translationTextLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        translationCardStack.addArrangedSubview(translationBarTopRow)
        translationCardStack.addArrangedSubview(translationTextLabel)

        translationCard.addSubview(translationCardStack)
        NSLayoutConstraint.activate([
            translationCardStack.topAnchor.constraint(equalTo: translationCard.topAnchor),
            translationCardStack.bottomAnchor.constraint(equalTo: translationCard.bottomAnchor),
            translationCardStack.leadingAnchor.constraint(equalTo: translationCard.leadingAnchor),
            translationCardStack.trailingAnchor.constraint(equalTo: translationCard.trailingAnchor),
            translationBarTopRow.widthAnchor.constraint(equalTo: translationCardStack.widthAnchor, constant: -18),
            translationTextLabel.widthAnchor.constraint(equalTo: translationCardStack.widthAnchor, constant: -18)
        ])

        // 3.5 1–6 语种直选胶囊条
        languagePickerRow.orientation = .horizontal
        languagePickerRow.alignment = .centerY
        languagePickerRow.spacing = 5

        // 4. 联想词句行
        predictionRow.orientation = .horizontal
        predictionRow.alignment = .centerY
        predictionRow.spacing = 7

        root.addArrangedSubview(headerRow)
        root.addArrangedSubview(candidatesRow)
        root.addArrangedSubview(translationCard)
        root.addArrangedSubview(languagePickerRow)
        root.addArrangedSubview(predictionRow)

        glass.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: glass.topAnchor),
            root.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: glass.trailingAnchor)
        ])

        headerWidthConstraint = headerRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -22)
        candidatesWidthConstraint = candidatesRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -22)
        translationWidthConstraint = translationCard.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -22)
        languagePickerWidthConstraint = languagePickerRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -22)
        predictionWidthConstraint = predictionRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -22)

        panel.contentView = glass
    }

    public func claimOwnership(ownerID: ObjectIdentifier) {
        currentOwnerID = ownerID
    }

    public func isOwner(_ ownerID: ObjectIdentifier) -> Bool {
        currentOwnerID == nil || currentOwnerID == ownerID
    }

    public func update(
        snapshot: CandidatePanelSnapshot,
        anchorRect: NSRect,
        ownerID: ObjectIdentifier
    ) {
        guard isOwner(ownerID) else { return }
        currentOwnerID = ownerID

        guard snapshot.isVisible else {
            hide(ownerID: ownerID)
            return
        }

        currentSnapshot = snapshot
        applySnapshotSynchronously(snapshot)

        glassView.layoutSubtreeIfNeeded()
        let naturalSize = glassView.fittingSize
        let size = NSSize(
            width: max(140, min(840, ceil(naturalSize.width))),
            height: max(34, min(340, ceil(naturalSize.height)))
        )

        let origin = computeSafeOrigin(anchorRect: anchorRect, panelSize: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        glassView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        panel.invalidateShadow()
        panel.orderFrontRegardless()
    }

    public func hide(ownerID: ObjectIdentifier? = nil) {
        if let ownerID, let current = currentOwnerID, current != ownerID {
            return
        }
        currentSnapshot = .empty
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    // MARK: - 同步视图更新

    private func applySnapshotSynchronously(_ snap: CandidatePanelSnapshot) {
        let isPredictionOnly = snap.candidates.isEmpty
            && snap.preedit.isEmpty
            && !snap.showTranslationBar
            && !snap.predictions.isEmpty

        // 1. 顶部行
        headerRow.isHidden = isPredictionOnly
        if !isPredictionOnly {
            preeditLabel.stringValue = snap.preedit
            preeditLabel.isHidden = snap.preedit.isEmpty
            configureModeBadge(
                snap.mode,
                isCodingMode: snap.isCodingModeActive,
                activeScene: snap.activeScene,
                isSceneLocked: snap.isSceneLocked
            )
        }

        // 2. 候选词行
        candidatesRow.arrangedSubviews.forEach { view in
            candidatesRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        candidatesRow.isHidden = snap.candidates.isEmpty
        for (idx, item) in snap.candidates.enumerated() {
            let isHighlighted = (idx == snap.highlightedIndex)
            let badge = resolveCandidateBadge(for: item, index: idx)
            let btn = CandidateChipButton(
                index: idx,
                text: item.text,
                fontSize: candidateFontSize,
                isHighlighted: isHighlighted,
                badge: badge
            ) {
                CandidatePanelController.shared.onSelectCandidate?(idx)
            }
            candidatesRow.addArrangedSubview(btn)
        }
        if !snap.candidates.isEmpty {
            let trailingSpacer = NSView()
            trailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            candidatesRow.addArrangedSubview(trailingSpacer)
        }

        // 3. 独立翻译栏卡片（翻译模式下始终展示，先呈现译文再按空格上屏）
        let shouldShowBar = snap.showTranslationBar || snap.translationPreview != .hidden
        translationCard.isHidden = !shouldShowBar
        if shouldShowBar {
            translationCard.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.085).cgColor
            translationCard.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.24).cgColor

            let activeTarget: TargetLanguage = {
                if let t = snap.mode.translationTarget { return t }
                switch snap.translationPreview {
                case .loading(_, let t), .ready(_, _, let t, _), .failed(_, let t, _):
                    return t
                case .hidden:
                    return .english
                }
            }()

            translationLangButton.configure(
                title: "中→\(activeTarget.shortBadge) \(snap.showLanguagePicker ? "▴" : "▾")",
                textColor: .controlAccentColor,
                fillColor: NSColor.controlAccentColor.withAlphaComponent(0.16),
                font: .systemFont(ofSize: 10.5, weight: .semibold),
                horizontalPad: 6,
                verticalPad: 2
            )

            if snap.isGlobalTranslateMode {
                translationScopeButton.configure(
                    title: "全局",
                    textColor: .white,
                    fillColor: NSColor.controlAccentColor.withAlphaComponent(0.85),
                    font: .systemFont(ofSize: 9.5, weight: .semibold),
                    horizontalPad: 5,
                    verticalPad: 2
                )
                translationScopeButton.toolTip = "全局翻译已开启 · 点击或按 ⌃⌥T / ⌥⇥ 关闭全局翻译"
            } else {
                translationScopeButton.configure(
                    title: "本句",
                    textColor: .secondaryLabelColor,
                    fillColor: NSColor.secondaryLabelColor.withAlphaComponent(0.14),
                    font: .systemFont(ofSize: 9.5, weight: .medium),
                    horizontalPad: 5,
                    verticalPad: 2
                )
                translationScopeButton.toolTip = "仅本句临时翻译 · 点击或按 ⌥⇥ / 双击 Tab 锁定为全局"
            }

            let src = snap.translationSourcePreview
            translationSourceLabel.stringValue = src.isEmpty ? "" : "「\(src)」"
            translationSourceLabel.isHidden = src.isEmpty

            commitOriginalButton.configure(
                title: "⇧⏎ 原文",
                textColor: .secondaryLabelColor,
                fillColor: NSColor.secondaryLabelColor.withAlphaComponent(0.12),
                font: .systemFont(ofSize: 10, weight: .medium),
                horizontalPad: 5,
                verticalPad: 2
            )
            commitOriginalButton.isHidden = src.isEmpty

            commitTranslationButton.configure(
                title: snap.translateSpaceCommitsTranslation ? "␣ 上屏译文" : "⏎ 上屏译文",
                textColor: .white,
                fillColor: .controlAccentColor,
                font: .systemFont(ofSize: 10, weight: .semibold),
                horizontalPad: 6,
                verticalPad: 2
            )
            commitTranslationButton.isHidden = src.isEmpty

            switch snap.translationPreview {
            case .hidden:
                let keyGuide = snap.translateSpaceCommitsTranslation
                    ? "1–9 选词拼句 · ␣ 上屏译文"
                    : "␣ 选词拼句 · ⏎ 上屏译文"
                translationTextLabel.stringValue = src.isEmpty
                    ? "输入拼音将实时展示 \(activeTarget.displayName) 译文 · \(keyGuide)"
                    : "继续输入拼音以生成 \(activeTarget.displayName) 译文 · \(keyGuide)"
                translationTextLabel.textColor = .secondaryLabelColor
                translationMetaLabel.stringValue = ""
                translationMetaLabel.isHidden = true
            case .loading(_, let target):
                translationTextLabel.stringValue = "⋯ 正在自动翻译为 \(target.displayName)…"
                translationTextLabel.textColor = .secondaryLabelColor
                translationMetaLabel.stringValue = ""
                translationMetaLabel.isHidden = true
            case .ready(_, let translated, _, let latencyMs):
                translationTextLabel.stringValue = translated
                translationTextLabel.textColor = .labelColor
                translationMetaLabel.stringValue = latencyMs < 1.0 ? "缓存" : String(format: "%.0fms", latencyMs)
                translationMetaLabel.isHidden = false
            case .failed(_, _, let reason):
                translationTextLabel.stringValue = "翻译暂不可用：\(reason)（可按 ⇧⏎ 上屏中文原文）"
                translationTextLabel.textColor = .secondaryLabelColor
                translationMetaLabel.stringValue = ""
                translationMetaLabel.isHidden = true
            }
        }

        // 3.5 1–6 语种直选胶囊条（双击右 Option 或点击 [中→EN ▾] 展开，1 次点击或按 1–6 直达）
        languagePickerRow.arrangedSubviews.forEach { view in
            languagePickerRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        languagePickerRow.isHidden = !snap.showLanguagePicker
        if snap.showLanguagePicker {
            let allLangs = TargetLanguage.allCases
            for (idx, lang) in allLangs.enumerated() {
                let isSelected = (idx == snap.languagePickerHighlightedIndex)
                let chip = PillButton()
                let compactName: String = {
                    switch lang {
                    case .english: return "EN"
                    case .japanese: return "日语"
                    case .korean: return "韩语"
                    case .french: return "法语"
                    case .german: return "德语"
                    case .spanish: return "西语"
                    }
                }()
                chip.configure(
                    title: "\(idx + 1) \(compactName)",
                    textColor: isSelected ? .white : .labelColor,
                    fillColor: isSelected ? .controlAccentColor : NSColor.secondaryLabelColor.withAlphaComponent(0.14),
                    font: .systemFont(ofSize: 11.5, weight: isSelected ? .semibold : .medium),
                    horizontalPad: 7,
                    verticalPad: 3
                )
                chip.onTap = {
                    CandidatePanelController.shared.onSelectTargetLanguage?(lang)
                }
                languagePickerRow.addArrangedSubview(chip)
            }
            let pickerSpacer = NSView()
            pickerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            languagePickerRow.addArrangedSubview(pickerSpacer)
        }

        // 4. 联想词句行
        predictionRow.arrangedSubviews.forEach { view in
            predictionRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        predictionRow.isHidden = snap.predictions.isEmpty
        if !snap.predictions.isEmpty {
            let badge = PillButton()
            badge.configure(
                title: "联想",
                textColor: .systemOrange,
                fillColor: NSColor.systemOrange.withAlphaComponent(0.22),
                font: .systemFont(ofSize: 10.5, weight: .semibold),
                horizontalPad: 6,
                verticalPad: 2
            )
            // 不设置 isEnabled = false，避免暗黑模式下 AppKit 自动压暗文字导致看不清
            badge.onTap = nil
            predictionRow.addArrangedSubview(badge)

            let directDigits = snap.predictionDirectDigitSelect
            for (idx, text) in snap.predictions.prefix(3).enumerated() {
                let isFirst = (idx == 0)
                let chip = PillButton()
                let keyPrefix = directDigits ? "\(idx + 1)" : "⌥\(idx + 1)"
                let title = "\(keyPrefix) \(text)"
                chip.configure(
                    title: title,
                    textColor: isFirst ? .labelColor : .secondaryLabelColor,
                    fillColor: isFirst ? NSColor.controlAccentColor.withAlphaComponent(0.16) : .clear,
                    font: .systemFont(ofSize: 13.5, weight: isFirst ? .medium : .regular),
                    horizontalPad: isFirst ? 7 : 5,
                    verticalPad: 2
                )
                chip.toolTip = directDigits
                    ? "直接按 \(idx + 1)（或 ⌥\(idx + 1) / 点击）上屏；也可直接敲首字母融入候选栏"
                    : "按 ⌥\(idx + 1)（或点击）上屏；也可直接敲首字母融入候选栏"
                chip.onTap = {
                    CandidatePanelController.shared.onSelectPrediction?(idx)
                }
                predictionRow.addArrangedSubview(chip)
            }

            let predSpacer = NSView()
            predSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            predictionRow.addArrangedSubview(predSpacer)

            let closeBtn = PillButton()
            closeBtn.configure(
                title: "✕",
                textColor: .secondaryLabelColor,
                fillColor: NSColor.secondaryLabelColor.withAlphaComponent(0.12),
                font: .systemFont(ofSize: 10, weight: .bold),
                horizontalPad: 5,
                verticalPad: 2
            )
            closeBtn.toolTip = "关闭联想 (Esc)"
            closeBtn.onTap = {
                CandidatePanelController.shared.onClosePanel?()
            }
            predictionRow.addArrangedSubview(closeBtn)
        }

        // 仅对当前处于视图树内的可见行激活等宽约束，完全兼容 detachesHiddenViews = true
        headerWidthConstraint?.isActive = !headerRow.isHidden
        candidatesWidthConstraint?.isActive = !candidatesRow.isHidden
        translationWidthConstraint?.isActive = !translationCard.isHidden
        languagePickerWidthConstraint?.isActive = !languagePickerRow.isHidden
        predictionWidthConstraint?.isActive = !predictionRow.isHidden
    }

    /// 按清晰视觉优先级为每个候选决定最多 1 个微标（绝不双标拥挤）：
    /// 强功能（纠/联） > 语义微胶囊（诗/成） > 可选激活领域微胶囊（游/数/计/美/科/医/财） > 弱来源（文/记/✦）
    private func resolveCandidateBadge(for item: PinyinCandidate, index idx: Int) -> CandidateBadgeDescriptor? {
        if showSourceBadges {
            switch item.source {
            case .typoCorrected:
                return CandidateBadgeDescriptor(text: "纠", style: .inlineText(.controlAccentColor))
            case .neuralPrediction:
                return CandidateBadgeDescriptor(text: "联", style: .inlineText(.controlAccentColor))
            default:
                break
            }
        }

        if let cat = item.category {
            if cat.isLiterary && showLiteraryBadges {
                switch cat {
                case .poetry:
                    return CandidateBadgeDescriptor(
                        text: "诗",
                        style: .microCapsule(text: Self.poetryBadgeTextColor, fill: Self.poetryBadgeFillColor)
                    )
                case .idiom:
                    return CandidateBadgeDescriptor(
                        text: "成",
                        style: .microCapsule(text: Self.idiomBadgeTextColor, fill: Self.idiomBadgeFillColor)
                    )
                default:
                    break
                }
            } else if !cat.isLiterary && showDomainBadges {
                return CandidateBadgeDescriptor(
                    text: cat.shortBadge,
                    style: .microCapsule(text: Self.domainBadgeTextColor, fill: Self.domainBadgeFillColor)
                )
            }
        }

        guard showSourceBadges else { return nil }
        switch item.source {
        case .documentContext:
            return CandidateBadgeDescriptor(text: "文", style: .inlineText(.systemTeal))
        case .workingMemory:
            return CandidateBadgeDescriptor(text: "记", style: .inlineText(.systemOrange))
        case .userMemory where idx <= 2:
            return CandidateBadgeDescriptor(text: "记", style: .inlineText(.systemOrange))
        case .neuralReranked where idx == 0:
            return CandidateBadgeDescriptor(text: "✦", style: .inlineText(.controlAccentColor))
        default:
            return nil
        }
    }

    private static let poetryBadgeTextColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.98, green: 0.68, blue: 0.86, alpha: 1.0)
            : NSColor(calibratedRed: 0.62, green: 0.16, blue: 0.45, alpha: 1.0)
    }

    private static let poetryBadgeFillColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.90, green: 0.36, blue: 0.68, alpha: 0.24)
            : NSColor(calibratedRed: 0.78, green: 0.24, blue: 0.56, alpha: 0.14)
    }

    private static let idiomBadgeTextColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.54, green: 0.94, blue: 0.78, alpha: 1.0)
            : NSColor(calibratedRed: 0.08, green: 0.48, blue: 0.34, alpha: 1.0)
    }

    private static let idiomBadgeFillColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.58, alpha: 0.24)
            : NSColor(calibratedRed: 0.12, green: 0.62, blue: 0.44, alpha: 0.14)
    }

    private static let domainBadgeTextColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.66, green: 0.84, blue: 1.0, alpha: 1.0)
            : NSColor(calibratedRed: 0.12, green: 0.40, blue: 0.72, alpha: 1.0)
    }

    private static let domainBadgeFillColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.28, green: 0.60, blue: 0.98, alpha: 0.24)
            : NSColor(calibratedRed: 0.18, green: 0.48, blue: 0.88, alpha: 0.13)
    }

    private func configureModeBadge(
        _ mode: InputMode,
        isCodingMode: Bool,
        activeScene: InputSceneDomain,
        isSceneLocked: Bool
    ) {
        let sceneSuffix: String = {
            guard activeScene != .general else { return "" }
            let prefix = isSceneLocked ? "🔒" : ""
            return "\(prefix)\(activeScene.panelShortLabel)"
        }()

        switch mode {
        case .translateOnCommit(let lang):
            modeBadgeButton.isEnabled = true
            let title = isCodingMode ? "译 · \(lang.shortBadge) · Code" : "译 · \(lang.shortBadge)"
            modeBadgeButton.configure(
                title: title,
                textColor: .controlAccentColor,
                fillColor: NSColor.controlAccentColor.withAlphaComponent(0.18),
                font: .systemFont(ofSize: 10.5, weight: .semibold),
                horizontalPad: 7,
                verticalPad: 2
            )
        case .chinesePinyin:
            modeBadgeButton.isEnabled = true
            let title: String
            let tintText: NSColor
            let tintFill: NSColor
            let weight: NSFont.Weight
            if !sceneSuffix.isEmpty && !(isCodingMode && activeScene == .computerScience && !isSceneLocked) {
                title = isCodingMode ? "拼 · \(sceneSuffix) · Code" : "拼 · \(sceneSuffix)"
                tintText = Self.sceneAccentColor(for: activeScene)
                tintFill = tintText.withAlphaComponent(0.18)
                weight = .semibold
            } else if isCodingMode {
                title = "拼 · Code"
                tintText = .systemOrange
                tintFill = NSColor.systemOrange.withAlphaComponent(0.16)
                weight = .semibold
            } else {
                title = "拼"
                tintText = .secondaryLabelColor
                tintFill = NSColor.secondaryLabelColor.withAlphaComponent(0.14)
                weight = .medium
            }
            modeBadgeButton.configure(
                title: title,
                textColor: tintText,
                fillColor: tintFill,
                font: .systemFont(ofSize: 10.5, weight: weight),
                horizontalPad: 6,
                verticalPad: 2
            )
        case .directEnglish:
            modeBadgeButton.isEnabled = false
            modeBadgeButton.configure(
                title: "EN",
                textColor: .systemTeal,
                fillColor: NSColor.systemTeal.withAlphaComponent(0.18),
                font: .systemFont(ofSize: 10.5, weight: .semibold),
                horizontalPad: 7,
                verticalPad: 2
            )
        }
    }

    private static func sceneAccentColor(for domain: InputSceneDomain) -> NSColor {
        switch domain {
        case .gaming: return .systemPink
        case .mathematics: return .systemIndigo
        case .computerScience: return .systemOrange
        case .artDesign: return .systemPurple
        case .science: return .systemTeal
        case .literature: return poetryBadgeTextColor
        case .medicine: return .systemGreen
        case .financeLaw: return .systemYellow
        case .general: return .secondaryLabelColor
        }
    }

    /// 多显示器边界防溢出定位：优先放在光标下方，若贴近屏幕底边则自动翻转至光标上方
    private func computeSafeOrigin(anchorRect: NSRect, panelSize: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchorRect.origin) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(anchorRect) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 6

        var x = anchorRect.minX
        if x + panelSize.width > visibleFrame.maxX - margin {
            x = max(visibleFrame.minX + margin, visibleFrame.maxX - panelSize.width - margin)
        }
        if x < visibleFrame.minX + margin {
            x = visibleFrame.minX + margin
        }

        var y = anchorRect.minY - panelSize.height - margin
        if y < visibleFrame.minY + margin {
            y = min(visibleFrame.maxY - panelSize.height - margin, anchorRect.maxY + margin)
        }
        return NSPoint(x: x, y: y)
    }
}

// MARK: - 原生单行候选词条、可点击容器与胶囊按钮

private final class ClickableContainerView: NSView {
    var onTap: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }
}

private struct CandidateBadgeDescriptor {
    enum Style {
        case inlineText(NSColor)
        case microCapsule(text: NSColor, fill: NSColor)
    }

    let text: String
    let style: Style
}

private final class CandidateChipButton: NSView {
    private let onTap: () -> Void

    init(
        index: Int,
        text: String,
        fontSize: CGFloat,
        isHighlighted: Bool,
        badge: CandidateBadgeDescriptor?,
        onTap: @escaping () -> Void
    ) {
        self.onTap = onTap
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = isHighlighted
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 3.5
        row.edgeInsets = NSEdgeInsets(top: 3, left: 7, bottom: 4, right: 7)
        row.translatesAutoresizingMaskIntoConstraints = false

        let numLabel = NSTextField(labelWithString: "\(index + 1)")
        numLabel.font = NSFont.monospacedSystemFont(ofSize: max(10, fontSize - 4), weight: .medium)
        numLabel.textColor = isHighlighted ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
        numLabel.usesSingleLineMode = true
        numLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let wordLabel = NSTextField(labelWithString: text)
        wordLabel.font = NSFont.systemFont(ofSize: fontSize, weight: isHighlighted ? .semibold : .regular)
        wordLabel.textColor = isHighlighted ? .white : .labelColor
        wordLabel.usesSingleLineMode = true
        wordLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.addArrangedSubview(numLabel)
        row.addArrangedSubview(wordLabel)

        if let badge, !badge.text.isEmpty {
            switch badge.style {
            case .inlineText(let color):
                let label = NSTextField(labelWithString: badge.text)
                label.font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
                label.textColor = isHighlighted ? NSColor.white.withAlphaComponent(0.92) : color
                label.usesSingleLineMode = true
                label.setContentCompressionResistancePriority(.required, for: .horizontal)
                row.addArrangedSubview(label)

            case .microCapsule(let textColor, let fillColor):
                let pill = NSView()
                pill.wantsLayer = true
                pill.layer?.cornerRadius = 4
                pill.layer?.backgroundColor = isHighlighted
                    ? NSColor.white.withAlphaComponent(0.24).cgColor
                    : fillColor.cgColor
                pill.translatesAutoresizingMaskIntoConstraints = false

                let label = NSTextField(labelWithString: badge.text)
                label.font = NSFont.systemFont(ofSize: 9.0, weight: .semibold)
                label.textColor = isHighlighted ? .white : textColor
                label.usesSingleLineMode = true
                label.translatesAutoresizingMaskIntoConstraints = false
                label.setContentCompressionResistancePriority(.required, for: .horizontal)
                pill.addSubview(label)
                NSLayoutConstraint.activate([
                    label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 1),
                    label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -1),
                    label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 3.5),
                    label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -3.5)
                ])
                pill.setContentCompressionResistancePriority(.required, for: .horizontal)
                pill.setContentHuggingPriority(.required, for: .horizontal)
                row.addArrangedSubview(pill)
            }
        }

        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        onTap()
    }
}

private final class PillButton: NSButton {
    var onTap: (() -> Void)?
    private var hPad: CGFloat = 6
    private var vPad: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .inline
        wantsLayer = true
        target = self
        action = #selector(handleClick)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(
        title: String,
        textColor: NSColor,
        fillColor: NSColor,
        font: NSFont,
        horizontalPad: CGFloat,
        verticalPad: CGFloat
    ) {
        self.hPad = horizontalPad
        self.vPad = verticalPad
        self.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: textColor]
        )
        self.layer?.backgroundColor = fillColor.cgColor
        self.layer?.cornerRadius = 7
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: ceil(base.width + hPad * 2), height: ceil(base.height + vPad * 2))
    }

    @objc private func handleClick() {
        onTap?()
    }
}
