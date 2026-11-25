import ApplicationServices
import Carbon
import Foundation
import InputMethodKit
import SmartPinyinCore

/// 焦点文本框三层只读采集器（安全隐私优先、主线程零阻塞）：
/// 1. 优先通过 IMKTextInput 读取光标前后窗口（同步、低开销，兼容原生 Cocoa/TextKit 应用）
/// 2. 其次在后台串行队列调用 macOS Accessibility API 读取 kAXFocusedUIElementAttribute 的 ±4000 字窗口（兼容浏览器/Electron/VS Code/编辑器）
/// 3. 兜底回退到本会话滚动输入缓存（ContextTracker）
/// 严格安全防线：一旦检测到 IsSecureEventInputEnabled() 或 AXSecureTextField，彻底阻断并清空索引。
public final class DocumentContextReader: @unchecked Sendable {
    public struct DocumentSnapshot: Sendable {
        public let fullWindowText: String
        public let cursorOffset: Int
        public let leftTail: String
        public let capturedAt: TimeInterval

        public init(
            fullWindowText: String,
            cursorOffset: Int,
            leftTail: String,
            capturedAt: TimeInterval = Date().timeIntervalSince1970
        ) {
            self.fullWindowText = fullWindowText
            self.cursorOffset = cursorOffset
            self.leftTail = leftTail
            self.capturedAt = capturedAt
        }
    }

    private let queue = DispatchQueue(label: "com.smartpinyin.doccontext.reader", qos: .utility)
    private let lock = NSLock()
    private var lastAppBundleID: String = ""
    private var lastAXReadTS: TimeInterval = 0
    private var cachedAXLeftTail: String = ""
    private var cachedAXCapturedAt: TimeInterval = 0
    private var hasValidAXCache: Bool = false
    private var pendingPostEditSync: DispatchWorkItem?

    public init() {}

    /// 立即作废过期 AX 左文缓存（在上屏、退格、删词、剪切、粘贴、点击切换焦点时调用，防止旧快照复活或倒流）
    public func invalidateCachedLeftTail() {
        lock.lock()
        cachedAXLeftTail = ""
        cachedAXCapturedAt = 0
        hasValidAXCache = false
        lastAXReadTS = 0
        lock.unlock()
    }

    /// 读取最近一次由 AX 采集到的光标左侧短尾（用于 Electron 等 IMK attributedSubstring 返回 nil 的兜底上文）
    public func cachedLeftTail(forApp bundleID: String, isSecureInput: Bool) -> String {
        cachedLeftTailWithTimestamp(forApp: bundleID, isSecureInput: isSecureInput)?.text ?? ""
    }

    /// 读取最近一次由 AX 采集到的光标左侧短尾及其采集前时间戳（供 ContextTracker 做因果护栏校验）
    public func cachedLeftTailWithTimestamp(
        forApp bundleID: String,
        isSecureInput: Bool
    ) -> (text: String, capturedAt: TimeInterval)? {
        guard !isSecureInput else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard hasValidAXCache, bundleID == lastAppBundleID else { return nil }
        return (cachedAXLeftTail, cachedAXCapturedAt)
    }

    /// 在退格/删词/剪切/粘贴/鼠标点击后延迟 ~75ms 异步拍摄一份新鲜 AX 快照，精准对齐真实文本框状态（含清空为空串）
    public func schedulePostEditAXSync(
        delayMs: Int = 75,
        appBundleID: String,
        isSecureInput: Bool,
        index: DocumentContextIndex
    ) {
        guard !isSecureInput else {
            invalidateCachedLeftTail()
            index.clear()
            return
        }
        lock.lock()
        pendingPostEditSync?.cancel()
        lastAppBundleID = appBundleID
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !IsSecureEventInputEnabled() else {
                self.invalidateCachedLeftTail()
                index.clear()
                return
            }
            if let axSnap = Self.readFocusedAXElementWindow() {
                self.lock.lock()
                if self.lastAppBundleID == appBundleID {
                    self.cachedAXLeftTail = axSnap.leftTail
                    self.cachedAXCapturedAt = axSnap.capturedAt
                    self.hasValidAXCache = true
                    self.lastAXReadTS = axSnap.capturedAt
                }
                self.lock.unlock()
                if axSnap.fullWindowText.count >= 2 {
                    index.updateDocument(text: axSnap.fullWindowText, cursorOffset: axSnap.cursorOffset)
                } else if axSnap.fullWindowText.isEmpty {
                    index.clear()
                }
            }
        }
        pendingPostEditSync = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + .milliseconds(max(20, delayMs)), execute: work)
    }

    /// 同步从 IMKTextInput 尝试截取光标前后内容（主线程安全，耗散 < 0.2ms）
    public func readIMKWindow(client: IMKTextInput, isSecureInput: Bool) -> DocumentSnapshot? {
        guard !isSecureInput else { return nil }
        let selected = client.selectedRange()
        guard selected.location != NSNotFound else { return nil }

        let beforeLen = min(selected.location, 1200)
        var beforeText = ""
        if beforeLen > 0 {
            let beforeRange = NSRange(location: selected.location - beforeLen, length: beforeLen)
            beforeText = client.attributedSubstring(from: beforeRange)?.string ?? ""
        }

        let afterStart = selected.location + max(0, selected.length)
        let afterRange = NSRange(location: afterStart, length: 600)
        let afterText = client.attributedSubstring(from: afterRange)?.string ?? ""

        let combined = beforeText + afterText
        guard combined.count >= 2 else { return nil }
        let leftTail = String(beforeText.suffix(256))
        return DocumentSnapshot(
            fullWindowText: combined,
            cursorOffset: beforeText.count,
            leftTail: leftTail
        )
    }

    /// 异步刷新指定 DocumentContextIndex（绝不阻塞主线程按键响应）
    public func refreshAsync(
        index: DocumentContextIndex,
        appBundleID: String,
        isSecureInput: Bool,
        imkSnapshot: DocumentSnapshot?,
        fallbackSessionText: String,
        forceAX: Bool = false
    ) {
        if isSecureInput {
            lock.lock()
            cachedAXLeftTail = ""
            cachedAXCapturedAt = 0
            hasValidAXCache = false
            lock.unlock()
            index.clear()
            return
        }

        let now = Date().timeIntervalSince1970
        lock.lock()
        let appChanged = (appBundleID != lastAppBundleID)
        if appChanged {
            lastAppBundleID = appBundleID
            cachedAXLeftTail = ""
            cachedAXCapturedAt = 0
            hasValidAXCache = false
            lastAXReadTS = 0
        }
        let shouldPollAX = forceAX || appChanged || (now - lastAXReadTS >= 1.2)
        if shouldPollAX {
            lastAXReadTS = now
        }
        lock.unlock()

        if appChanged {
            index.clear()
        }

        queue.async { [weak self] in
            guard let self else { return }
            guard !IsSecureEventInputEnabled() else {
                index.clear()
                return
            }

            // 1. 优先尝试 AX 读取完整文本框（±4000 字，记录开始读取前的时间戳 capturedAt 供因果护栏校验）
            if shouldPollAX, let axSnap = Self.readFocusedAXElementWindow() {
                self.lock.lock()
                if self.lastAppBundleID == appBundleID {
                    self.cachedAXLeftTail = axSnap.leftTail
                    self.cachedAXCapturedAt = axSnap.capturedAt
                    self.hasValidAXCache = true
                }
                self.lock.unlock()
                if axSnap.fullWindowText.count >= 2 {
                    index.updateDocument(text: axSnap.fullWindowText, cursorOffset: axSnap.cursorOffset)
                } else if axSnap.fullWindowText.isEmpty {
                    index.clear()
                }
                return
            }

            // 2. 次选 IMK 读取窗口
            if let imkSnapshot, imkSnapshot.fullWindowText.count >= 2 {
                index.updateDocument(text: imkSnapshot.fullWindowText, cursorOffset: imkSnapshot.cursorOffset)
                return
            }

            // 3. 兜底使用本会话滚动输入缓存
            if fallbackSessionText.count >= 2 {
                index.updateDocument(text: fallbackSessionText, cursorOffset: fallbackSessionText.count)
            }
        }
    }

    /// 通过 macOS Accessibility API 只读获取当前焦点文本框的光标周围 ±4000 字符（含空文本框感知与采集时间戳）
    private static func readFocusedAXElementWindow() -> DocumentSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        guard !IsSecureEventInputEnabled() else { return nil }

        // 在发起 AX IPC 之前记录采集时间戳，确保因果护栏宁严勿松（绝不把旧读取当成新快照）
        let captureStartTS = Date().timeIntervalSince1970

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard err == .success, let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement

        // 严格过滤密码框（AXSecureTextField）
        if isSecureAXElement(element) {
            return nil
        }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success,
              let fullText = valueRef as? String
        else {
            return nil
        }

        if fullText.isEmpty {
            return DocumentSnapshot(
                fullWindowText: "",
                cursorOffset: 0,
                leftTail: "",
                capturedAt: captureStartTS
            )
        }

        // 获取光标在文本中的偏移，仅切片光标前后 ±4000 字避免超大文档开销
        let nsText = fullText as NSString
        let totalUTF16 = nsText.length
        var cursorUTF16 = totalUTF16

        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
           let rangeRef,
           CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            var cfRange = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange),
               cfRange.location >= 0,
               cfRange.location <= totalUTF16 {
                cursorUTF16 = cfRange.location
            }
        }

        let startUTF16 = max(0, cursorUTF16 - 4000)
        let endUTF16 = min(totalUTF16, cursorUTF16 + 4000)
        let windowRange = NSRange(location: startUTF16, length: max(0, endUTF16 - startUTF16))
        let windowText = nsText.substring(with: windowRange)

        let beforeRange = NSRange(location: startUTF16, length: max(0, cursorUTF16 - startUTF16))
        let beforeText = nsText.substring(with: beforeRange)
        let leftTail = String(beforeText.suffix(256))

        return DocumentSnapshot(
            fullWindowText: windowText,
            cursorOffset: beforeText.count,
            leftTail: leftTail,
            capturedAt: captureStartTS
        )
    }

    private static func isSecureAXElement(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String,
           role.localizedCaseInsensitiveContains("Secure") {
            return true
        }
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String,
           subrole.localizedCaseInsensitiveContains("Secure") {
            return true
        }
        return false
    }
}
