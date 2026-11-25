import Foundation
import SharedIPC

/// 实时场景推断结果（0ms 驱动 CandidateFusionRanker 领域调权与候选窗右上角场景微标）
public struct SceneContextState: Equatable, Sendable {
    public let primaryScene: InputSceneDomain
    public let confidence: Double
    /// 各激活领域的实时权重（已融合 App 先验、上下文命中、迟滞平滑与用户自定义倍率）
    public let domainScores: [InputSceneDomain: Double]
    public let isLocked: Bool

    public static let general = SceneContextState(
        primaryScene: .general,
        confidence: 0,
        domainScores: [:],
        isLocked: false
    )

    public init(
        primaryScene: InputSceneDomain,
        confidence: Double,
        domainScores: [InputSceneDomain: Double],
        isLocked: Bool
    ) {
        self.primaryScene = primaryScene
        self.confidence = confidence
        self.domainScores = domainScores
        self.isLocked = isLocked
    }
}

/// 0ms 本地场景智能感知引擎（纯 L1 内存计算 < 0.15ms，100% 离线，密码框硬阻断）：
/// - 融合三类信号：
///   1. 宿主应用软先验（IDE/终端 → 计算机、Figma/Blender/PS → 美术、Steam/Discord → 游戏等，权重 0.35）
///   2. 光标前文最近 120 字 + 短期工作记忆近期主题词的滑窗领域命中（权重 0.65，随时可压过 App 先验）
///   3. 迟滞防抖（进入阈值 >= 0.55，维持阈值 >= 0.28，跨应用或 3 分钟空闲自动衰减重置）
/// - 支持用户手动锁定场景及按场景自定义优先级倍率（0.0~2.0×）
public final class SceneContextDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var lastAppBundleID: String = ""
    private var lastUpdateTS: TimeInterval = 0
    private var smoothedScores: [InputSceneDomain: Double] = [:]
    private var currentPrimary: InputSceneDomain = .general

    private let enterThreshold: Double = 0.52
    private let holdThreshold: Double = 0.26
    private let staleTimeoutSeconds: TimeInterval = 180.0

    public init() {}

    /// 评估当前上下文场景并返回平滑后的活跃领域分布
    public func evaluate(
        appBundleID: String,
        leftContext: String,
        recentWorkingTerms: [String] = [],
        isSecureInput: Bool,
        preferences: SmartPinyinPreferences,
        tagStore: DomainAndLiteraryTagStore?,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> SceneContextState {
        // 1. 密码框安全硬阻断：绝不读取前文、绝不激活任何场景
        if isSecureInput {
            return .general
        }

        // 2. 用户手动锁定场景时直接生效（优先级最高）
        if let locked = preferences.lockedSceneDomain {
            guard locked != .general else {
                return SceneContextState(primaryScene: .general, confidence: 1.0, domainScores: [:], isLocked: true)
            }
            let mult = preferences.priorityMultiplier(for: locked)
            let score = min(1.5, 1.0 * max(0.5, mult))
            return SceneContextState(
                primaryScene: locked,
                confidence: 1.0,
                domainScores: [locked: score],
                isLocked: true
            )
        }

        guard preferences.enableSmartSceneAdaptation, let tagStore else {
            return .general
        }

        // 3. 计算本次瞬时得分（App 软先验 + 前文滑窗命中 + 短期工作记忆主题词）
        var instant: [InputSceneDomain: Double] = [:]

        // 3A. 宿主应用软先验（0.35，若用户将该场景倍率设为 0 则忽略）
        for (domain, prior) in Self.appPrior(for: appBundleID) {
            let mult = preferences.priorityMultiplier(for: domain)
            guard mult > 0 else { continue }
            instant[domain, default: 0] += prior * mult
        }

        // 3B. 光标前文最近 120 字滑窗扫描（2~5 字 n-gram，越靠近光标权重越高）
        let allowTrad = preferences.traditionalChinese
        let tail = String(leftContext.suffix(120))
        if !tail.isEmpty {
            let hits = Self.scanChineseContext(
                tail,
                tagStore: tagStore,
                allowTraditionalFallback: allowTrad
            )
            for (domain, val) in hits {
                let mult = preferences.priorityMultiplier(for: domain)
                guard mult > 0 else { continue }
                instant[domain, default: 0] += val * mult
            }
        }

        // 3C. 短期工作记忆近期主题词补充（跨换行/刚删改后仍能延续上下文场景！）
        if !recentWorkingTerms.isEmpty {
            for (idx, term) in recentWorkingTerms.prefix(12).enumerated() {
                let mask = tagStore.domainMask(for: term, allowTraditionalFallback: allowTrad)
                guard mask != 0 else { continue }
                let decay = max(0.25, 1.0 - Double(idx) * 0.08)
                let perHit = 0.22 * decay
                for domain in InputSceneDomain.specializedDomains where (mask & domain.bitMask) != 0 {
                    let mult = preferences.priorityMultiplier(for: domain)
                    guard mult > 0 else { continue }
                    instant[domain, default: 0] += perHit * mult
                }
            }
        }

        // 4. 指数滑动平滑 + 迟滞防抖
        lock.lock()
        defer { lock.unlock() }

        let switchedApp = !lastAppBundleID.isEmpty && appBundleID != lastAppBundleID
        let timedOut = lastUpdateTS > 0 && (now - lastUpdateTS) > staleTimeoutSeconds
        if switchedApp || timedOut {
            smoothedScores.removeAll(keepingCapacity: true)
            currentPrimary = .general
        }
        lastAppBundleID = appBundleID
        lastUpdateTS = now

        var updated: [InputSceneDomain: Double] = [:]
        for domain in InputSceneDomain.specializedDomains {
            let prev = smoothedScores[domain] ?? 0
            let cur = min(1.5, instant[domain] ?? 0)
            let blended = (prev > 0) ? (0.35 * prev + 0.65 * cur) : cur
            if blended >= 0.08 {
                updated[domain] = min(1.5, blended)
            }
        }
        smoothedScores = updated

        let ranked = updated.sorted { lhs, rhs in
            if abs(lhs.value - rhs.value) > 1e-6 { return lhs.value > rhs.value }
            return lhs.key.rawValue < rhs.key.rawValue
        }

        if let best = ranked.first {
            if best.value >= enterThreshold {
                // 若当前已锁定某非通用场景，新场景需明显领先（+0.12）才切换，防抖动
                if currentPrimary != .general,
                   currentPrimary != best.key,
                   let curScore = updated[currentPrimary],
                   curScore >= holdThreshold,
                   best.value < curScore + 0.12 {
                    // 维持当前主场景
                } else {
                    currentPrimary = best.key
                }
            } else if currentPrimary != .general {
                let curScore = updated[currentPrimary] ?? 0
                if curScore < holdThreshold {
                    currentPrimary = .general
                }
            }
        } else {
            currentPrimary = .general
        }

        let primaryConf = (currentPrimary == .general) ? 0.0 : min(1.0, updated[currentPrimary] ?? 0.0)
        return SceneContextState(
            primaryScene: currentPrimary,
            confidence: primaryConf,
            domainScores: updated,
            isLocked: false
        )
    }

    public func reset() {
        lock.lock()
        smoothedScores.removeAll(keepingCapacity: true)
        currentPrimary = .general
        lastAppBundleID = ""
        lastUpdateTS = 0
        lock.unlock()
    }

    /// 计算单个候选词在当前活跃场景下的领域提权分（0.0 ~ 1.55，供 CandidateFusionRanker 第 11 维消费）
    public static func domainBoost(
        forCandidateText text: String,
        sceneState: SceneContextState,
        preferences: SmartPinyinPreferences,
        tagStore: DomainAndLiteraryTagStore?
    ) -> Double {
        guard !sceneState.domainScores.isEmpty,
              let tagStore,
              text.count >= 2
        else { return 0 }

        let mask = tagStore.domainMask(
            for: text,
            allowTraditionalFallback: preferences.traditionalChinese
        )
        guard mask != 0 else { return 0 }

        var best: Double = 0
        for (domain, score) in sceneState.domainScores where (mask & domain.bitMask) != 0 {
            guard score >= 0.25 else { continue }
            let mult = preferences.priorityMultiplier(for: domain)
            let isPrimary = (domain == sceneState.primaryScene)
            let base = isPrimary ? min(1.25, score * 1.15) : min(0.65, score * 0.60)
            best = max(best, base * mult)
        }
        return min(1.55, best)
    }

    // MARK: - 宿主应用先验与上下文滑窗扫描

    private static func appPrior(for bundleID: String) -> [(InputSceneDomain, Double)] {
        let lower = bundleID.lowercased()
        guard !lower.isEmpty else { return [] }

        // 1. 开发工具 / 终端 / IDE -> 计算机先验（若在其中写数学/游戏注释，上下文语境权重 0.65 仍可压过先验）
        let devKeys = [
            "xcode", "vscode", "visual-studio", "cursor", "jetbrains", "intellij", "pycharm",
            "goland", "clion", "webstorm", "terminal", "iterm", "warp", "alacritty", "kitty",
            "ghostty", "wezterm", "zed", "sublime", "neovide", "t3code", "t3-code", "antigravity"
        ]
        if devKeys.contains(where: { lower.contains($0) }) {
            return [(.computerScience, 0.36)]
        }

        // 2. 美术 / 设计 / 摄影 / 3D 工具 -> 美术设计强先验
        let artKeys = [
            "figma", "sketch", "photoshop", "illustrator", "indesign", "lightroom", "aftereffects",
            "premiere", "blender", "cinema4d", "maya", "zbrush", "affinity", "pixelmator",
            "procreate", "clipstudio", "krita", "aseprite", "davinci", "finalcut"
        ]
        if artKeys.contains(where: { lower.contains($0) }) {
            return [(.artDesign, 0.56)]
        }

        // 3. 游戏平台 / 游戏语音 / 社区 -> 游戏强先验
        let gameKeys = [
            "steam", "valvesoftware", "blizzard", "battle.net", "epicgames", "riotgames",
            "hoyoverse", "mihoyo", "genshin", "starrail", "discord", "minecraft", "roblox",
            "unity", "unreal", "godot"
        ]
        if gameKeys.contains(where: { lower.contains($0) }) {
            return [(.gaming, 0.56)]
        }

        // 4. 数学 / 科学计算工具 -> 数学 + 科学先验
        let mathSciKeys = [
            "mathematica", "wolfram", "matlab", "rstudio", "texshop", "texstudio", "lyx",
            "geogebra", "jupyter", "pymol", "chemdraw"
        ]
        if mathSciKeys.contains(where: { lower.contains($0) }) {
            return [(.mathematics, 0.50), (.science, 0.36)]
        }

        return []
    }

    /// 对最近中文前文执行 2~5 字滑窗领域命中统计（避免重复重叠计分，靠近光标权重大）
    private static func scanChineseContext(
        _ text: String,
        tagStore: DomainAndLiteraryTagStore,
        allowTraditionalFallback: Bool
    ) -> [InputSceneDomain: Double] {
        let chars = Array(text)
        let n = chars.count
        guard n >= 2 else { return [:] }

        var scores: [InputSceneDomain: Double] = [:]
        var seenTerms = Set<String>()

        // 显式场景提示短语快速增强（如用户直接提到“数学/游戏/美术/物理/化学/医学/编程/古诗”）
        let explicitAnchors: [(String, InputSceneDomain, Double)] = [
            ("打游戏", .gaming, 0.45), ("游戏", .gaming, 0.32), ("副本", .gaming, 0.36), ("排位", .gaming, 0.36),
            ("数学", .mathematics, 0.38), ("证明", .mathematics, 0.25), ("公式", .mathematics, 0.28),
            ("微积分", .mathematics, 0.45), ("线性代数", .mathematics, 0.48), ("矩阵", .mathematics, 0.36),
            ("美术", .artDesign, 0.40), ("画画", .artDesign, 0.40), ("绘画", .artDesign, 0.38),
            ("构图", .artDesign, 0.38), ("配色", .artDesign, 0.38), ("素描", .artDesign, 0.40),
            ("物理", .science, 0.38), ("化学", .science, 0.38), ("生物", .science, 0.34), ("量子", .science, 0.40),
            ("代码", .computerScience, 0.36), ("编程", .computerScience, 0.40), ("算法", .computerScience, 0.34),
            ("古诗", .literature, 0.45), ("诗词", .literature, 0.45), ("成语", .literature, 0.42),
            ("医院", .medicine, 0.28), ("诊断", .medicine, 0.34), ("病历", .medicine, 0.38),
            ("股票", .financeLaw, 0.36), ("财报", .financeLaw, 0.38), ("合同", .financeLaw, 0.30),
        ]
        for (kw, domain, boost) in explicitAnchors where text.contains(kw) {
            scores[domain, default: 0] += boost
        }

        // 从后往前（靠近光标优先）滑窗扫描 5 → 2 字纯汉字片断
        var i = 0
        while i < n {
            guard Self.isHanzi(chars[i]) else {
                i += 1
                continue
            }
            var matchedLen = 0
            let maxLen = min(5, n - i)
            if maxLen >= 2 {
                for len in stride(from: maxLen, through: 2, by: -1) {
                    var allCJK = true
                    for k in 0..<len where !Self.isHanzi(chars[i + k]) {
                        allCJK = false
                        break
                    }
                    guard allCJK else { continue }
                    let slice = String(chars[i..<(i + len)])
                    let mask = tagStore.domainMask(for: slice, allowTraditionalFallback: allowTraditionalFallback)
                    if mask != 0 {
                        matchedLen = len
                        if seenTerms.insert(slice).inserted {
                            // 越接近光标尾部（i 越大）权重越高：0.55 ~ 1.0
                            let recency = 0.55 + 0.45 * (Double(i + len) / Double(n))
                            // 3+ 字专业术语比 2 字术语区分度更高
                            let specificity = (len >= 3) ? 0.38 : 0.28
                            // 若一个词跨多个领域，平摊部分权重避免多领域同时过曝
                            let bitCount = max(1, mask.nonzeroBitCount)
                            let contribution = (specificity * recency) / sqrt(Double(bitCount))
                            for domain in InputSceneDomain.specializedDomains where (mask & domain.bitMask) != 0 {
                                scores[domain, default: 0] += contribution
                            }
                        }
                        break
                    }
                }
            }
            i += max(1, matchedLen)
        }

        // 若文本中直接出现了经典古诗词/成语（4-7 字），提升文学场景分
        if n >= 4 {
            let litWindow = String(chars.suffix(36))
            let parts = litWindow.split { !Self.isHanzi($0) }.map(String.init)
            for p in parts where p.count >= 4 && p.count <= 14 {
                if tagStore.literaryCategory(for: p, allowTraditionalFallback: allowTraditionalFallback) != nil {
                    scores[.literature, default: 0] += 0.40
                }
            }
        }

        return scores
    }

    private static func isHanzi(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        return (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF)
    }
}
