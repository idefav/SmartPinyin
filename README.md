<div align="center">

# 智 · SmartPinyin

**为 Apple Silicon 而生的 macOS 原生智能拼音输入法**

[![macOS 15+ Apple Silicon](https://img.shields.io/badge/macOS-15.0%2B%20Apple%20Silicon-0071E3?style=flat-square&logo=apple)](https://github.com/idefav/SmartPinyin/releases)
[![GitHub Pages Showcase](https://img.shields.io/badge/Interactive%20Showcase-GitHub%20Pages-6366F1?style=flat-square&logo=githubpages)](https://idefav.github.io/SmartPinyin/)
[![CI](https://img.shields.io/github/actions/workflow/status/idefav/SmartPinyin/ci.yml?branch=main&label=CI&style=flat-square)](https://github.com/idefav/SmartPinyin/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/idefav/SmartPinyin?style=flat-square&color=10B981)](https://github.com/idefav/SmartPinyin/releases)
[![License: MIT Non-Commercial](https://img.shields.io/badge/License-MIT%20Non--Commercial%20(Personal%20Use%20Only)-F59E0B?style=flat-square)](./LICENSE)

[✨ 互动动画主页](https://idefav.github.io/SmartPinyin/) · [📦 下载安装包](https://github.com/idefav/SmartPinyin/releases) · [⌨️ 快捷键一览](#-快捷键与操作指南) · [🛠️ 本地构建](#-从源码构建与测试) · [📜 协议说明](#-开源协议非商用限制)

</div>

---

SmartPinyin 基于原生 `InputMethodKit`、`librime 1.17`（万象拼音 + 语法模型）与独立 XPC 进程的本地小模型（`llama.cpp` + Metal GPU）打造。100% 离线运行、零云端上传、常驻内存极低，将传统输入法的毫秒级稳定响应与本地端侧 AI 的语境理解融为一体。

## ✨ 核心特性

- **⚡ L1 极速确定性底座（P50 `0.61 ms`）& 单字逐选兜底**：基于 `librime 1.17` + 万象拼音 `v18.2.1` + `wanxiang-lts-zh-hans.gram` 语法模型，全拼、简拼、整句与用户词频持久化毫秒级响应；超长串或无整句候选时自动兜底进入**单字逐选模式**（亦支持 `⌥C` 手动开关，且自动避让纯英文与中英混输候选）。
- **🔤 中英文免切混输、7.3 万离线英文词库 & 双层拼写纠错**：
  - 无需切换中英文模式，直接输入「英+中 / 中+英 / 词头+拼音」（如 `gitdiz` → `git地址`、`gitck` → `git仓库`、`reactzj` → `React组件`、`dockerjx` → `Docker镜像`、`apiwd` → `API文档`、`wodegit` → `我的git`），候选轻量标注 `混` / `英` 微胶囊；
  - 启动 0ms 阻塞异步加载随包 73,171 条离线英文词库与技术词规范大小写覆盖，支持 QWERTY 邻键替换/转置/漏键/多键双层英文拼写纠错（如 `dokcer` → `Docker`、`recat` → `React`、`typescritp` → `TypeScript`、`enviroment` → `environment`、`gtidiz` → `git地址`）；
  - 大写/驼峰/下划线标识符（如 `React`、`API_KEY`、`user_id`）免切直出；临时英文空文档同样支持前缀补全与 `Tab` 一键采纳纠错（`Recat + Tab` → `React`，按 `Space` 严格保留原词），并支持双语记忆自学习与英文锚点续写。
- **📝 整句暂存与整体错字纠偏模式（两段空格）**：`⌃⌥D` 或 `/d` 随时开启——第一下 `Space` 将候选送入草稿栏并触发 **L1 规则 + L2 `Qwen3-0.6B` 五重护栏**对整句同音/错别字进行自动纠偏，确认无误再按一下 `Space` 整句上屏；`Shift+Return` / `Option+Return` 上屏原稿，`Option+Backspace` 整段撤回。
- **🔧 三级快打中文纠错 & 可配置模糊音**：自动纠偏键盘误触、漏键、连键、倒序（如 `shaighai` → `上海`、`shanhai` → `山海 / 上海 纠`），默认开启前后鼻音模糊（`an↔ang / en↔eng / in↔ing`），平翘舌与 `n↔l / f↔h` 按需开关；纠偏词自动按正确拼音回写个人记忆，不污染词库。
- **📜 诗词 / 成语微胶囊 & 0ms 场景智能词库**：离线内置 56,828 条成语与古诗词索引及 50,851 条多领域知识库，候选栏自适应深浅色标注 `诗` / `成` 微胶囊；0ms 实时感知应用上下文与前文语境，在 **计算机、游戏、数学、科学、美术设计、诗词文学、医学、财经法律** 8 大专业场景间自动切换并动态提权候选（如右上角显示 `拼 · 游戏`、`拼 · 数学`、`拼 · Code`）。
- **📚 开源词库热更新中心**：在 `SmartPinyin Setup` →「词库与场景」一键拉取万象每日构建词库、按需启用 THUOCL / 萌娘百科 / 维基百科 / 万象扩展词库，或导入自定义 `.dict.yaml` / `.txt` 词表，后台自动热部署并实时生效。
- **🌐 语境记忆联想续写 & 双进程 XPC 离线翻译（严格 `< 2 GB` 内存闸门）**：
  - IMK 宿主进程仅常驻约 `33 MB`；所有神经网络推理隔离在独立 `SmartPinyinInference.xpc` 进程内，异常自动无感降级回纯离线拼音。
  - 完整追踪会话前文与退格删改状态，上屏后单手 `1/2/3` 或 `Tab` 采纳精准联想续写（继续打首字母 0ms 融入首位）。
  - **日常槽** `Qwen3-0.6B-Q4_K_M`（语境重排 + 整句校对 + 句末联想）与 **专职翻译槽** `HY-MT1.5-1.8B-Q4_K_M`（中→英/日/韩/法/德/西实时翻译）互斥懒加载，空闲 180 秒自动释放显存/内存。
- **🛡️ 图形化引导、零冗余升级与 6 步安全「卸载自己」**：
  - Lite 包安装后再下载模型时 XPC 自动动态发现，**免重启即刻生效**；Full PKG 模型经独立暂存目录安装后自动清理，消除 1.46 GB 永久双份占用；覆盖升级自动保留目录 inode 与辅助功能 TCC 权限。
  - 卸载合并为**单次同步管理员提权**，取消授权自动回滚不损现有安装，并彻底清理 Setup 缓存、HTTPStorages、PKG 收据与自删自身；打包链路内置 `@rpath` 闭环硬校验与自内向外逐层签名。

## ⌨️ 快捷键与操作指南

| 快捷键 / 触发 | 功能说明 |
| :--- | :--- |
| 短按 `Shift` | 快速切换 **中文拼音 / 英文直出** |
| `gitdiz` / `dokcer` / `Recat + Tab` | 免切中英混输与双层英文拼写纠错；大写/驼峰/下划线免切直出；临时英文下 `Tab` 纠错补全、`Space` 保留原词 |
| `⌃⌥D` 或 `/d` | 开关 **整句暂存与整体错字纠偏模式**（两段空格：首空格入草稿自动纠偏，再空格整句上屏；`Option + Backspace` 整段撤回） |
| `⌥C` | 手动开关 **单字逐选模式**（超长无候选也会自动兜底进入） |
| 单击 `右 Option` | 空态 0ms 开关「实时翻译上屏模式」 |
| 双击 `右 Option` | 弹出 `1–6` 语种直选悬浮胶囊条（`EN / JA / KO / FR / DE / ES`） |
| 拼写时 `Tab` / `⌃⌥T` | 临时切换本句译文 / 全局一键关闭翻译模式 |
| `Shift + Return` | 普通中文模式下将当前整句一键译成英文并上屏（草稿校对模式下上屏原稿） |
| `Option + Return` | 在译文/校对模式下强制上屏原文 |
| `/ja ` `/en ` `/ko ` `/t` `/d` `/code` | 行内指令：单句切语种 / 开关翻译 / 开关整句校对 / 切换中英标点风格 |
| `1 / 2 / 3` 或 `Tab` | 上屏后单手采纳句末联想续写（含英文锚点续写；继续打首字母 0ms 置顶） |

## 📦 安装方式

前往 [GitHub Releases](https://github.com/idefav/SmartPinyin/releases) 下载对应安装包（仅支持 **macOS 15.0+ Apple Silicon**）：

- **离线完整版（`SmartPinyin-<version>-arm64.dmg` / `.pkg`，约 `1.8 GB`）**：已内置万象词库、语法模型与两枚本地 GGUF 模型，断网开箱即用。
- **轻量按需版（`SmartPinyin-<version>-arm64-lite.dmg` / `.pkg`，约 `373 MB`）**：安装包轻巧，首次打开 `SmartPinyin Setup.app` 时可按需一键从 ModelScope / HuggingFace 拉取或导入本地模型。

> 若未配置 Apple 公证证书，首次打开如提示「无法验证开发者」，请右键点击安装包选择「打开」或在「系统设置 → 隐私与安全性」中点击「仍要打开」。

## 🛠️ 从源码构建与测试

### 环境要求
- macOS 15.0+（Apple Silicon M1/M2/M3/M4/M5）
- Xcode 16+（含 Command Line Tools）
- Homebrew 依赖：

```bash
brew install xcodegen llama.cpp ggml libomp
```

### 一键拉取依赖、测试与打包

```bash
# 1. 拉取 librime 1.17.0、万象词库 v18.2.1 与万象 LTS 语法模型（不污染 Git 仓库）
bash Scripts/fetch-deps.sh

# （可选）同时下载两枚本地 GGUF 模型用于离线全量打包或 Benchmark
bash Scripts/fetch-deps.sh --with-models

# 2. 运行全部单元测试（105 项用例覆盖状态机、中英混输与英文纠错、整句校对、单字逐选、拼音纠错、诗词/场景标签、词库管理与安装卸载）
swift test

# 3. 打包可分发安装包（默认输出至 dist/，内置 @rpath 闭环与 Mach-O 零路径泄漏硬校验）
bash Scripts/package-installer.sh --format all --no-bundle-models   # 轻量版 DMG + PKG
bash Scripts/package-installer.sh --format all --bundle-models      # 完整离线版 DMG + PKG

# 4. 本机一键编译并就地热部署（保留 .app 目录 inode 与辅助功能 TCC 权限）
bash Scripts/build-and-install.sh
```

## 🚀 CI / Release 自动化流水线

- **[CI (`ci.yml`)](./.github/workflows/ci.yml)**：每次推送或 PR 至 `main` 时，自动在 GitHub `macos-15`（Apple Silicon）上安装依赖、拉取缓存词库并运行全量 `swift test`。
- **[Release (`release.yml`)](./.github/workflows/release.yml)**：推送语义化标签（如 `git tag v0.2.0 && git push origin v0.2.0`）或在 Actions 页面手动触发 `workflow_dispatch`，自动测试、打包 `arm64-lite` 与可选 `arm64` 完整离线版 DMG/PKG、生成 `SHA256SUMS.txt` 并发布至 GitHub Releases。
  - 支持在仓库 Secrets 配置可选签名密钥：`MACOS_SIGN_P12_BASE64`、`MACOS_SIGN_P12_PASSWORD`、`MACOS_SIGN_IDENTITY`（未配置时自动以 ad-hoc 签名完成构建）。
- **[GitHub Pages (`pages.yml`)](./.github/workflows/pages.yml)**：推送 `docs/**` 时自动部署互动动画演示站至 `https://idefav.github.io/SmartPinyin/`。

## 🧹 零残留「卸载自己」

随时可通过以下任意入口彻底卸载（自动切回系统英文键盘、禁用输入源、停止进程、按勾选清理词库与模型，并延迟自删卸载器本身）：
1. 点击右上角状态栏 SmartPinyin 输入法图标 → **卸载 SmartPinyin…**
2. 打开 `SmartPinyin Setup.app` → 顶部切换到 **卸载自己**
3. 重新打开 `.dmg` 内的 `Install SmartPinyin.app` → 切换到 **卸载自己**

## 📜 开源协议（非商用限制）

本项目采用 **[MIT Non-Commercial License (Personal Use Only)](./LICENSE)**（基于 MIT 协议修订）：

- ✅ **允许**：个人学习、研究、日常使用、修改与保留协议声明的非商业分发。
- ❌ **禁止商用**：未经版权方事先书面许可，**严禁任何形式的商业使用**（包括但不限于出售、收费分发/安装/支持、嵌入商业软硬件或付费服务、广告变现、企业/商业机构用于商业运营）。
- 第三方开源引擎、词库与模型遵循各自原协议，详见 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)。
