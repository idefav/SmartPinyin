import SmartPinyinInstallerCore
import SwiftUI

@main
struct SmartPinyinSetupApp: App {
    @StateObject private var vm = SetupViewModel()

    var body: some Scene {
        WindowGroup("SmartPinyin 偏好设置与管理中心") {
            RootSetupView(vm: vm)
                .frame(width: 780, height: 600)
        }
        .windowResizability(.contentSize)
    }
}

private struct RootSetupView: View {
    @ObservedObject var vm: SetupViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 10) {
                    Text("智")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.16, green: 0.36, blue: 0.94), Color(red: 0.45, green: 0.22, blue: 0.88)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text("SmartPinyin")
                            .font(.headline)
                        Text("macOS 原生拼音 · 本地小模型联想 · 回车译文")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Picker("", selection: $vm.activeTab) {
                    ForEach(SetupTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 420)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            switch vm.activeTab {
            case .preferences:
                PreferencesView(vm: vm)
            case .lexicon:
                LexiconAndSceneView(vm: vm)
            case .onboarding:
                OnboardingWizardView(vm: vm)
            case .status:
                StatusDashboardView(vm: vm)
            case .uninstall:
                UninstallView(vm: vm)
            }
        }
    }
}

private struct StatusDashboardView: View {
    @ObservedObject var vm: SetupViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("运行状态与权限体检")
                        .font(.title2.bold())
                    Spacer()
                    Button("刷新状态") { vm.refreshAllState() }
                        .buttonStyle(.bordered)
                }

                if let banner = vm.infoBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(banner).font(.caption)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                if let err = vm.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(err).font(.caption)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                if vm.hasMultipleInstalledCopies {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("检测到系统中同时存在多份 SmartPinyin.app 副本，建议在「卸载自己」清理后统一使用系统级安装。")
                            .font(.caption)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                GroupBox("系统集成状态") {
                    VStack(alignment: .leading, spacing: 10) {
                        row("安装位置", value: vm.installedBundlePath ?? "未安装", ok: vm.installedBundlePath != nil)
                        row("系统输入源启用", value: vm.inputSourceStatus.isEnabled ? "已启用" : "未启用", ok: vm.inputSourceStatus.isEnabled)
                        row("辅助功能权限（可选）", value: vm.isAccessibilityTrusted ? "已授权" : "未授权", ok: vm.isAccessibilityTrusted)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 10) {
                    Button("重新注册/启用输入源") { vm.autoRegisterAndEnableIfInstalled() }
                        .buttonStyle(.borderedProminent)
                    Button("打开键盘输入源设置") { vm.openKeyboardInputSourcesSettings() }
                        .buttonStyle(.bordered)
                    Button("前往辅助功能授权") { vm.requestAccessibilityPermission() }
                        .buttonStyle(.bordered)
                }

                GroupBox("本地小模型（档位 C）") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(vm.modelItems) { item in
                            HStack {
                                Text(item.spec.displayName).font(.subheadline.weight(.medium))
                                Spacer()
                                switch item.availability {
                                case .ready(_, let bytes):
                                    Text("已就绪 (\(InstallerEngine.formatBytes(bytes)))")
                                        .font(.caption).foregroundStyle(.green)
                                case .discoverable:
                                    Button("一键导入") { vm.importDiscoveredModel(item) }
                                        .buttonStyle(.borderedProminent).controlSize(.small)
                                        .disabled(vm.downloadingModelID != nil || vm.isBusy)
                                case .missing:
                                    Button("导入本地") { vm.pickAndImportLocalModel(for: item.spec) }
                                        .buttonStyle(.bordered).controlSize(.small)
                                        .disabled(vm.downloadingModelID != nil || vm.isBusy)
                                    Button("在线下载") { vm.downloadModel(item.spec) }
                                        .buttonStyle(.borderedProminent).controlSize(.small)
                                        .disabled(vm.downloadingModelID != nil || vm.isBusy)
                                }
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
                                    Button("取消下载") { vm.cancelModelDownload() }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        vm.activeTab = .uninstall
                    } label: {
                        Label("卸载 SmartPinyin…", systemImage: "trash")
                    }
                }
            }
            .padding(24)
        }
    }

    private func row(_ label: String, value: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(label)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
