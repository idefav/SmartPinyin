import Foundation
import SharedIPC

/// 分段翻译上屏的智能边界空格助手：
/// 解决英语/法语/德语/西语/韩语连续分段翻译时出现 `Hello!Today` 粘连的问题。
public enum TranslationSpacingHelper {
    private static let leadingPunctuation: Set<Character> = [
        ",", ".", "!", "?", ";", ":", ")", "]", "}", "’", "'", "\"", "”",
        "，", "。", "！", "？", "；", "：", "、", "）", "】"
    ]

    private static let trailingNoSpaceChars: Set<Character> = [
        "(", "[", "{", "\"", "“", "‘", "/", "-", "—"
    ]

    public static func formatForCommit(
        translatedText: String,
        leftContext: String,
        target: TargetLanguage,
        autoSpaceEnabled: Bool
    ) -> String {
        guard autoSpaceEnabled,
              target.usesWordSpacing,
              !translatedText.isEmpty,
              let firstChar = translatedText.first,
              let lastLeft = leftContext.last
        else {
            return translatedText
        }

        // 左侧已是空白/换行，或左括号/引号开头，无需再补空格
        if lastLeft.isWhitespace || lastLeft.isNewline || trailingNoSpaceChars.contains(lastLeft) {
            return translatedText
        }

        // 新译文以空白或附着型标点开头，无需补空格
        if firstChar.isWhitespace || leadingPunctuation.contains(firstChar) {
            return translatedText
        }

        // 左侧紧邻拉丁/韩文/数字或英文结束标点（如 "Hello!" / "Today" / "yes,"）时自动前补 1 个空格
        if isWordOrSentenceBoundary(lastLeft) {
            return " " + translatedText
        }

        return translatedText
    }

    private static func isWordOrSentenceBoundary(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        // ASCII 字母或数字
        if (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) {
            return true
        }
        // 拉丁扩展字母（法/德/西语重音字母）
        if (0x00C0...0x024F).contains(v) {
            return true
        }
        // 韩文音节
        if (0xAC00...0xD7AF).contains(v) {
            return true
        }
        // 英文/拉丁常见闭合标点
        let closingPunct: Set<Character> = ["!", "?", ".", ",", ";", ":", ")", "]", "}", "\"", "'", "”", "’"]
        return closingPunct.contains(ch)
    }
}
