import SharedIPC
import SmartPinyinInstallerCore
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var vm: SetupViewModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("智能排序与自进化记忆（100% 本地存储）") {
                    Toggle("开启本地偏好记忆与自进化排序（越用越懂你）", isOn: $vm.preferences.enablePersonalMemory)
                    Toggle("自动记忆前面输入的文字用于后续推荐与排序（30 分钟短期工作记忆）", isOn: $vm.preferences.enableWorkingMemory)
                    Toggle("允许跨应用共享短期输入主题记忆（自动过滤密码框 / 密钥 / 长数字）", isOn: $vm.preferences.shareWorkingMemoryAcrossApps)
                        .disabled(!vm.preferences.enableWorkingMemory)
                    Toggle("高频连词自动造词沉淀（连续选词累计 ≥ 2 次写入本地词库）", isOn: $vm.preferences.enableAutoPhraseLearning)
                        .disabled(!vm.preferences.enableWorkingMemory || !vm.preferences.enablePersonalMemory)
                    Toggle("结合当前文本框内容快速召回候选（拼音 / 简拼 / 锚点接续）", isOn: $vm.preferences.enableDocumentContextAssist)
                    Toggle("同时召回文本框中的英文术语与代码标识符", isOn: $vm.preferences.enableDocumentEnglishTokens)
                        .disabled(!vm.preferences.enableDocumentContextAssist)
                    Toggle("候选词条旁显示来源微标（✦ AI / 记 记忆 / 文 文档 / 纠 纠错）", isOn: $vm.preferences.showCandidateSourceBadges)
                    Toggle("候选词条旁显示诗词 / 成语分类微胶囊（诗 / 成）", isOn: $vm.preferences.showLiteraryBadges)
                    Toggle("激活专业场景时显示领域微标（游 / 数 / 计 / 美 / 科 / 医 / 财）", isOn: $vm.preferences.showDomainBadges)
                    Toggle("智能场景自适应词库优先级（自动识别游戏 / 数学 / 美术 / 科学 / 计算机语境）", isOn: $vm.preferences.enableSmartSceneAdaptation)

                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("本地记忆库统计（仅存本机，密码框与敏感信息零采集）")
                                .font(.subheadline)
                            Text("拼音偏好 \(vm.memorySummary.pinyinEntries) 条 · 语境搭配 \(vm.memorySummary.contextBigrams) 组 · 自动成词 \(vm.memorySummary.learnedPhrases) 条 · 场景偏好 \(vm.memorySummary.appEntries) 条 · 权重校准 \(vm.memorySummary.weightUpdates) 次")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("刷新") {
                            vm.refreshMemorySummary()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("清空近期记忆") {
                            vm.clearWorkingMemoryOnly()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("清空全部记忆…", role: .destructive) {
                            vm.showClearMemoryConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }

                Section("实时翻译（HY-MT1.5-1.8B · 离线）") {
                    Toggle("开启实时自动翻译模式（弹窗自动显示翻译栏）", isOn: $vm.preferences.defaultTranslateMode)

                    Text("翻译模式下输入拼音会在候选窗下方实时展示译文：按空格或回车直接上屏译文，按数字键 1–9 选词纠错，按 Shift + 回车上屏中文原文。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("默认翻译目标语言", selection: $vm.preferences.defaultTargetLanguage) {
                        ForEach(TargetLanguage.allCases, id: \.self) { lang in
                            Text("\(lang.displayName) (\(lang.shortBadge))").tag(lang)
                        }
                    }

                    Picker("翻译模式按空格键", selection: $vm.preferences.translateSpaceBehavior) {
                        ForEach(TranslateSpaceBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }

                    Picker("空态快速切换译文/语种手势", selection: $vm.preferences.translateQuickGesture) {
                        ForEach(TranslateQuickGesture.allCases) { gesture in
                            Text(gesture.displayName).tag(gesture)
                        }
                    }

                    Picker("拼写时按 Tab 键", selection: $vm.preferences.composingTabBehavior) {
                        ForEach(ComposingTabBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }

                    Picker("一键全局关闭翻译快捷键", selection: $vm.preferences.globalDisableTranslateShortcut) {
                        ForEach(GlobalDisableTranslateShortcut.allCases) { shortcut in
                            Text(shortcut.displayName).tag(shortcut)
                        }
                    }

                    Toggle("拼写时快速双击 Tab（≤ 320ms）或按 ⌥Tab 切换全局翻译开关", isOn: $vm.preferences.doubleTabTogglesGlobalTranslate)
                    Toggle("行内语种前缀（/ja /en 等）同时记住为默认目标语言", isOn: $vm.preferences.inlinePrefixPersistsLanguage)
                    Toggle("连续分段翻译自动补词间空格（如 Hello! Today）", isOn: $vm.preferences.autoSpaceTranslatedSegments)
                    Toggle("普通中文模式支持 Shift + Return 一键译文上屏", isOn: $vm.preferences.shiftReturnQuickTranslate)
                    Toggle("支持行内快速指令（/t 开关翻译 · /ja /en 切语种 · /code 切标点）", isOn: $vm.preferences.inlineLanguagePrefixEnabled)
                    Toggle("允许使用 Option + T / Option + L 快捷键切换翻译（默认关闭，防热键冲突）", isOn: $vm.preferences.enableTranslateHotkeys)
                    Text("快切速查：拼写时 Tab 切本句译文、⌥Tab / 双击 Tab 锁全局或关全局、Shift+Tab 切语种；任意时刻按 ⌃⌥T 一键全局关闭翻译；空态短按右 Option 开关翻译、双击右 Option 弹 1–6 语种直选条。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("拼音、标点与 Coding 模式") {
                    Picker("每页候选词数量", selection: $vm.preferences.candidatePageSize) {
                        Text("5 个").tag(5)
                        Text("6 个").tag(6)
                        Text("7 个（推荐）").tag(7)
                        Text("9 个").tag(9)
                    }

                    Picker("候选窗字体大小", selection: $vm.preferences.candidateFontSize) {
                        Text("紧凑（13 pt）").tag(13.0)
                        Text("标准（15 pt）").tag(15.0)
                        Text("大号（17 pt）").tag(17.0)
                    }

                    Picker("中文模式下按回车键", selection: $vm.preferences.returnKeyBehavior) {
                        ForEach(ReturnKeyBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }

                    Toggle("短按 Shift 快速切换中 / 英文", isOn: $vm.preferences.shiftTapSwitchEnabled)
                    Toggle("程序员中英混输快车道（大写/驼峰/下划线自动临时英文 · Shift+空格输英文短句）", isOn: $vm.preferences.smartInlineEnglishEnabled)
                    Text("提示：中文模式下直接敲 React / T3 / useState / user_id 可免切模式直出英文；全小写单词按回车直出英文；按 Shift+空格可输入带空格的英文短语（如 t3 code）并按回车自动回到中文。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("使用中文全角标点（，。！？）", isOn: $vm.preferences.chinesePunctuation)
                    Toggle("智能标点（数字后 3.14 / 14:30 自动半角 · 智能配对引号 · 中英混输自适应）", isOn: $vm.preferences.smartPunctuationEnabled)
                    Toggle("Coding 模式（中文输入时全局默认使用英文半角标点）", isOn: $vm.preferences.codingModeEnabled)
                    Toggle("在 IDE / 终端 / T3 Code 中自动启用 Coding 模式", isOn: $vm.preferences.autoCodingModeForDevApps)
                    Toggle("输出繁体中文（简转繁）", isOn: $vm.preferences.traditionalChinese)
                    Toggle("开启简拼与声母简码（如 zgr → 中国人）", isOn: $vm.preferences.enableAbbrevPinyin)
                    Toggle("智能拼音自动纠错（纠偏错键、漏键、多键与字母倒序，如 shaighai → 上海）", isOn: $vm.preferences.enableAutoCorrection)
                    Toggle("中英文混输、离线英文词典补全与拼写纠错（如 gitdiz → git地址 · dokcer → Docker）", isOn: $vm.preferences.enableMixedBilingualAssist)
                    Toggle("前后鼻音模糊容错（an↔ang · en↔eng · in↔ing，如 shanhai → 上海）", isOn: $vm.preferences.fuzzyNasalPinyin)
                    Toggle("平翘舌模糊容错（zh↔z · ch↔c · sh↔s）", isOn: $vm.preferences.fuzzyRetroflexPinyin)
                    Toggle("声母 n / l 与 f / h 模糊容错", isOn: $vm.preferences.fuzzyNLAndFHPinyin)
                    Toggle("超长连续输入或找不到匹配时自动切换「单字逐选」模式（支持 ⌥C 手动随时切换）", isOn: $vm.preferences.enableAutoSingleCharFallback)
                    Toggle("候选栏显示 Emoji 表情词条", isOn: $vm.preferences.enableEmojiCandidates)
                }

                Section("整句暂存与整体错字纠偏（类翻译暂存区体验）") {
                    Toggle("开启整句暂存与校对模式（先按空格进草稿校对，确认无误再按空格上屏）", isOn: $vm.preferences.defaultDraftProofreadMode)
                    Toggle("暂存模式下自动使用本地 Qwen3-0.6B 做语义错字纠偏（100% 离线，零新增模型）", isOn: $vm.preferences.enableAIDraftProofread)
                    Picker("校对模式按空格键", selection: $vm.preferences.draftSpaceBehavior) {
                        ForEach(DraftSpaceBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    Picker("一键全局开关暂存校对模式快捷键", selection: $vm.preferences.draftModeToggleShortcut) {
                        ForEach(DraftModeToggleShortcut.allCases) { shortcut in
                            Text(shortcut.displayName).tag(shortcut)
                        }
                    }
                    Text("提示：默认拼写时按空格/1–9 选词进入底栏草稿区并自动错字纠偏，确认无误后再按一次空格（或回车）一次上屏；草稿为空时小写英文直接按回车出原词，大写/驼峰/下划线、万象英文词与 Shift+空格独立英文直接上屏不进草稿盒；按 Shift+回车 或 Option+回车 上屏原稿，按 Option+退格 撤回上一词段，也可输入行内指令 /d 随时开关。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("本地小模型增强（Qwen3-0.6B · 离线）") {
                    Toggle("语境智能重排（根据前文纠正同音歧义）", isOn: $vm.preferences.enableNeuralRerank)
                    Toggle("句末智能联想续写（支持数字直选 + 首字母 0ms 融入候选栏）", isOn: $vm.preferences.enableContinuationPrediction)

                    Picker("联想展示方式", selection: $vm.preferences.predictionDisplayStyle) {
                        ForEach(PredictionDisplayStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .disabled(!vm.preferences.enableContinuationPrediction)

                    Picker("联想条直选快捷键", selection: $vm.preferences.predictionSelectionShortcut) {
                        ForEach(PredictionSelectionShortcut.allCases) { shortcut in
                            Text(shortcut.displayName).tag(shortcut)
                        }
                    }
                    .disabled(
                        !vm.preferences.enableContinuationPrediction
                            || vm.preferences.predictionDisplayStyle == .inlineFusionOnly
                    )

                    Picker("联想浮窗自动收起时间", selection: $vm.preferences.predictionAutoHideSeconds) {
                        Text("4 秒").tag(4)
                        Text("8 秒（推荐）").tag(8)
                        Text("15 秒").tag(15)
                    }
                    .disabled(
                        !vm.preferences.enableContinuationPrediction
                            || vm.preferences.predictionDisplayStyle == .inlineFusionOnly
                    )
                }

                Section("内存与性能保护（< 2GB 档位 C）") {
                    Picker("停止输入后自动释放模型权重", selection: $vm.preferences.idleUnloadSeconds) {
                        Text("1 分钟").tag(60)
                        Text("3 分钟（推荐）").tag(180)
                        Text("5 分钟").tag(300)
                        Text("10 分钟").tag(600)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Label(
                    vm.preferencesSavedHint ?? "修改会自动保存并实时同步到正在运行的 SmartPinyin",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button("恢复默认配置") {
                    vm.resetPreferencesToDefaults()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .onAppear {
            vm.refreshMemorySummary()
        }
        .alert("确定清空本地偏好记忆？", isPresented: $vm.showClearMemoryConfirm) {
            Button("取消", role: .cancel) {}
            Button("确定清空", role: .destructive) {
                vm.clearLocalMemory()
            }
        } message: {
            Text("将清空本地 SQLite 中记录的个人选词偏好、语境搭配、应用场景习惯及在线自校准权重，不会影响万象基础词库与离线模型。")
        }
    }
}
