import SmartPinyinInstallerCore
import SwiftUI

struct UninstallView: View {
    @ObservedObject var vm: SetupViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("卸载 SmartPinyin", systemImage: "trash.circle.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.red)
                    Text("自动切回系统英文键盘、从「键盘 → 输入源」中彻底禁用、终止后台进程并清理选定文件，同时清理卸载器自身，不留幽灵输入法残留。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let banner = vm.infoBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(banner).font(.callout)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                if let err = vm.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(err).font(.callout)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                GroupBox("将移除的项目与磁盘占用") {
                    let usage = vm.diskUsage
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "checkmark.square.fill").foregroundStyle(Color.accentColor)
                            Text("SmartPinyin 输入法本体与控制中心（含自删）")
                            Spacer()
                            Text(InstallerEngine.formatBytes(usage?.totalRemovableAppBytes ?? 0))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Toggle(isOn: $vm.uninstallOptions.removePreferencesAndLogs) {
                            HStack {
                                Text("清除偏好设置、应用缓存与运行日志")
                                Spacer()
                                Text(InstallerEngine.formatBytes(usage?.preferencesAndLogsBytes ?? 0))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Toggle(isOn: $vm.uninstallOptions.removeUserDictionaries) {
                            HStack {
                                Text("同时删除个人词库、扩展词库与偏好记忆（RimeUserData / LexiconPacks / SQLite）")
                                Spacer()
                                Text(InstallerEngine.formatBytes(usage?.userDictionaryBytes ?? 0))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Toggle(isOn: $vm.uninstallOptions.removeLocalModels) {
                            HStack {
                                Text("同时删除本地 GGUF 模型权重（保留以便重装免重下）")
                                Spacer()
                                Text(InstallerEngine.formatBytes(usage?.localModelsBytes ?? 0))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let paths = vm.diskUsage?.installedAppPaths, !paths.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已检测到的安装路径：")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(paths, id: \.path) { url in
                            Text("• \(url.path)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !vm.uninstallCompleted {
                    Text("当前未检测到已安装的 SmartPinyin.app（仍可勾选清理剩余词库/模型/偏好）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if vm.isBusy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(vm.progressMessage).font(.callout)
                    }
                } else if !vm.uninstallCompleted {
                    Button(role: .destructive, action: { vm.showUninstallConfirm = true }) {
                        Label("彻底卸载 SmartPinyin", systemImage: "trash.fill")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                }
                Text("提示：系统级安装卸载仅需一次管理员密码确认；如曾开启「辅助功能」权限且系统设置中仍保留历史条目，可在「隐私与安全性 → 辅助功能」中点「-」移除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .alert("确认彻底卸载 SmartPinyin？", isPresented: $vm.showUninstallConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认卸载", role: .destructive) {
                vm.executeSelfUninstall()
            }
        } message: {
            Text("卸载器将自动切回系统英文键盘、移除输入源注册项并清理选定的应用文件。")
        }
    }
}
