import Foundation

/// 本地隐私与敏感文本硬过滤器（零联网、零副作用）：
/// 在任何文本写入短期工作记忆或长期个人记忆库之前进行拦截，严防密钥、验证码、银行卡/手机号与邮箱落入记忆。
public enum SensitiveTextFilter {
    private static let secretPrefixes = [
        "sk-", "pk_", "rk_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
        "glpat-", "xoxb-", "xoxp-", "aiza", "akia", "asia", "bearer "
    ]

    private static let digitRunRegex = try? NSRegularExpression(pattern: #"\d{6,}"#)
    private static let emailRegex = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
    private static let secretQueryRegex = try? NSRegularExpression(
        pattern: #"(?i)(token|password|passwd|secret|api[_-]?key|auth|signature|access_key)\s*[=:]\s*\S+"#
    )
    private static let highEntropyHexOrB64Regex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])[A-Fa-f0-9]{24,}(?![A-Za-z0-9])|(?<![A-Za-z0-9/+_-])[A-Za-z0-9+/_-]{32,}={0,2}(?![A-Za-z0-9/+_-])"#
    )

    /// 检查文本是否包含疑似敏感信息（密钥、长数字串、邮箱、鉴权参数、高熵随机令牌）
    public static func containsSensitiveData(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()
        for prefix in secretPrefixes where lower.contains(prefix) {
            return true
        }

        let ns = trimmed as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        if let r = digitRunRegex, r.firstMatch(in: trimmed, range: fullRange) != nil {
            return true
        }
        if let r = emailRegex, r.firstMatch(in: trimmed, range: fullRange) != nil {
            return true
        }
        if let r = secretQueryRegex, r.firstMatch(in: trimmed, range: fullRange) != nil {
            return true
        }
        if let r = highEntropyHexOrB64Regex, let m = r.firstMatch(in: trimmed, range: fullRange) {
            let token = ns.substring(with: m.range)
            // 仅过滤混合大小写+数字或纯长十六进制的高熵令牌，不误伤普通长驼峰英文类名（如 SmartPinyinInputController）
            let hasDigit = token.contains(where: { $0.isNumber })
            let isHex = token.allSatisfy { $0.isHexDigit }
            if hasDigit || isHex {
                return true
            }
        }
        return false
    }

    /// 过滤单个待记忆词条（中文短语或代码标识符）
    public static func isSafeMemoryToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 48 else { return false }
        return !containsSensitiveData(trimmed)
    }
}
