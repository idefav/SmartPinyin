# Third-Party Notices & Attributions

SmartPinyin incorporates or downloads the following third-party open-source software, dictionaries, linguistic datasets, and language models. Each component remains governed by its respective upstream license.

## 1. Core Input & Inference Engines

| Component | Source | License |
| :--- | :--- | :--- |
| **librime** (`1.17.0` + `librime-lua`, `librime-octagram`, `librime-predict`) | https://github.com/rime/librime | BSD-3-Clause |
| **llama.cpp** & **ggml** | https://github.com/ggml-org/llama.cpp | MIT License |
| **libomp** (LLVM OpenMP Runtime) | https://github.com/llvm/llvm-project | Apache-2.0 WITH LLVM-exception |

## 2. Pinyin Schema, Dictionaries & Language Model

| Component | Source | License |
| :--- | :--- | :--- |
| **rime-wanxiang** (万象拼音方案与核心词库 `v18.2.1`) | https://github.com/amzxyz/rime-wanxiang | CC-BY-4.0 |
| **wanxiang-lts-zh-hans.gram** (万象语法模型) | https://github.com/amzxyz/RIME-LMDG | CC-BY-4.0 |
| **rime-wanxiang-data** (扩展词库与化学术语子集) | https://github.com/amzxyz/rime-wanxiang-data | CC-BY-4.0 |

## 3. Literary & Domain Tag Index (`Resources/Lexicon/`)

| Component | Source | License |
| :--- | :--- | :--- |
| **chinese-xinhua** (`data/idiom.json`) | https://github.com/pwxcoo/chinese-xinhua | MIT License |
| **THUOCL** (清华大学开放中文词库: chengyu, poem, IT, medical, law, caijing, animal) | https://github.com/thunlp/THUOCL | MIT License |
| **chinese-poetry** (tangshisanbaishou, songci300, qianjiashi, shijing) | https://github.com/chinese-poetry/chinese-poetry | MIT License |

> Citation: 本项目使用了清华大学开放中文词库 (THUOCL)。

## 4. Optional On-Demand Lexicon Packs

Users may optionally install additional community dictionaries inside `SmartPinyin Setup`:

| Component | Source | License |
| :--- | :--- | :--- |
| **mw2fcitx** (萌娘百科 / 中文维基百科词库) | https://github.com/outloudvi/mw2fcitx | CC-BY-SA-3.0 / Unlicense |
| **rime-ice** (雾凇拼音 / 网络词库) | https://github.com/iDvel/rime-ice | GPL-3.0 |

## 5. Local GGUF AI Models (Downloaded On Demand / Bundled in Full Releases)

| Model | Source | License |
| :--- | :--- | :--- |
| **Qwen3-0.6B-Q4_K_M.gguf** | https://huggingface.co/unsloth/Qwen3-0.6B-GGUF | Apache-2.0 |
| **HY-MT1.5-1.8B-Q4_K_M.gguf** | https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF | Tencent Hunyuan Community License |
