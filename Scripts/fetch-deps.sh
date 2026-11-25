#!/usr/bin/env bash
# 拉取 SmartPinyin 构建与测试所需的外部大型依赖资产（幂等，已存在且有效时自动跳过）：
#   1. Vendor/librime/                       <- librime 1.17.0 macOS Universal + 插件
#   2. Resources/RimeData/                   <- 万象拼音 Base v18.2.1
#   3. Resources/RimeData/wanxiang-lts-zh-hans.gram <- 万象 LTS 语法模型（373 MB）
#   4. Models/*.gguf（仅在传入 --with-models 时下载，共约 1.46 GB）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WITH_MODELS=0
FORCE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-models)
      WITH_MODELS=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    *)
      printf 'Unknown argument: %s (supported: --with-models, --force)\n' "$1" >&2
      exit 2
      ;;
  esac
done

LIBRIME_URL="https://github.com/rime/librime/releases/download/1.17.0/rime-33e7814-macOS-universal.tar.bz2"
WANXIANG_URL="https://github.com/amzxyz/rime-wanxiang/releases/download/v18.2.1/rime-wanxiang-base.zip"
GRAM_URL="https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/wanxiang-lts-zh-hans.gram"

QWEN_HF_URL="https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf"
QWEN_MS_URL="https://www.modelscope.cn/api/v1/models/unsloth/Qwen3-0.6B-GGUF/repo?Revision=master&FilePath=Qwen3-0.6B-Q4_K_M.gguf"
HYMT_HF_URL="https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/resolve/main/HY-MT1.5-1.8B-Q4_K_M.gguf"
HYMT_MS_URL="https://www.modelscope.cn/api/v1/models/Tencent-Hunyuan/HY-MT1.5-1.8B-GGUF/repo?Revision=master&FilePath=HY-MT1.5-1.8B-Q4_K_M.gguf"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

download_with_fallback() {
  local dest="$1"
  shift
  local tmp_file="$TMP_DIR/$(basename "$dest").part"
  for url in "$@"; do
    printf '    Downloading %s\n' "$url"
    if curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$tmp_file" "$url"; then
      mv -f "$tmp_file" "$dest"
      return 0
    fi
    rm -f "$tmp_file"
  done
  printf 'ERROR: Failed to download %s from all mirrors.\n' "$dest" >&2
  return 1
}

validate_gguf() {
  local file="$1"
  local min_bytes="$2"
  [ -f "$file" ] || return 1
  local size
  size="$(stat -f '%z' "$file" 2>/dev/null || stat -c '%s' "$file")"
  [ "$size" -ge "$min_bytes" ] || return 1
  local magic_hex
  magic_hex="$(od -An -tx1 -N4 "$file" | tr -d ' \t\r\n')"
  [ "$magic_hex" = "47475546" ]
}

# 1. librime 1.17.0
LIBRIME_DIR="$ROOT_DIR/Vendor/librime"
if [ "$FORCE" -eq 1 ] || [ ! -f "$LIBRIME_DIR/dist/lib/librime.1.17.0.dylib" ]; then
  printf '==> [1/3] Fetching librime 1.17.0 (macOS universal)...\n'
  rm -rf "$LIBRIME_DIR"
  mkdir -p "$LIBRIME_DIR"
  download_with_fallback "$TMP_DIR/librime.tar.bz2" "$LIBRIME_URL"
  tar -xjf "$TMP_DIR/librime.tar.bz2" -C "$LIBRIME_DIR"
else
  printf '==> [1/3] librime 1.17.0 already present, skipping.\n'
fi

# 2. Wanxiang Base v18.2.1
RIME_DATA_DIR="$ROOT_DIR/Resources/RimeData"
if [ "$FORCE" -eq 1 ] || [ ! -f "$RIME_DATA_DIR/wanxiang.schema.yaml" ] || [ ! -f "$RIME_DATA_DIR/dicts/jichu.dict.yaml" ]; then
  printf '==> [2/3] Fetching rime-wanxiang Base v18.2.1...\n'
  mkdir -p "$RIME_DATA_DIR"
  download_with_fallback "$TMP_DIR/wanxiang-base.zip" "$WANXIANG_URL"
  # 使用 macOS 原生 ditto 解压，保留 ZIP 内 UTF-8 中文文件名
  if command -v ditto >/dev/null 2>&1; then
    ditto -xk "$TMP_DIR/wanxiang-base.zip" "$RIME_DATA_DIR"
  else
    unzip -qo "$TMP_DIR/wanxiang-base.zip" -d "$RIME_DATA_DIR"
  fi
else
  printf '==> [2/3] rime-wanxiang Base already present, skipping.\n'
fi

# 3. Wanxiang LTS Grammar Model (373 MB)
GRAM_FILE="$RIME_DATA_DIR/wanxiang-lts-zh-hans.gram"
if [ "$FORCE" -eq 1 ] || [ ! -f "$GRAM_FILE" ] || [ "$(stat -f '%z' "$GRAM_FILE" 2>/dev/null || echo 0)" -lt 300000000 ]; then
  printf '==> [3/3] Fetching wanxiang-lts-zh-hans.gram (~373 MB)...\n'
  download_with_fallback "$GRAM_FILE" "$GRAM_URL"
else
  printf '==> [3/3] wanxiang-lts-zh-hans.gram already present, skipping.\n'
fi

# 4. Optional local GGUF models
if [ "$WITH_MODELS" -eq 1 ]; then
  MODELS_DIR="$ROOT_DIR/Models"
  mkdir -p "$MODELS_DIR"

  QWEN_PATH="$MODELS_DIR/Qwen3-0.6B-Q4_K_M.gguf"
  if [ "$FORCE" -eq 1 ] || ! validate_gguf "$QWEN_PATH" 200000000; then
    printf '==> [Models 1/2] Fetching Qwen3-0.6B-Q4_K_M.gguf (~378 MB)...\n'
    download_with_fallback "$QWEN_PATH" "$QWEN_HF_URL" "$QWEN_MS_URL"
    validate_gguf "$QWEN_PATH" 200000000 || { printf 'ERROR: Invalid GGUF header for %s\n' "$QWEN_PATH" >&2; exit 1; }
  else
    printf '==> [Models 1/2] Qwen3-0.6B-Q4_K_M.gguf already valid, skipping.\n'
  fi

  HYMT_PATH="$MODELS_DIR/HY-MT1.5-1.8B-Q4_K_M.gguf"
  if [ "$FORCE" -eq 1 ] || ! validate_gguf "$HYMT_PATH" 700000000; then
    printf '==> [Models 2/2] Fetching HY-MT1.5-1.8B-Q4_K_M.gguf (~1.08 GB)...\n'
    download_with_fallback "$HYMT_PATH" "$HYMT_HF_URL" "$HYMT_MS_URL"
    validate_gguf "$HYMT_PATH" 700000000 || { printf 'ERROR: Invalid GGUF header for %s\n' "$HYMT_PATH" >&2; exit 1; }
  else
    printf '==> [Models 2/2] HY-MT1.5-1.8B-Q4_K_M.gguf already valid, skipping.\n'
  fi
fi

printf '==> All dependencies ready.\n'
