import Foundation
import SmartPinyinCore
import XCTest

final class ContextTrackerSyncTests: XCTestCase {
    /// 精准复现截图 Bug：
    /// 先提交「上海」（AX 缓存拍到 "上海"），再提交「植物园」，
    /// 无论是 1.2 秒前的旧 AX 缓存还是尚未刷新的 Electron IMK 返回 "上海"，
    /// 绝不允许把新鲜的「上海植物园」覆写倒退成「上海」！
    func testCommitPreventsStaleAXAndLaggingIMKFromRollingBackFreshText() {
        var now: TimeInterval = 1_700_000_000
        let tracker = ContextTracker(maxLength: 2000, clock: { now })

        // 1. 先打「上海」上屏，AX 在 t=100.0 拍到 "上海"
        tracker.recordCommitted("上海", isSecureInput: false)
        let staleAXSnapshot = ExternalLeftContextSnapshot(
            text: "上海",
            capturedAt: now,
            isSynchronousIMK: false
        )

        // 2. 0.5 秒后打「植物园」上屏，滚动缓冲立刻更新为「上海植物园」
        now += 0.5
        tracker.recordCommitted("植物园", isSecureInput: false)

        // 2A. 若外部返回旧 AX 快照（capturedAt < lastMutationTS），必须被因果护栏拦截
        let resolvedAfterStaleAX = tracker.resolveAuthoritativeLeftContext(
            isSecureInput: false,
            maxWindow: 128,
            requiredSuffix: "植物园",
            queryExternalSnapshot: { staleAXSnapshot }
        )
        XCTAssertEqual(resolvedAfterStaleAX, "上海植物园")
        XCTAssertEqual(tracker.sessionText(isSecureInput: false), "上海植物园")

        // 2B. 即便同步 IMK 因 Electron 跨进程滞后仍返回提交前的 "上海"，也必须被后缀强不变量拦截
        let laggingIMK = ExternalLeftContextSnapshot(
            text: "上海",
            capturedAt: now,
            isSynchronousIMK: true
        )
        let resolvedAfterLagIMK = tracker.resolveAuthoritativeLeftContext(
            isSecureInput: false,
            maxWindow: 128,
            requiredSuffix: "植物园",
            queryExternalSnapshot: { laggingIMK }
        )
        XCTAssertEqual(resolvedAfterLagIMK, "上海植物园")

        // 2C. 紧接着下一按键（0.1 秒后）即使不带 requiredSuffix，滞后的短前缀也不得倒流覆写
        now += 0.1
        let resolvedNextKey = tracker.resolveAuthoritativeLeftContext(
            isSecureInput: false,
            maxWindow: 128,
            requiredSuffix: nil,
            queryExternalSnapshot: {
                ExternalLeftContextSnapshot(text: "上海", capturedAt: now, isSynchronousIMK: true)
            }
        )
        XCTAssertEqual(resolvedNextKey, "上海植物园")
    }

    /// 验证当宿主文本框里原本已有文字时，新鲜且包含滚动缓冲后缀的权威快照能无损补全更长上文
    func testFreshAuthoritativeSnapshotExtendsPreexistingTextBeforeCommittedWord() {
        var now: TimeInterval = 1_700_000_000
        let tracker = ContextTracker(maxLength: 2000, clock: { now })

        tracker.recordCommitted("植物园", isSecureInput: false)
        now += 0.05
        let resolved = tracker.resolveAuthoritativeLeftContext(
            isSecureInput: false,
            maxWindow: 128,
            requiredSuffix: "植物园",
            queryExternalSnapshot: {
                ExternalLeftContextSnapshot(
                    text: "周末想去上海植物园",
                    capturedAt: now,
                    isSynchronousIMK: false
                )
            }
        )
        XCTAssertEqual(resolved, "周末想去上海植物园")
        XCTAssertEqual(tracker.sessionText(isSecureInput: false), "周末想去上海植物园")
    }

    /// 验证单字退格、Cmd+A 全选删除、删词/删行重校准与旧 AX 防复活
    func testBackspaceSelectAllAndExternalResyncStayInSync() {
        var now: TimeInterval = 1_700_000_000
        let tracker = ContextTracker(maxLength: 2000, clock: { now })

        tracker.recordCommitted("上海植物园", isSecureInput: false)
        let oldSnapshotBeforeDelete = ExternalLeftContextSnapshot(
            text: "上海植物园",
            capturedAt: now,
            isSynchronousIMK: false
        )

        // 连删 3 个字（删掉「植物园」），精确回到「上海」，且旧 AX 快照绝不能把「植物园」复活
        now += 0.5
        tracker.handleBackspace()
        tracker.handleBackspace()
        tracker.handleBackspace()
        let afterBackspace = tracker.resolveAuthoritativeLeftContext(
            isSecureInput: false,
            maxWindow: 128,
            queryExternalSnapshot: { oldSnapshotBeforeDelete }
        )
        XCTAssertEqual(afterBackspace, "上海")

        // Cmd+A 后再按 Backspace：立即清空并标记 needsAuthoritativeResync，新鲜空快照同步对齐
        now += 0.5
        tracker.markSelectAll()
        XCTAssertTrue(tracker.hasPendingSelectAll)
        tracker.handleBackspace()
        XCTAssertEqual(tracker.sessionText(isSecureInput: false), "")
        XCTAssertTrue(tracker.needsAuthoritativeResync)

        now += 0.1
        let afterClearSync = tracker.resolveAuthoritativeLeftContext(
            isSecureInput: false,
            maxWindow: 128,
            queryExternalSnapshot: {
                ExternalLeftContextSnapshot(text: "", capturedAt: now, isSynchronousIMK: false)
            }
        )
        XCTAssertEqual(afterClearSync, "")
        XCTAssertFalse(tracker.needsAuthoritativeResync)

        // 鼠标点击跳到另一个已有文字的框：markExternalEditOccurred 后采纳新鲜快照对齐新光标位置
        now += 1.0
        tracker.markExternalEditOccurred()
        now += 0.1
        let afterClickMove = tracker.resolveAuthoritativeLeftContext(
            isSecureInput: false,
            maxWindow: 128,
            queryExternalSnapshot: {
                ExternalLeftContextSnapshot(text: "今天天气", capturedAt: now, isSynchronousIMK: false)
            }
        )
        XCTAssertEqual(afterClickMove, "今天天气")
    }
}
