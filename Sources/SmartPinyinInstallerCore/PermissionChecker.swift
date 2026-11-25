import AppKit
import ApplicationServices
import Foundation

/// macOS 15 / 26 系统设置深链与辅助功能权限检测
public enum SystemSettingsPane: Sendable {
    case keyboardInputSources
    case accessibility
    case privacySecurity

    /// 主深链（macOS 15+ Sequoia / Tahoe）与旧版回落深链
    public var candidateURLs: [URL] {
        let strings: [String]
        switch self {
        case .keyboardInputSources:
            strings = [
                "x-apple.systempreferences:com.apple.Keyboard?InputSources",
                "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
                "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts"
            ]
        case .accessibility:
            strings = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ]
        case .privacySecurity:
            strings = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity",
                "x-apple.systempreferences:com.apple.preference.security"
            ]
        }
        return strings.compactMap(URL.init(string:))
    }
}

public enum PermissionChecker {
    /// 检测当前进程自身是否拥有辅助功能权限（显式传递 prompt=false 促使系统重新查询）
    public static func isCurrentProcessAccessibilityTrusted() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: kCFBooleanFalse!] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 兼容旧名：检测指定已安装的 SmartPinyin.app（或当前进程）的真实实时辅助功能状态。
    /// 通过调用 SmartPinyin.app 主二进制的 --check-accessibility 极速子进程，彻底绕过进程内 TCC 缓存，
    /// 确保用户在系统设置中勾选 SmartPinyin 后可立即实时刷新。
    public static func isAccessibilityTrusted(installedAppURL: URL? = nil) -> Bool {
        if let appURL = installedAppURL {
            let exeURL = appURL.appendingPathComponent("Contents/MacOS/SmartPinyin")
            if FileManager.default.isExecutableFile(atPath: exeURL.path) {
                if runQuickProbe(executableURL: exeURL, arguments: ["--check-accessibility"]) == 0 {
                    return true
                }
            }
        }
        return isCurrentProcessAccessibilityTrusted()
    }

    /// 触发系统原生的辅助功能授权提示弹窗，优先将真正的 SmartPinyin.app 本体注册到辅助功能列表，并打开系统设置定位到“辅助功能”
    @discardableResult
    public static func requestAccessibilityPermission(installedAppURL: URL? = nil) -> Bool {
        if let appURL = installedAppURL {
            let exeURL = appURL.appendingPathComponent("Contents/MacOS/SmartPinyin")
            if FileManager.default.isExecutableFile(atPath: exeURL.path) {
                _ = runQuickProbe(executableURL: exeURL, arguments: ["--request-accessibility"])
                let trusted = isAccessibilityTrusted(installedAppURL: appURL)
                if !trusted {
                    openSystemSettings(.accessibility)
                }
                return trusted
            }
        }

        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: kCFBooleanTrue!] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            openSystemSettings(.accessibility)
        }
        return trusted
    }

    /// 跳转到指定的 macOS 系统设置面板
    @discardableResult
    public static func openSystemSettings(_ pane: SystemSettingsPane) -> Bool {
        for url in pane.candidateURLs {
            if NSWorkspace.shared.open(url) {
                return true
            }
        }
        return false
    }

    private static func runQuickProbe(executableURL: URL, arguments: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = arguments
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }
}
