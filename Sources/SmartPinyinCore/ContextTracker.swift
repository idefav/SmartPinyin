import Foundation

/// 来自宿主 IMKTextInput 或 macOS Accessibility API 的光标左文快照（带因果采集时间戳，杜绝旧快照倒流覆写新鲜输入）
public struct ExternalLeftContextSnapshot: Equatable, Sendable {
    public let text: String
    public let capturedAt: TimeInterval
    public let isSynchronousIMK: Bool

    public init(text: String, capturedAt: TimeInterval, isSynchronousIMK: Bool) {
        self.text = text
        self.capturedAt = capturedAt
        self.isSynchronousIMK = isSynchronousIMK
    }
}

/// 三层防倒流上下文追踪器（解决 Chrome / Electron / T3 Code / VS Code 中 IMK 异步滞后与 AX 节流缓存倒流覆写问题）：
/// 1. 进程内精确滚动提交缓冲（0ms、100% 顺序记录前面输入的每个词与退格删除）
/// 2. 因果时间戳护栏（Causal Timestamp Fence）：绝不允许采集早于最近一次上屏/退格时刻的旧 AX/IMK 快照把新鲜左文覆写倒退
/// 3. 提交后后缀强不变量（Post-Commit Suffix Invariant）：刚提交词后若外部尚未刷新出该后缀，直接信任已追加该词的滚动缓冲
/// 4. 安全输入（密码框）硬阻断：开启 Secure Input 时不读写、不缓存任何文本
public final class ContextTracker {
    private let maxLength: Int
    private let clock: () -> TimeInterval
    private var rollingBuffer: String = ""
    private var activeClientID: String = ""
    /// 最近一次进程内明确写/删操作的时间戳，用于阻断更早采集的旧 AX 快照倒流
    public private(set) var lastMutationTS: TimeInterval = 0
    /// 发生了删词/删行/剪切/粘贴/光标移动/切换输入框等未知幅度变更，等待下一次新鲜权威快照重对齐
    public private(set) var needsAuthoritativeResync: Bool = false
    /// 用户刚按下 Cmd+A 全选，下一次退格或输入将替换整段缓冲
    private var pendingSelectAll: Bool = false

    public init(
        maxLength: Int = 2000,
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.maxLength = maxLength
        self.clock = clock
    }

    /// 切换焦点应用或窗口时清空旧滚动缓存，并标记需要权威同步
    public func switchClient(identifier: String) {
        if identifier != activeClientID {
            activeClientID = identifier
            rollingBuffer = ""
            pendingSelectAll = false
            needsAuthoritativeResync = true
            lastMutationTS = clock()
        }
    }

    /// 记录刚刚上屏的文本（密码框模式下禁止调用）
    public func recordCommitted(_ text: String, isSecureInput: Bool) {
        guard !isSecureInput, !text.isEmpty else { return }
        if pendingSelectAll {
            rollingBuffer = ""
            pendingSelectAll = false
        }
        rollingBuffer.append(text)
        if rollingBuffer.count > maxLength {
            rollingBuffer = String(rollingBuffer.suffix(maxLength))
        }
        lastMutationTS = clock()
        needsAuthoritativeResync = false
    }

    /// 标记用户刚按了 Cmd+A 全选
    public func markSelectAll() {
        pendingSelectAll = true
    }

    /// 当前是否处于全选待替换态
    public var hasPendingSelectAll: Bool {
        pendingSelectAll
    }

    /// 退格删除同步：
    /// - 普通单字退格：精确移除缓冲尾字并刷新 lastMutationTS（防止旧 AX 复活已删字）
    /// - 全选退格 / Option+Backspace 删词 / Cmd+Backspace 删行：清空或标记重对齐，等待新鲜权威快照同步剩余文本
    public func handleBackspace(isWordOrLineDelete: Bool = false) {
        let now = clock()
        if pendingSelectAll {
            rollingBuffer = ""
            pendingSelectAll = false
            needsAuthoritativeResync = true
            lastMutationTS = now
            return
        }
        if isWordOrLineDelete {
            rollingBuffer = ""
            needsAuthoritativeResync = true
            lastMutationTS = now
            return
        }
        if !rollingBuffer.isEmpty {
            rollingBuffer.removeLast()
        }
        lastMutationTS = now
    }

    /// 标记外部发生了剪切/粘贴/撤销/方向键移动光标/鼠标点击，等待新鲜权威快照校准真实光标左文
    public func markExternalEditOccurred(clearBuffer: Bool = false) {
        pendingSelectAll = false
        if clearBuffer {
            rollingBuffer = ""
        }
        needsAuthoritativeResync = true
        lastMutationTS = clock()
    }

    public func clear() {
        rollingBuffer = ""
        pendingSelectAll = false
        needsAuthoritativeResync = false
        lastMutationTS = clock()
    }

    /// 返回当前会话滚动缓存文本（用于无 AX/IMK 读取权限时的文本框词汇索引与删除前归档）
    public func sessionText(isSecureInput: Bool) -> String {
        guard !isSecureInput else { return "" }
        return rollingBuffer
    }

    /// 兼容旧签名：从外部文本闭包解析左文（假定外部返回的是实时同步 IMK 文本）
    public func resolveLeftContext(
        isSecureInput: Bool,
        maxWindow: Int = 128,
        queryClientLeftText: (() -> String?)? = nil
    ) -> String {
        resolveAuthoritativeLeftContext(
            isSecureInput: isSecureInput,
            maxWindow: maxWindow,
            requiredSuffix: nil
        ) {
            guard let text = queryClientLeftText?(), !text.isEmpty else { return nil }
            return ExternalLeftContextSnapshot(
                text: text,
                capturedAt: self.clock(),
                isSynchronousIMK: true
            )
        }
    }

    /// 权威左文解析（带因果时间戳护栏 + 提交后后缀强不变量）：
    /// - 绝不用早于 lastMutationTS 的过期 AX 快照覆写 rollingBuffer
    /// - 刚提交词（requiredSuffix 非空）时，若 Electron/Chrome 渲染进程尚未刷新出该词，坚决忽略旧值并信任 rollingBuffer
    /// - 发生删词/删行/全选/粘贴/鼠标点击后（needsAuthoritativeResync == true），采纳新鲜快照（含空串）精准对齐真实光标左文
    public func resolveAuthoritativeLeftContext(
        isSecureInput: Bool,
        maxWindow: Int = 128,
        requiredSuffix: String? = nil,
        queryExternalSnapshot: (() -> ExternalLeftContextSnapshot?)? = nil
    ) -> String {
        guard !isSecureInput else { return "" }

        let now = clock()
        if let ext = queryExternalSnapshot?() {
            let trimmed = String(ext.text.suffix(maxLength))

            // 护栏 1（因果时间戳）：非同步 AX 快照若采集早于最近一次上屏/退格，属于过期旧照片，直接丢弃！
            let passesCausalFence = ext.isSynchronousIMK || (ext.capturedAt >= lastMutationTS)

            // 护栏 2（提交后后缀强不变量）：刚 insertText(suffix) 后，外部若还没刷新出该后缀，直接忽略！
            let passesSuffixInvariant: Bool = {
                guard let suffix = requiredSuffix, !suffix.isEmpty else { return true }
                return trimmed.hasSuffix(suffix)
            }()

            if passesCausalFence && passesSuffixInvariant {
                if needsAuthoritativeResync {
                    // 编辑/删词/切换光标后首次拿到新鲜权威快照（包括空文本框 ""），精准对齐
                    rollingBuffer = trimmed
                    needsAuthoritativeResync = false
                    return String(rollingBuffer.suffix(maxWindow))
                }

                if !trimmed.isEmpty {
                    // 护栏 3（防 Electron 刚提交 0.5 秒内异步回显旧前缀把新词回退掉）：
                    // 若 rollingBuffer = "上海植物园" 而外部回显滞后的前缀 "上海"，坚决不倒流！
                    let isLaggingShorterPrefix = !rollingBuffer.isEmpty
                        && trimmed.count < rollingBuffer.count
                        && rollingBuffer.hasPrefix(trimmed)
                        && (now - lastMutationTS) < 0.50

                    if !isLaggingShorterPrefix {
                        if rollingBuffer.isEmpty || trimmed.hasSuffix(rollingBuffer) {
                            // 外部快照包含更多前文（如原本框里已有的文字 + 刚打的词），无损补全！
                            rollingBuffer = trimmed
                            return String(rollingBuffer.suffix(maxWindow))
                        }
                        if ext.isSynchronousIMK && requiredSuffix == nil && (now - lastMutationTS) >= 0.50 {
                            // 原生 Cocoa/TextKit 同步客户端在非刚提交期发生外部光标/内容变更时跟随同步
                            rollingBuffer = trimmed
                            return String(rollingBuffer.suffix(maxWindow))
                        }
                    }
                }
            }
        }

        // 兜底：返回 100% 同步记录的 rollingBuffer，确保包含所有前面输入的词与刚提交的词
        return String(rollingBuffer.suffix(maxWindow))
    }
}
