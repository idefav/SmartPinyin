#!/usr/bin/env python3
"""Render GitHub Release notes for SmartPinyin with SHA-256 checksums and license notice."""

from __future__ import annotations

import argparse
import pathlib
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate SmartPinyin GitHub Release notes.")
    parser.add_argument("--tag", required=True, help="Git tag, e.g. v0.1.0")
    parser.add_argument("--version", required=True, help="Version without leading v, e.g. 0.1.0")
    parser.add_argument("--repo", required=True, help="GitHub owner/repo, e.g. idefav/SmartPinyin")
    parser.add_argument("--checksums", required=True, help="Path to SHA256SUMS.txt")
    parser.add_argument("--output", required=True, help="Output Markdown path")
    args = parser.parse_args()

    sums = pathlib.Path(args.checksums).read_text(encoding="utf-8").strip()
    body = f"""## SmartPinyin {args.tag} (macOS 15+ Apple Silicon)

### 📦 安装包说明
- **离线完整版（`SmartPinyin-{args.version}-arm64.dmg` / `.pkg`）**：已内置万象词库、语法模型与两枚本地 GGUF 模型（`Qwen3-0.6B` + `HY-MT1.5-1.8B`），断网开箱即用。
- **轻量按需版（`SmartPinyin-{args.version}-arm64-lite.dmg` / `.pkg`）**：体积轻巧，安装后可在 `SmartPinyin Setup.app` 中一键在线拉取或导入本地模型。

### ✨ 核心亮点
- ⚡ L1 `librime 1.17` + 万象拼音 v18.2.1 + 语法模型（P50 `0.61 ms`）
- 🔧 三级快打智能纠错与可配置模糊音
- 📜 诗词 / 成语微胶囊（`诗` / `成`）+ 0ms 八大场景智能词库提权
- 📚 开源词库热更新中心（万象每日词库 / THUOCL / 萌娘 / 维基 / 自定义导入）
- ✨ 语境记忆联想续写、中英混输快车道与双进程 XPC `< 2 GB` 离线多语种翻译
- 🧹 一键 6 步零残留自卸载

### 🔐 校验和 (SHA-256)
```text
{sums}
```

> 📜 **协议提示**：本项目基于 [MIT Non-Commercial License (Personal Use Only)](https://github.com/{args.repo}/blob/main/LICENSE) 开源，**仅允许个人学习、研究与非商业使用，禁止任何形式的商用**。
"""
    pathlib.Path(args.output).write_text(body, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
