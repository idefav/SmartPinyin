import Foundation
import SharedIPC

/// 智能标点符号与 Coding 模式决策引擎（纯逻辑、零 I/O、100% 确定性可单测）：
/// - 英文直出模式自动半角英文标点
/// - Coding 模式（手动全局或 IDE / 终端 / T3 Code 自动识别）默认半角英文标点
/// - 中文与中英混输场景自动输出规范中文全角标点，并支持智能成对引号（“” / ‘’）
/// - 数字后小数点/冒号（3.14 / 14:30）与 URL 冒号（http: / https:）自动保持半角
/// - 翻译模式空态下按目标语种输出对应标点（EN/FR/DE/ES/KO 半角，JA 日式标点）
public final class SmartPunctuationEngine {
    public struct Context: Sendable {
        public let mode: InputMode
        public let preferences: SmartPinyinPreferences
        public let appBundleID: String
        public let leftContext: String
        public let isTrailingInlineEnglish: Bool
        public let isInsideChineseTranslationBuffer: Bool

        public init(
            mode: InputMode,
            preferences: SmartPinyinPreferences,
            appBundleID: String,
            leftContext: String,
            isTrailingInlineEnglish: Bool = false,
            isInsideChineseTranslationBuffer: Bool = false
        ) {
            self.mode = mode
            self.preferences = preferences
            self.appBundleID = appBundleID
            self.leftContext = leftContext
            self.isTrailingInlineEnglish = isTrailingInlineEnglish
            self.isInsideChineseTranslationBuffer = isInsideChineseTranslationBuffer
        }
    }

    private var openDoubleQuote = true
    private var openSingleQuote = true

    /// 内置主流开发工具 Bundle ID（自动启用 Coding 模式，默认半角英文标点）
    private static let codingAppBundleIDs: Set<String> = [
        // 终端
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "org.alacritty",
        "co.zeit.hyper",
        // IDE 与代码编辑器
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.panic.Nova",
        "com.github.atom",
        "com.neovide.neovide",
        // AI 编程工具
        "com.t3tools.t3code",
        "com.google.antigravity"
    ]

    private static let codingAppBundlePrefixes: [String] = [
        "com.jetbrains.",
        "com.t3tools."
    ]

    /// 静态自然语言中文标点映射表（编程高频符号 ` ~ @ # $ % ^ & * - _ + = / { } | 永不乱转）
    private static let chineseStaticMap: [String: String] = [
        ",": "，",
        ".": "。",
        "!": "！",
        "?": "？",
        ":": "：",
        ";": "；",
        "(": "（",
        ")": "）",
        "[": "【",
        "]": "】",
        "<": "《",
        ">": "》",
        "\\": "、"
    ]

    /// 翻译模式空态针对日语的标点映射
    private static let japaneseStaticMap: [String: String] = [
        ",": "、",
        ".": "。",
        "!": "！",
        "?": "？",
        ":": "：",
        ";": "；",
        "(": "（",
        ")": "）",
        "[": "「",
        "]": "」"
    ]

    /// 紧跟在临时英文单词后仍保持半角的代码/配对符号（如 React(props)、T3[0]、a=1）
    private static let codePairedPunctuation: Set<String> = [
        "(", ")", "[", "]", "{", "}", "=", ";", "<", ">", "'", "\"", "\\"
    ]

    public init() {}

    /// 失焦、换行或切换客户端时重置成对引号状态
    public func resetQuotePairing() {
        openDoubleQuote = true
        openSingleQuote = true
    }

    /// 判断宿主应用是否属于开发者工具（IDE / 终端 / 代码编辑器 / T3 Code）
    public static func isCodingApp(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        if codingAppBundleIDs.contains(bundleID) {
            return true
        }
        return codingAppBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// 计算当前生效的 Coding 模式状态（手动全局开关 OR 按开发应用自动识别）
    public static func isEffectiveCodingMode(
        preferences: SmartPinyinPreferences,
        appBundleID: String
    ) -> Bool {
        if preferences.codingModeEnabled {
            return true
        }
        if preferences.autoCodingModeForDevApps && isCodingApp(bundleID: appBundleID) {
            return true
        }
        return false
    }

    /// 判断字符是否属于可被中文/智能标点引擎接管的 ASCII 标点
    public static func isMappedPunctuationKey(_ ch: String) -> Bool {
        ch.count == 1 && (chineseStaticMap[ch] != nil || ch == "\"" || ch == "'")
    }

    /// 映射单个 ASCII 标点字符：
    /// - 返回 `nil` 表示保持原样英文半角标点（空态可直接 `.passThrough`）
    /// - 返回非空字符串表示应输出的中文/日文标点
    public func mapPunctuation(_ ch: String, context: Context) -> String? {
        guard Self.isMappedPunctuationKey(ch) else { return nil }

        // 1. 英文直出模式：始终输出英文半角标点
        if case .directEnglish = context.mode {
            return nil
        }

        // 2. 翻译模式拼句缓冲中（正在拼待译中文句）：按中文标点断句，帮助 HY-MT1.5 精准译出目标语标点
        if context.isInsideChineseTranslationBuffer {
            if context.preferences.smartPunctuationEnabled && shouldStayHalfWidthForNumberOrURL(ch, leftContext: context.leftContext) {
                return nil
            }
            return mapChinese(ch)
        }

        // 3. 翻译模式空态（刚上屏外文译文后补标点）：按目标语种输出对应标点
        if case .translateOnCommit(let target) = context.mode {
            if target == .japanese {
                return Self.japaneseStaticMap[ch]
            }
            return nil
        }

        // 4. Coding 模式（手动开启或 Dev App 自动识别）：默认英文半角标点
        if Self.isEffectiveCodingMode(preferences: context.preferences, appBundleID: context.appBundleID) {
            return nil
        }

        // 5. 用户手动关闭了中文全角标点
        guard context.preferences.chinesePunctuation else {
            return nil
        }

        // 6. 临时英文词尾随标点（如 "重启了T3," vs "React("）
        if context.isTrailingInlineEnglish {
            if Self.codePairedPunctuation.contains(ch) {
                return nil
            }
            if context.preferences.smartPunctuationEnabled {
                // 仅当光标前存在中文语境（中英混输）或左文为空（以英文专有名词开头写中文句）时输出中文标点；
                // 若前文是纯英文句子（如 "Hello React,"）则保持英文半角标点
                if !context.leftContext.isEmpty && !Self.containsChinese(context.leftContext) {
                    return nil
                }
            }
            return mapChinese(ch)
        }

        // 7. 智能数字与 URL 识别（如 3.14、14:30、http:）
        if context.preferences.smartPunctuationEnabled
            && shouldStayHalfWidthForNumberOrURL(ch, leftContext: context.leftContext) {
            return nil
        }

        return mapChinese(ch)
    }

    private func mapChinese(_ ch: String) -> String? {
        if ch == "\"" {
            let out = openDoubleQuote ? "“" : "”"
            openDoubleQuote.toggle()
            return out
        }
        if ch == "'" {
            let out = openSingleQuote ? "‘" : "’"
            openSingleQuote.toggle()
            return out
        }
        return Self.chineseStaticMap[ch]
    }

    private func shouldStayHalfWidthForNumberOrURL(_ ch: String, leftContext: String) -> Bool {
        guard let last = leftContext.last else { return false }
        // 数字后紧跟小数点或时间冒号保持半角（3.14、v1.2、14:30）
        if (ch == "." || ch == ":"), last.isASCII && last.isNumber {
            return true
        }
        // URL scheme 冒号保持半角（http: / https: / file: / ssh: / ws:）
        if ch == ":" {
            let lowerTail = leftContext.suffix(8).lowercased()
            let schemes = ["http", "https", "file", "ssh", "ftp", "ws", "wss", "localhost"]
            if schemes.contains(where: { lowerTail.hasSuffix($0) }) {
                return true
            }
        }
        return false
    }

    private static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }
}
