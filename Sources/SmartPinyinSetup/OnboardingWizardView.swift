import SmartPinyinInstallerCore
import SwiftUI

struct OnboardingWizardView: View {
    @ObservedObject var vm: SetupViewModel

    var body: some View {
        VStack(spacing: 0) {
            stepBar
                .padding(.horizontal, 24)
                .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let banner = vm.infoBanner {
                        statusBanner(banner, isError: false)
                    }
                    if let err = vm.errorMessage {
                        statusBanner(err, isError: true)
                    }

                    switch vm.step {
                    case .welcomeInstall:
                        stepWelcomeInstall
                    case .enableInputSource:
                        stepEnableInputSource
                    case .permissionsAndModels:
                        stepPermissionsAndModels
                    case .liveSandbox:
                        stepLiveSandbox
                    }
                }
                .padding(24)
            }

            Divider()

            footerBar
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
    }

    private var stepBar: some View {
        HStack(spacing: 12) {
            ForEach(OnboardingStep.allCases) { item in
                let isCurrent = (item == vm.step)
                let isDone = vm.isStepCompleted(item)
                Button(action: { vm.navigateToStep(item) }) {
                    HStack(spacing: 6) {
                        Image(systemName: isDone ? "checkmark.circle.fill" : item.iconName)
                            .foregroundStyle(isDone ? Color.green : (isCurrent ? Color.accentColor : Color.secondary))
                        Text(item.title)
                            .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? .primary : .secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        isCurrent ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                if item != OnboardingStep.allCases.last {
                    Spacer(minLength: 4)
                }
            }
        }
    }

    // MARK: - Step 1: 欢迎与安装

    private var stepWelcomeInstall: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("欢迎安装 SmartPinyin 原生智能输入法")
                    .font(.title2.bold())
                Text("基于 librime 万象拼音 + Apple Silicon 本地小模型（总内存 < 2GB），支持全拼、简拼、语境联想，以及输入中文回车直出英文/多语种。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            GroupBox("选择安装范围") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("安装范围", selection: $vm.installScope) {
                        ForEach(InstallScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    Text("目标路径：\(vm.installScope.inputMethodsDirectory.path)/SmartPinyin.app")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let installed = vm.installedBundlePath {
                Label("已安装至：\(installed)", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Label("点击右下角「安装并继续」将自动部署 SmartPinyin.app 并注册系统输入源。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if vm.isBusy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(vm.progressMessage).font(.callout)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Step 2: 输入源自动注册与启用

    private var stepEnableInputSource: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("开通 macOS 系统输入源")
                .font(.title2.bold())
            Text("系统需要启用 SmartPinyin 后才能通过快捷键切换输入法。向导会尝试自动注册并启用，同时实时监测开通状态。")
                .font(.callout)
                .foregroundStyle(.secondary)

            GroupBox("当前输入源状态（自动刷新）") {
                VStack(alignment: .leading, spacing: 10) {
                    checkRow(title: "1. 输入法包已部署到 Input Methods 目录", ok: vm.installedBundlePath != nil)
                    checkRow(title: "2. 已向系统文本服务（TSM）注册", ok: vm.inputSourceStatus.isRegistered)
                    checkRow(title: "3. 已在系统「键盘 → 输入源」中启用", ok: vm.inputSourceStatus.isEnabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                if vm.installedBundlePath == nil && vm.hasEmbeddedPayload {
                    Button(action: { vm.performInstall() }) {
                        Label("立即安装并注册输入源", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isBusy)
                } else {
                    Button(action: { vm.autoRegisterAndEnableIfInstalled() }) {
                        Label("自动注册并启用", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.installedBundlePath == nil)
                }

                Button(action: { vm.openKeyboardInputSourcesSettings() }) {
                    Label("打开「系统设置 → 键盘 → 输入源」", systemImage: "gear")
                }
                .buttonStyle(.bordered)
            }

            if !vm.inputSourceStatus.isEnabled {
                Text("如 macOS 未自动添加：在打开的「系统设置 → 键盘 → 输入法 → 编辑」中点左下角「+」，搜索并添加「SmartPinyin」即可，此页面会自动变绿确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Step 3: 权限与本地小模型

    private var stepPermissionsAndModels: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("权限体检与本地小模型就绪")
                .font(.title2.bold())

            GroupBox("辅助功能权限（可选增强）") {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: vm.isAccessibilityTrusted ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                        .font(.title2)
                        .foregroundStyle(vm.isAccessibilityTrusted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(vm.isAccessibilityTrusted ? "已为 SmartPinyin 开通辅助功能权限" : "尚未开通辅助功能权限（可跳过）")
                            .font(.headline)
                        Text("点击「前往授权」后，在「隐私与安全性 → 辅助功能」中打开「SmartPinyin」开关，切回本窗口将自动变绿刷新。所有数据 100% 本地处理，不联网。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !vm.isAccessibilityTrusted {
                        Button("前往授权") {
                            vm.requestAccessibilityPermission()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Button(action: { vm.refreshAllState() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("立即重新检测权限与模型状态")
                }
                .padding(8)
            }

            GroupBox("本地小模型（档位 C · 总内存 < 2GB）") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.modelItems) { item in
                        modelRow(item)
                        if item.id != vm.modelItems.last?.id {
                            Divider()
                        }
                    }
                    if let activeID = vm.downloadingModelID {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: vm.downloadProgress)
                            HStack {
                                Text("正在下载 \(activeID)：\(vm.downloadDetailText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("取消下载") {
                                    vm.cancelModelDownload()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ item: ModelInspectionItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            switch item.availability {
            case .ready(_, let bytes):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.spec.displayName).font(.subheadline.weight(.semibold))
                    Text("\(item.spec.roleDescription) · 已就绪 (\(InstallerEngine.formatBytes(bytes)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("已就绪").font(.caption.weight(.medium)).foregroundStyle(.green)

            case .discoverable(_, let bytes):
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.spec.displayName).font(.subheadline.weight(.semibold))
                    Text("在本机发现可用权重 (\(InstallerEngine.formatBytes(bytes)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("一键导入") { vm.importDiscoveredModel(item) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

            case .missing:
                Image(systemName: "arrow.down.circle").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.spec.displayName).font(.subheadline.weight(.semibold))
                    Text("\(item.spec.roleDescription) · 约 \(item.spec.expectedSizeMB) MB")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("导入本地") { vm.pickAndImportLocalModel(for: item.spec) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.downloadingModelID != nil)
                Button("在线下载") { vm.downloadModel(item.spec) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(vm.downloadingModelID != nil)
            }
        }
    }

    // MARK: - Step 4: 现场试打框

    private var stepLiveSandbox: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("现场试打验收")
                .font(.title2.bold())
            Text("点击下方输入框，切换到 SmartPinyin 体验全拼/简拼（zgr、wsm）、中英混输与纠错（gitdiz → git地址、dokcer → Docker），以及单击右 Option 开启译文模式后输入中文直接回车出英文。")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $vm.sandboxText)
                .font(.system(size: 15))
                .frame(height: 110)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            GroupBox("核心快捷键速查") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    shortcutRow("短按 Shift", "中文拼音 / 英文直出快速切换")
                    shortcutRow("中英混输 / 纠错", "直接敲 gitdiz → git地址、dokcer → Docker；大写/驼峰/下划线免切英文，错拼按 Tab 纠正")
                    shortcutRow("右 Option 单击 / 双击", "空态 0ms 开关「译文模式」/ 弹出 1–6 语种直选（拼写时 Tab 切本句译文、⌃⌥T 全局关闭）")
                    shortcutRow("⌃⌥D 或 /d", "开关「整句暂存校对模式」（先按空格进草稿自动纠偏，再按空格整句上屏）")
                    shortcutRow("Shift + Return", "普通中文模式下临时将当前句一键译成英文上屏")
                    shortcutRow("/ja  /en  /ko  /code", "行内快速指定单句翻译语种或切换中英标点风格")
                    shortcutRow("1 / 2 / 3 或 Tab", "上屏后单手采纳本地小模型联想续写（继续打首字母 0ms 融入首位）")
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func shortcutRow(_ key: String, _ desc: String) -> some View {
        GridRow {
            Text(key)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            Text(desc).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func checkRow(title: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
            Text(title)
                .font(.callout)
                .foregroundStyle(ok ? .primary : .secondary)
        }
    }

    private func statusBanner(_ text: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(text).font(.caption)
            Spacer()
        }
        .padding(10)
        .background(
            (isError ? Color.red : Color.green).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private var footerBar: some View {
        HStack {
            if vm.step != .welcomeInstall {
                Button("上一步") {
                    if let prev = OnboardingStep(rawValue: vm.step.rawValue - 1) {
                        vm.errorMessage = nil
                        vm.step = prev
                    }
                }
                .disabled(vm.isBusy)
            }
            Spacer()

            switch vm.step {
            case .welcomeInstall:
                if vm.installedBundlePath != nil {
                    Button("覆盖重装") {
                        vm.performInstall()
                    }
                    .disabled(vm.isBusy || !vm.hasEmbeddedPayload)

                    Button("下一步") {
                        vm.navigateToStep(.enableInputSource)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isBusy)
                } else {
                    Button(action: { vm.performInstall() }) {
                        Label("安装并继续", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isBusy || !vm.hasEmbeddedPayload)
                }

            case .enableInputSource, .permissionsAndModels:
                Button("下一步") {
                    if let next = OnboardingStep(rawValue: vm.step.rawValue + 1) {
                        vm.navigateToStep(next)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isBusy)

            case .liveSandbox:
                Button("完成并关闭") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
