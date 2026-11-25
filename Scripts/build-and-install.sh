#!/usr/bin/env bash
# SmartPinyin 本机一键构建与就地热部署脚本（统一复用 package-installer.sh 单一构建真源）：
# - 自动打包自包含、0 开发机 rpath 泄漏、Apple Development 签名的 SmartPinyin.app 与 SmartPinyinSetup.app
# - 默认就地 rsync -a --delete 同步至 /Library/Input Methods/ 与 /Applications/（保留目录 inode 与辅助功能 TCC 权限）
# - 绝不强杀 imklaunchagent，仅重启 SmartPinyin 与 SmartPinyinInference
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DO_INSTALL=1
SIGN_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-install)
      DO_INSTALL=0
      shift
      ;;
    --sign-identity)
      SIGN_ARGS+=(--sign-identity "${2:-}")
      shift 2
      ;;
    *)
      printf 'Unknown argument: %s (supported: --no-install, --sign-identity <id>)\n' "$1" >&2
      exit 2
      ;;
  esac
done

"$ROOT_DIR/Scripts/package-installer.sh" --format dmg --no-bundle-models "${SIGN_ARGS[@]}"

STAGE="$ROOT_DIR/build/package-stage"
if [ "$DO_INSTALL" -eq 0 ]; then
  printf '==> Build complete (skipped install): %s/SmartPinyin.app\n' "$STAGE"
  exit 0
fi

DEST_IME="/Library/Input Methods/SmartPinyin.app"
DEST_SETUP="/Applications/SmartPinyin Setup.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

printf '==> Deploying in-place (preserving directory inode & Accessibility TCC)...\n'
sudo mkdir -p "$DEST_IME" "$DEST_SETUP"
sudo rsync -ac --delete "$STAGE/SmartPinyin.app/" "$DEST_IME/"
sudo rsync -ac --delete "$STAGE/SmartPinyinSetup.app/" "$DEST_SETUP/"
sudo chown -R root:wheel "$DEST_IME" "$DEST_SETUP"
sudo chmod -R a+rX "$DEST_IME" "$DEST_SETUP"
sudo xattr -dr com.apple.quarantine "$DEST_IME" "$DEST_SETUP" 2>/dev/null || true

if [ -x "$LSREG" ]; then
  "$LSREG" -f "$DEST_IME" >/dev/null 2>&1 || true
  "$LSREG" -f "$DEST_SETUP" >/dev/null 2>&1 || true
fi

pkill -x SmartPinyinInference 2>/dev/null || true
pkill -x SmartPinyin 2>/dev/null || true
sleep 1.0
open -g "$DEST_IME"

codesign --verify --deep --strict "$DEST_IME"
codesign --verify --deep --strict "$DEST_SETUP"
printf '==> Deployed & verified: %s\n' "$DEST_IME"
