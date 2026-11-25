import SharedIPC
import SmartPinyinInstallerCore
import SwiftUI

struct LexiconAndSceneView: View {
    @ObservedObject var vm: SetupViewModel
    @State private var selectedImportDomain: InputSceneDomain = .general

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("智能场景适配与知识库优先级（0ms 零重建）") {
                    Toggle("智能场景自适应（结合当前应用与上下文自动抬升对应领域词）", isOn: $vm.preferences.enableSmartSceneAdaptation)

                    Picker("当前场景模式", selection: lockedSceneBinding) {
                        Text("自动智能适配（推荐）").tag(Optional<InputSceneDomain>.none)
                        Divider()
                        ForEach(InputSceneDomain.specializedDomains) { domain in
                            Text("手动锁定：\(domain.displayName)").tag(Optional(domain))
                        }
                    }

                    Toggle("候选词条旁显示诗词 / 成语分类微胶囊（诗 / 成）", isOn: $vm.preferences.showLiteraryBadges)
                    Toggle("激活专业场景时于专业词条旁显示领域微标（游 / 数 / 计 / 美 / 科 / 医 / 财）", isOn: $vm.preferences.showDomainBadges)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("分场景词库优先级倍率")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Button("重置默认倍率") {
                                vm.resetScenePriorityMultipliers()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        ForEach(InputSceneDomain.specializedDomains) { domain in
                            HStack {
                                Text(domain.displayName)
                                    .font(.callout)
                                    .frame(width: 118, alignment: .leading)
                                Picker("", selection: priorityBinding(for: domain)) {
                                    Text("关闭").tag(0.0)
                                    Text("低").tag(0.5)
                                    Text("标准").tag(1.0)
                                    Text("高优先").tag(1.5)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .disabled(!vm.preferences.enableSmartSceneAdaptation && vm.preferences.lockedSceneDomain == nil)
                }

                Section("开源词库管理与动态热更新（写入 RimeUserData，不破坏 App 签名）") {
                    Toggle("打开管理中心时自动检查开源词库新版本", isOn: $vm.preferences.checkLexiconUpdatesOnSetupLaunch)

                    HStack(spacing: 8) {
                        Button {
                            vm.checkLexiconUpdates()
                        } label: {
                            Label(
                                vm.isCheckingLexiconUpdates ? "正在检查更新…" : "检查更新",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isCheckingLexiconUpdates || vm.busyLexiconPackID != nil)

                        Menu {
                            ForEach(InputSceneDomain.allCases) { domain in
                                Button("归属场景：\(domain.displayName)") {
                                    selectedImportDomain = domain
                                    vm.pickAndImportCustomLexicon(domain: domain)
                                }
                            }
                        } label: {
                            Label("导入本地词库 (.dict.yaml / .txt)…", systemImage: "square.and.arrow.down")
                        }
                        .disabled(vm.busyLexiconPackID != nil)

                        Spacer()

                        Button("打开词库目录") {
                            vm.openLexiconFolderInFinder()
                        }
                        .buttonStyle(.bordered)
                    }

                    if let busyID = vm.busyLexiconPackID {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: vm.lexiconProgress)
                            Text(vm.lexiconStatusText.isEmpty ? "正在处理 \(busyID)…" : vm.lexiconStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    if let banner = vm.lexiconBanner, !banner.isEmpty {
                        Label(banner, systemImage: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }

                    if let err = vm.lexiconError, !err.isEmpty {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    ForEach(vm.lexiconItems) { item in
                        lexiconRow(item)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            vm.refreshLexicons()
            if vm.preferences.checkLexiconUpdatesOnSetupLaunch && !vm.hasAutoCheckedLexiconUpdates {
                vm.hasAutoCheckedLexiconUpdates = true
                vm.checkLexiconUpdates()
            }
        }
    }

    @ViewBuilder
    private func lexiconRow(_ item: LexiconPackStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.spec.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text(item.spec.license)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                        if item.spec.domain != .general {
                            Text(item.spec.domain.displayName)
                                .font(.caption2)
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.12), in: Capsule())
                        }
                        if let upd = item.updateInfo, upd.hasUpdate {
                            Text("有新版本 \(upd.latestVersion)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(item.spec.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if item.spec.sourceKind == .wanxiangCoreZip {
                    Button(item.updateInfo?.hasUpdate == true ? "一键热更新" : "重新拉取更新") {
                        vm.installOrUpdateLexicon(item)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(vm.busyLexiconPackID != nil)
                } else if let rec = item.record {
                    Toggle("", isOn: Binding(
                        get: { rec.isEnabled },
                        set: { vm.toggleLexiconEnabled(item, enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(vm.busyLexiconPackID != nil)

                    if item.updateInfo?.hasUpdate == true {
                        Button("更新") {
                            vm.installOrUpdateLexicon(item)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(vm.busyLexiconPackID != nil)
                    }

                    Button(role: .destructive) {
                        vm.removeLexicon(item)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("移除此词库")
                    .disabled(vm.busyLexiconPackID != nil)
                } else {
                    Button("下载安装 (\(item.spec.approxSizeLabel))") {
                        vm.installOrUpdateLexicon(item)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.busyLexiconPackID != nil)
                }
            }

            if let rec = item.record {
                HStack(spacing: 12) {
                    Text("版本：\(rec.installedVersion)")
                    Text("词条：\(rec.entryCount) 条")
                    if item.spec.sourceKind != .wanxiangCoreZip {
                        Picker("归属场景", selection: Binding(
                            get: { rec.domain },
                            set: { vm.updateLexiconDomain(item, domain: $0) }
                        )) {
                            ForEach(InputSceneDomain.allCases) { d in
                                Text(d.displayName).tag(d)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.mini)
                        .frame(maxWidth: 180)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var lockedSceneBinding: Binding<InputSceneDomain?> {
        Binding(
            get: { vm.preferences.lockedSceneDomain },
            set: { vm.preferences.lockedSceneDomain = $0 }
        )
    }

    private func priorityBinding(for domain: InputSceneDomain) -> Binding<Double> {
        Binding(
            get: {
                let raw = vm.preferences.scenePriorityMultipliers[domain.rawValue] ?? 1.0
                if raw <= 0.1 { return 0.0 }
                if raw <= 0.75 { return 0.5 }
                if raw <= 1.25 { return 1.0 }
                return 1.5
            },
            set: { newVal in
                var map = vm.preferences.scenePriorityMultipliers
                map[domain.rawValue] = newVal
                vm.preferences.scenePriorityMultipliers = map
            }
        )
    }
}
