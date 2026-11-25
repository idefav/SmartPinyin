import ApplicationServices
import Carbon
import Foundation
import SharedIPC

/// 封装 macOS Carbon TIS (Text Input Source) API，管理输入法的注册、启用、选中与彻底禁用。
public struct InputSourceStatus: Equatable, Sendable {
    public let isRegistered: Bool
    public let isEnabled: Bool
    public let isSelected: Bool
    public let matchedSourceIDs: [String]

    public init(
        isRegistered: Bool,
        isEnabled: Bool,
        isSelected: Bool,
        matchedSourceIDs: [String]
    ) {
        self.isRegistered = isRegistered
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.matchedSourceIDs = matchedSourceIDs
    }
}

public enum InputSourceManager {
    public static let bundleID = SmartPinyinIdentifiers.appBundleID
    public static let pinyinModeID = "\(SmartPinyinIdentifiers.appBundleID).pinyin"

    /// 向系统 Text Services Manager 注册指定路径的输入法 .app 包（Carbon TIS 必须在主线程调用）
    @discardableResult
    public static func register(bundleURL: URL) -> OSStatus {
        runOnMain {
            TISRegisterInputSource(bundleURL as CFURL)
        }
    }

    /// 枚举匹配本输入法 Bundle ID 的所有输入源（含父级 Bundle 与子级 Mode）
    /// 关键：includeAllInstalled 必须为 true 才能查到刚注册尚未启用的输入源
    public static func matchingSources(includeAllInstalled: Bool = true) -> [TISInputSource] {
        runOnMain {
            matchingSourcesOnMain(includeAllInstalled: includeAllInstalled)
        }
    }

    /// 查询当前注册/启用/选中状态
    public static func currentStatus() -> InputSourceStatus {
        runOnMain {
            currentStatusOnMain()
        }
    }

    /// 异步注册并自动启用输入源（不阻塞主线程，并在首次 TSM 刷新延迟时自动短间隔重试一次）
    @discardableResult
    public static func registerAndEnableAsync(bundleURL: URL) async -> InputSourceStatus {
        _ = await MainActor.run {
            TISRegisterInputSource(bundleURL as CFURL)
        }
        try? await Task.sleep(for: .milliseconds(250))
        var status = await MainActor.run {
            enableAndSelectOnMain()
        }
        if !status.isEnabled {
            try? await Task.sleep(for: .milliseconds(350))
            status = await MainActor.run {
                _ = TISRegisterInputSource(bundleURL as CFURL)
                return enableAndSelectOnMain()
            }
        }
        return status
    }

    /// 注册并尝试自动启用、选中 SmartPinyin 输入源（后台线程调用时自带一次 TSM 延迟重试）
    @discardableResult
    public static func registerAndEnable(bundleURL: URL) -> InputSourceStatus {
        _ = register(bundleURL: bundleURL)
        // 仅在非主线程时短暂等待 TSM 刷新注册表，避免阻塞 UI 线程
        if !Thread.isMainThread {
            Thread.sleep(forTimeInterval: 0.25)
        }

        var status = runOnMain {
            enableAndSelectOnMain()
        }
        if !status.isEnabled && !Thread.isMainThread {
            Thread.sleep(forTimeInterval: 0.35)
            status = runOnMain {
                _ = TISRegisterInputSource(bundleURL as CFURL)
                return enableAndSelectOnMain()
            }
        }
        return status
    }

    private static func enableAndSelectOnMain() -> InputSourceStatus {
        let sources = matchingSourcesOnMain(includeAllInstalled: true)
        // 先启用父级输入法，再启用子级拼音模式
        let ordered = sources.sorted { lhs, rhs in
            let lID = stringProperty(lhs, key: kTISPropertyInputSourceID) ?? ""
            let rID = stringProperty(rhs, key: kTISPropertyInputSourceID) ?? ""
            return lID.count < rID.count
        }
        for src in ordered {
            _ = TISEnableInputSource(src)
        }
        // 尝试切到拼音模式
        if let pinyinSource = ordered.first(where: {
            stringProperty($0, key: kTISPropertyInputSourceID) == pinyinModeID
        }) ?? ordered.last {
            _ = TISSelectInputSource(pinyinSource)
        }
        invalidateUIOrderCache()
        return currentStatusOnMain()
    }

    /// 清除系统菜单栏输入源 UI 顺序缓存（AppleInputSourcesInUIOrderPasteboard），
    /// 避免覆盖升级或“卸载后重装”时 TextInputMenuAgent 读到旧列表而漏掉 SmartPinyin。
    public static func invalidateUIOrderCache() {
        var pb: Pasteboard?
        if PasteboardCreate("AppleInputSourcesInUIOrderPasteboard" as CFString, &pb) == noErr,
           let pb {
            _ = PasteboardClear(pb)
        }
    }

    /// 清除 UI 顺序缓存并温和刷新菜单栏输入法代理进程，使新增/变更的输入源立即可见（避免 SIGKILL 强杀其他系统 UI 进程）
    public static func refreshSystemInputMenu() {
        invalidateUIOrderCache()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-x", "TextInputMenuAgent"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    /// 卸载前安全停用：先将当前活跃输入法切回系统英文 ABC/US，再禁用全部 SmartPinyin 输入源
    public static func disableAllAndSwitchToSafeKeyboard() {
        runOnMain {
            switchToSafeASCIIKeyboard()
            let sources = matchingSourcesOnMain(includeAllInstalled: true)
            // 逆序禁用（先子模式后父级）
            let ordered = sources.sorted { lhs, rhs in
                let lID = stringProperty(lhs, key: kTISPropertyInputSourceID) ?? ""
                let rID = stringProperty(rhs, key: kTISPropertyInputSourceID) ?? ""
                return lID.count > rID.count
            }
            for src in ordered {
                _ = TISDisableInputSource(src)
            }
            invalidateUIOrderCache()
        }
    }

    private static func runOnMain<T>(_ block: () -> T) -> T {
        if Thread.isMainThread {
            return block()
        }
        return DispatchQueue.main.sync(execute: block)
    }

    private static func matchingSourcesOnMain(includeAllInstalled: Bool) -> [TISInputSource] {
        guard let rawList = TISCreateInputSourceList(nil, includeAllInstalled)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return rawList.filter { source in
            let bid = stringProperty(source, key: kTISPropertyBundleID) ?? ""
            let sid = stringProperty(source, key: kTISPropertyInputSourceID) ?? ""
            return bid == bundleID || sid == bundleID || sid.hasPrefix("\(bundleID).")
        }
    }

    private static func currentStatusOnMain() -> InputSourceStatus {
        let sources = matchingSourcesOnMain(includeAllInstalled: true)
        guard !sources.isEmpty else {
            return InputSourceStatus(isRegistered: false, isEnabled: false, isSelected: false, matchedSourceIDs: [])
        }
        var anyEnabled = false
        var anySelected = false
        var ids: [String] = []

        for src in sources {
            if let sid = stringProperty(src, key: kTISPropertyInputSourceID) {
                ids.append(sid)
            }
            if boolProperty(src, key: kTISPropertyInputSourceIsEnabled) {
                anyEnabled = true
            }
            if boolProperty(src, key: kTISPropertyInputSourceIsSelected) {
                anySelected = true
            }
        }
        return InputSourceStatus(
            isRegistered: true,
            isEnabled: anyEnabled,
            isSelected: anySelected,
            matchedSourceIDs: ids
        )
    }

    /// 切换到系统自带的 ABC / U.S. 英文键盘布局，避免卸载时当前焦点输入法失效
    private static func switchToSafeASCIIKeyboard() {
        let preferredIDs = [
            "com.apple.keylayout.ABC",
            "com.apple.keylayout.US",
            "com.apple.keylayout.USInternational-PC"
        ]
        if let enabled = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] {
            for targetID in preferredIDs {
                if let match = enabled.first(where: { stringProperty($0, key: kTISPropertyInputSourceID) == targetID }) {
                    _ = TISSelectInputSource(match)
                    return
                }
            }
            if let fallback = enabled.first(where: {
                let sid = stringProperty($0, key: kTISPropertyInputSourceID) ?? ""
                let selectable = boolProperty($0, key: kTISPropertyInputSourceIsSelectCapable)
                return selectable && !sid.hasPrefix(bundleID)
            }) {
                _ = TISSelectInputSource(fallback)
                return
            }
        }
        if let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() {
            _ = TISSelectInputSource(ascii)
        }
    }

    private static func stringProperty(_ source: TISInputSource, key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func boolProperty(_ source: TISInputSource, key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }
}
