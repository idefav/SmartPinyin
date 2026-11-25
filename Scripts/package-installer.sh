#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="0.1.0"
ARCH="arm64"
FORMAT="all"          # dmg | pkg | all
BUNDLE_MODELS=1       # 默认内置本地小模型，开箱即用免在线下载
SIGN_IDENTITY=""      # 默认自动探测本机稳定 Apple Development / Developer ID 证书以保障 TCC 权限稳定

while [ "$#" -gt 0 ]; do
  case "$1" in
    --format)
      FORMAT="${2:-all}"
      shift 2
      ;;
    --bundle-models)
      BUNDLE_MODELS=1
      shift
      ;;
    --no-bundle-models)
      BUNDLE_MODELS=0
      shift
      ;;
    --sign-identity)
      SIGN_IDENTITY="${2:--}"
      shift 2
      ;;
    --version)
      VERSION="${2:-0.1.0}"
      shift 2
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

# 自动选择稳定签名身份（优先 Developer ID Application -> Apple Development -> 回落 ad-hoc '-'）
# 注意：使用默认空白分隔取 $2（40 位 SHA-1 指纹），避免钥匙串存在同名证书时 codesign 报 ambiguous 错误
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application:/ {print $2; exit}')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development:/ {print $2; exit}')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="-"
fi
printf '==> Using codesign identity: %s (bundle_models=%d)\n' "$SIGN_IDENTITY" "$BUNDLE_MODELS"

case "$FORMAT" in
  dmg|pkg|all) ;;
  *)
    printf 'Invalid --format value: %s (expected dmg|pkg|all)\n' "$FORMAT" >&2
    exit 2
    ;;
esac

BUILD_DIR="$ROOT_DIR/build"
STAGE_DIR="$BUILD_DIR/package-stage"
DIST_DIR="$ROOT_DIR/dist"
mkdir -p "$BUILD_DIR" "$DIST_DIR"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

cd "$ROOT_DIR"

# 1. 使用原生 CoreGraphics 生成标准 macOS AppIcon.icns
generate_app_icon() {
  local icns_out="$1"
  local iconset_dir="$STAGE_DIR/AppIcon.iconset"
  local base_png="$STAGE_DIR/icon_1024.png"
  mkdir -p "$iconset_dir"

  swift - "$base_png" <<'SWIFT'
import AppKit
import Foundation

let outPath = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 1024,
    pixelsHigh: 1024,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx

let rect = NSRect(origin: .zero, size: size).insetBy(dx: 72, dy: 72)
let path = NSBezierPath(roundedRect: rect, xRadius: 210, yRadius: 210)

let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.94, alpha: 1.0),
    ending: NSColor(calibratedRed: 0.45, green: 0.22, blue: 0.88, alpha: 1.0)
)!
gradient.draw(in: path, angle: -45)

// 微妙玻璃高光边框
NSColor.white.withAlphaComponent(0.28).setStroke()
path.lineWidth = 10
path.stroke()

// 主字标「智」（与状态栏、系统设置、光标浮标全链路图标统一）
let mainAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 470, weight: .bold),
    .foregroundColor: NSColor.white
]
let mainStr = NSAttributedString(string: "智", attributes: mainAttrs)
let mainSize = mainStr.size()
mainStr.draw(at: NSPoint(x: (1024 - mainSize.width) / 2 - 40, y: (1024 - mainSize.height) / 2 + 20))

// 右下角「EN」小胶囊徽章
let badgeRect = NSRect(x: 560, y: 170, width: 270, height: 130)
let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 65, yRadius: 65)
NSColor.white.withAlphaComponent(0.24).setFill()
badgePath.fill()

let badgeAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 78, weight: .heavy),
    .foregroundColor: NSColor.white
]
let badgeStr = NSAttributedString(string: "EN", attributes: badgeAttrs)
let badgeSize = badgeStr.size()
badgeStr.draw(at: NSPoint(
    x: badgeRect.midX - badgeSize.width / 2,
    y: badgeRect.midY - badgeSize.height / 2 + 2
))

NSGraphicsContext.restoreGraphicsState()
let data = rep.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: outPath))
SWIFT

  for sz in 16 32 128 256 512; do
    sips -z "$sz" "$sz" "$base_png" --out "$iconset_dir/icon_${sz}x${sz}.png" >/dev/null
    local sz2=$((sz * 2))
    sips -z "$sz2" "$sz2" "$base_png" --out "$iconset_dir/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset_dir" -o "$icns_out"
}

# 生成匹配 macOS 状态栏与系统设置风格的矢量 PDF 模板图标 menu_icon.pdf (16x16pt，真正 evenOdd 透明镂空)
generate_menu_icon() {
  local pdf_out="$1"
  swift - "$pdf_out" <<'SWIFT'
import CoreGraphics
import CoreText
import Foundation

let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
var mediaBox = CGRect(x: 0, y: 0, width: 16, height: 16)
guard let consumer = CGDataConsumer(url: outURL as CFURL),
      let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
else {
    fatalError("Failed to create PDF context")
}

ctx.beginPDFPage(nil)
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

// 与微信输入法/搜狗/系统自带「拼」尺寸对齐的 16x16pt 矢量模板图标：
// 使用 evenOdd 复合路径将「智」字真正镂空为透明，确保 isTemplate=true 时深浅色/蓝底选中均清晰锐利
let bgRect = CGRect(x: 0.5, y: 1.5, width: 15.0, height: 13.0)
let composite = CGMutablePath()
composite.addRoundedRect(in: bgRect, cornerWidth: 3.0, cornerHeight: 3.0)

let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 9.6, nil)
let ch: [UniChar] = Array("智".utf16)
var glyphs = [CGGlyph](repeating: 0, count: ch.count)
if CTFontGetGlyphsForCharacters(font, ch, &glyphs, ch.count),
   let glyphPath = CTFontCreatePathForGlyph(font, glyphs[0], nil) {
    let gBounds = glyphPath.boundingBoxOfPath
    var transform = CGAffineTransform(
        translationX: bgRect.midX - gBounds.midX,
        y: bgRect.midY - gBounds.midY
    )
    if let positioned = glyphPath.copy(using: &transform) {
        composite.addPath(positioned)
    }
}

ctx.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
ctx.addPath(composite)
ctx.fillPath(using: .evenOdd)

ctx.endPDFPage()
ctx.closePDF()
SWIFT
}

printf '==> [1/6] Generating AppIcon.icns, menu_icon.pdf and SmartPinyin.xcodeproj\n'
ICON_FILE="$STAGE_DIR/AppIcon.icns"
MENU_ICON_FILE="$STAGE_DIR/menu_icon.pdf"
generate_app_icon "$ICON_FILE"
generate_menu_icon "$MENU_ICON_FILE"
xcodegen generate --spec "$ROOT_DIR/project.yml"

printf '==> [2/6] Building Release SmartPinyin.app & SmartPinyinSetup.app\n'
xcodebuild \
  -project "$ROOT_DIR/SmartPinyin.xcodeproj" \
  -scheme SmartPinyin \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  build

xcodebuild \
  -project "$ROOT_DIR/SmartPinyin.xcodeproj" \
  -scheme SmartPinyinSetup \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  build

PRODUCTS_DIR="$BUILD_DIR/DerivedData/Build/Products/Release"
IME_SRC="$PRODUCTS_DIR/SmartPinyin.app"
SETUP_SRC="$PRODUCTS_DIR/SmartPinyinSetup.app"

printf '==> [3/6] Assembling self-contained SmartPinyin.app and SmartPinyinSetup.app\n'
IME_APP="$STAGE_DIR/SmartPinyin.app"
SETUP_HELPER="$STAGE_DIR/SmartPinyinSetup.app"
cp -R "$IME_SRC" "$IME_APP"
cp -R "$SETUP_SRC" "$SETUP_HELPER"
chmod -R u+w "$IME_APP" "$SETUP_HELPER"

# 同步版本号至待打包的各 Info.plist，保证 GitHub Release 标签与安装包版本严格一致
for plist_file in \
  "$IME_APP/Contents/Info.plist" \
  "$IME_APP/Contents/XPCServices/SmartPinyinInference.xpc/Contents/Info.plist" \
  "$SETUP_HELPER/Contents/Info.plist"; do
  if [ -f "$plist_file" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$plist_file" 2>/dev/null || true
  fi
done

mkdir -p \
  "$IME_APP/Contents/Resources/zh-Hans.lproj" \
  "$IME_APP/Contents/Resources/zh_CN.lproj" \
  "$IME_APP/Contents/Resources/en.lproj" \
  "$IME_APP/Contents/Resources/Base.lproj" \
  "$SETUP_HELPER/Contents/Resources"
cp "$ICON_FILE" "$IME_APP/Contents/Resources/AppIcon.icns"
cp "$MENU_ICON_FILE" "$IME_APP/Contents/Resources/menu_icon.pdf"
cp "$ICON_FILE" "$SETUP_HELPER/Contents/Resources/AppIcon.icns"

# 写入 UTF-16LE 编码的全语言目录 InfoPlist.strings（与微信/搜狗输入法格式一致），确保系统设置与菜单栏干净显示「SmartPinyin」
TMP_STRINGS_UTF8="$STAGE_DIR/InfoPlist.utf8.strings"
cat > "$TMP_STRINGS_UTF8" <<'STRINGS'
"CFBundleDisplayName" = "SmartPinyin";
"CFBundleName" = "SmartPinyin";
"com.smartpinyin.inputmethod.SmartPinyin" = "SmartPinyin";
"com.smartpinyin.inputmethod.SmartPinyin.pinyin" = "SmartPinyin";
STRINGS

for strings_path in \
  "$IME_APP/Contents/Resources/InfoPlist.strings" \
  "$IME_APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" \
  "$IME_APP/Contents/Resources/zh_CN.lproj/InfoPlist.strings" \
  "$IME_APP/Contents/Resources/en.lproj/InfoPlist.strings" \
  "$IME_APP/Contents/Resources/Base.lproj/InfoPlist.strings"; do
  iconv -f UTF-8 -t UTF-16 "$TMP_STRINGS_UTF8" > "$strings_path"
done

mkdir -p "$IME_APP/Contents/Frameworks/rime-plugins"
mkdir -p "$IME_APP/Contents/Frameworks/ggml-backends"
mkdir -p "$IME_APP/Contents/Resources/RimeData"
mkdir -p "$IME_APP/Contents/Helpers"

cp -af "$ROOT_DIR/Vendor/librime/dist/lib"/librime*.dylib "$IME_APP/Contents/Frameworks/"
cp -af "$ROOT_DIR/Vendor/librime/dist/lib/rime-plugins"/*.dylib "$IME_APP/Contents/Frameworks/rime-plugins/"

LLAMA_LIB_DIR="$(brew --prefix llama.cpp)/lib"
GGML_PREFIX="$(brew --prefix ggml 2>/dev/null || brew --prefix llama.cpp)"
LIBOMP_LIB_DIR="$(brew --prefix libomp)/lib"
cp -af "$LLAMA_LIB_DIR"/libllama.dylib "$LLAMA_LIB_DIR"/libllama.*.dylib "$IME_APP/Contents/Frameworks/" 2>/dev/null || true
cp -af "$GGML_PREFIX/lib"/libggml.dylib "$GGML_PREFIX/lib"/libggml.*.dylib "$GGML_PREFIX/lib"/libggml-base*.dylib "$IME_APP/Contents/Frameworks/" 2>/dev/null || true
if [ -d "$GGML_PREFIX/libexec" ]; then
  cp -af "$GGML_PREFIX/libexec"/*.so "$IME_APP/Contents/Frameworks/ggml-backends/" 2>/dev/null || true
elif [ -d "$LLAMA_LIB_DIR" ]; then
  cp -af "$LLAMA_LIB_DIR"/libggml-*.so "$IME_APP/Contents/Frameworks/ggml-backends/" 2>/dev/null || true
fi
cp -af "$LIBOMP_LIB_DIR"/libomp.dylib "$IME_APP/Contents/Frameworks/"
chmod -R u+w "$IME_APP/Contents/Frameworks"

# 重写所有对 /opt/homebrew 或 /usr/local 的绝对路径依赖为 @rpath，保证安装包发到无 Homebrew 的 Mac 也能独立运行
rewrite_homebrew_refs() {
  local bin="$1"
  [ -f "$bin" ] && [ ! -L "$bin" ] || return 0
  local deps
  deps="$(otool -L "$bin" 2>/dev/null | awk '/^\t/ {print $1}' | grep -E '^(/opt/homebrew/|/usr/local/)' | sort -u || true)"
  [ -n "$deps" ] || return 0
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    local base
    base="$(basename "$dep")"
    install_name_tool -change "$dep" "@rpath/$base" "$bin" 2>/dev/null || true
  done <<< "$deps"
}

for dylib in \
  "$IME_APP/Contents/Frameworks"/libllama*.dylib \
  "$IME_APP/Contents/Frameworks"/libggml*.dylib \
  "$IME_APP/Contents/Frameworks"/libomp.dylib \
  "$IME_APP/Contents/Frameworks/ggml-backends"/*.so \
  "$IME_APP/Contents/Frameworks/LocalInferenceCore.framework/Versions/A/LocalInferenceCore"; do
  [ -f "$dylib" ] && [ ! -L "$dylib" ] || continue
  base_name="$(basename "$dylib")"
  case "$base_name" in
    *.dylib|*.so)
      install_name_tool -id "@rpath/$base_name" "$dylib" 2>/dev/null || true
      ;;
  esac
  rewrite_homebrew_refs "$dylib"
done

# 确保 libggml-metal.so 等插件加载时能通过 @loader_path/.. 找到 Contents/Frameworks 里的 libggml/libomp
for plugin in "$IME_APP/Contents/Frameworks/ggml-backends"/*.so; do
  [ -f "$plugin" ] || continue
  install_name_tool -add_rpath "@loader_path/.." "$plugin" 2>/dev/null || true
done

# 规范化所有动态库权限为 0755（避免 Homebrew 拷贝过来的 0644 权限）
find "$IME_APP/Contents/Frameworks" -type f \( -name "*.dylib" -o -name "*.so" \) -exec chmod 0755 {} +

# 剥离所有二进制中的开发机绝对 LC_RPATH（/opt/homebrew、/usr/local、/Users），
# 防止跨机信息泄漏以及本机 Homebrew 升级时抢占 App 内嵌动态库导致 ABI 崩溃
strip_dev_rpaths() {
  local bin="$1"
  [ -f "$bin" ] && [ ! -L "$bin" ] || return 0
  local rpaths
  rpaths="$(otool -l "$bin" 2>/dev/null | awk '/LC_RPATH/{f=1} f && /path /{print $2; f=0}' | grep -E '^(/opt/homebrew|/usr/local|/Users)' | sort -u || true)"
  [ -n "$rpaths" ] || return 0
  while IFS= read -r rp; do
    [ -n "$rp" ] || continue
    install_name_tool -delete_rpath "$rp" "$bin" 2>/dev/null || true
  done <<< "$rpaths"
}

while IFS= read -r -d '' macho; do
  if file "$macho" | grep -q "Mach-O"; then
    strip_dev_rpaths "$macho"
  fi
done < <(find "$IME_APP" "$SETUP_HELPER" -type f \( -perm +111 -o -name "*.dylib" -o -name "*.so" -o -path "*.framework/*" \) -print0)

# 自包含防泄漏硬校验：确保所有 Mach-O 二进制 0 外部绝对依赖、0 开发机 LC_RPATH
# 注意：universal fat 二进制的 otool -L 会为每个架构打印头部路径，仅匹配 \t 缩进的依赖与 install_id 行
VERIFY_LEAKS=0
while IFS= read -r -d '' macho; do
  if file "$macho" | grep -q "Mach-O"; then
    bad_deps="$(otool -L "$macho" 2>/dev/null | awk '/^\t/ {print $1}' | grep -E '^(/opt/homebrew|/usr/local|/Users)' | sort -u || true)"
    bad_rpaths="$(otool -l "$macho" 2>/dev/null | awk '/LC_RPATH/{f=1} f && /path /{print $2; f=0}' | grep -E '^(/opt/homebrew|/usr/local|/Users)' | sort -u || true)"
    if [ -n "$bad_deps" ] || [ -n "$bad_rpaths" ]; then
      printf 'ERROR: Non-portable reference in %s\n' "$macho" >&2
      [ -n "$bad_deps" ] && printf '  dylib: %s\n' "$bad_deps" >&2
      [ -n "$bad_rpaths" ] && printf '  rpath: %s\n' "$bad_rpaths" >&2
      VERIFY_LEAKS=1
    fi
  fi
done < <(find "$IME_APP" "$SETUP_HELPER" -type f \( -perm +111 -o -name "*.dylib" -o -name "*.so" -o -path "*.framework/*" \) -print0)
if [ "$VERIFY_LEAKS" -ne 0 ]; then
  printf 'Aborting packaging due to leaked local paths.\n' >&2
  exit 1
fi

rsync -a --delete "$ROOT_DIR/Resources/RimeData/" "$IME_APP/Contents/Resources/RimeData/"
if [ -d "$ROOT_DIR/Resources/Lexicon" ]; then
  mkdir -p "$IME_APP/Contents/Resources/Lexicon"
  rsync -a --delete "$ROOT_DIR/Resources/Lexicon/" "$IME_APP/Contents/Resources/Lexicon/"
fi

# 将控制中心/自卸载器内嵌至输入法包中，供状态栏菜单随时唤起
codesign --force --deep --sign "$SIGN_IDENTITY" "$SETUP_HELPER"
cp -R "$SETUP_HELPER" "$IME_APP/Contents/Helpers/SmartPinyinSetup.app"
codesign --force --deep --sign "$SIGN_IDENTITY" "$IME_APP"
codesign --verify --deep --strict "$IME_APP"

SUFFIX=""
if [ "$BUNDLE_MODELS" -eq 0 ]; then
  SUFFIX="-lite"
fi

# 4. 构建 DMG（内含图形化 4 步引导安装器 Install SmartPinyin.app）
if [ "$FORMAT" = "dmg" ] || [ "$FORMAT" = "all" ]; then
  printf '==> [4/6] Packaging DMG installer\n'
  DMG_STAGE="$STAGE_DIR/dmg-root"
  mkdir -p "$DMG_STAGE"

  INSTALLER_APP="$DMG_STAGE/Install SmartPinyin.app"
  cp -R "$SETUP_HELPER" "$INSTALLER_APP"
  mkdir -p "$INSTALLER_APP/Contents/Resources/Payload"
  cp -R "$IME_APP" "$INSTALLER_APP/Contents/Resources/Payload/SmartPinyin.app"

  if [ "$BUNDLE_MODELS" -eq 1 ] && [ -d "$ROOT_DIR/Models" ]; then
    mkdir -p "$INSTALLER_APP/Contents/Resources/Models"
    cp -L "$ROOT_DIR/Models"/*.gguf "$INSTALLER_APP/Contents/Resources/Models/" 2>/dev/null || true
  fi

  codesign --force --deep --sign "$SIGN_IDENTITY" "$INSTALLER_APP"
  codesign --verify --deep --strict "$INSTALLER_APP"

  cat > "$DMG_STAGE/使用与卸载说明.txt" <<'TXT'
SmartPinyin macOS 原生智能输入法
==================================

【安装步骤】
1. 双击「Install SmartPinyin.app」打开图形化安装向导；
2. 推荐选择系统级安装（/Library/Input Methods/，确保系统设置完整显示名称与图标，覆盖升级自动保留辅助功能权限），也支持免管理员密码安装至当前用户目录；
3. 按向导完成系统输入源开通、可选辅助功能权限体检、本地小模型检测/导入/下载与现场试打验收。

【核心功能与快捷键】
- 短按 Shift          ：中文拼音 / 英文直出快速切换
- 大写 / 驼峰 / 下划线 ：中英混输快车道（如 React / user_id 免切直出）；Shift+空格输英文短句
- 智能自动纠错与模糊音 ：自动纠偏错键/漏键/连键/倒序（如 shaighai→上海）及前后鼻音模糊
- 诗词/成语与场景适配 ：候选栏自动标注「诗」「成」微胶囊，0ms 智能感知游戏/数学/计算机/美术/科学场景并动态提权
- 开源词库热更新管理  ：打开 SmartPinyin Setup →「词库与场景」一键更新万象词库、按需装扩展词库或导入自定义词表
- 右 Option 单击/双击 ：空态 0ms 开关翻译模式 / 弹出 1–6 语种直选胶囊条（拼写时 Tab 切本句译文、⌃⌥T 一键全局关翻译）
- Shift + Return      ：普通中文模式下临时将当前句一键译成英文上屏
- /ja  /en  /ko  /t   ：行内快速切语种 / 开关翻译 / /code 切标点
- 1 / 2 / 3 或 Tab    ：单手直选句末智能联想续写（继续打首字母 0ms 融入候选栏首位）

【彻底卸载自己】
随时可通过以下任意入口零残留卸载：
1. 点击右上角状态栏 SmartPinyin 输入法图标 ->「卸载 SmartPinyin…」
2. 打开「SmartPinyin Setup.app」-> 顶部切换到「卸载自己」
3. 或再次打开本 DMG 内的「Install SmartPinyin.app」-> 切换到「卸载自己」
TXT

  DMG_OUT="$DIST_DIR/SmartPinyin-${VERSION}-${ARCH}${SUFFIX}.dmg"
  rm -f "$DMG_OUT"
  hdiutil create \
    -volname "SmartPinyin ${VERSION}" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format ULFO \
    "$DMG_OUT" >/dev/null
  printf '    Created DMG: %s (%s)\n' "$DMG_OUT" "$(du -sh "$DMG_OUT" | awk '{print $1}')"
  # 及时注销并清理 DMG 临时 staging（内置模型时可立即释放 ~1.8GB 磁盘空间，保障 CI Runner 余量）
  LSREG_TMP="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [ -x "$LSREG_TMP" ] && [ -e "$INSTALLER_APP" ] && "$LSREG_TMP" -u "$INSTALLER_APP" >/dev/null 2>&1 || true
  rm -rf "$DMG_STAGE"
fi

# 5. 构建标准 macOS PKG（关闭 BundleIsRelocatable + postinstall 自动拉起引导页）
if [ "$FORMAT" = "pkg" ] || [ "$FORMAT" = "all" ]; then
  printf '==> [5/6] Packaging standard macOS PKG installer\n'
  PKG_ROOT="$STAGE_DIR/pkg-root"
  PKG_SCRIPTS="$STAGE_DIR/pkg-scripts"
  PKG_RES="$STAGE_DIR/pkg-resources"
  mkdir -p "$PKG_ROOT/Library/Input Methods" "$PKG_ROOT/Applications" "$PKG_SCRIPTS" "$PKG_RES"

  cp -R "$IME_APP" "$PKG_ROOT/Library/Input Methods/SmartPinyin.app"
  cp -R "$SETUP_HELPER" "$PKG_ROOT/Applications/SmartPinyin Setup.app"
  if [ "$BUNDLE_MODELS" -eq 1 ] && [ -d "$ROOT_DIR/Models" ]; then
    mkdir -p "$PKG_ROOT/Applications/SmartPinyin Setup.app/Contents/Resources/Models"
    cp -L "$ROOT_DIR/Models"/*.gguf "$PKG_ROOT/Applications/SmartPinyin Setup.app/Contents/Resources/Models/" 2>/dev/null || true
    codesign --force --deep --sign "$SIGN_IDENTITY" "$PKG_ROOT/Applications/SmartPinyin Setup.app"
    codesign --verify --deep --strict "$PKG_ROOT/Applications/SmartPinyin Setup.app"
  fi

  cp "$ROOT_DIR/Scripts/pkg/postinstall" "$PKG_SCRIPTS/postinstall"
  chmod 0755 "$PKG_SCRIPTS/postinstall"

  # 生成并强制关闭 BundleIsRelocatable，防止 Installer 误覆盖开发构建目录
  COMPONENT_PLIST="$STAGE_DIR/components.plist"
  pkgbuild --analyze --root "$PKG_ROOT" "$COMPONENT_PLIST" >/dev/null
  python3 - "$COMPONENT_PLIST" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    items = plistlib.load(f)
for item in items:
    item["BundleIsRelocatable"] = False
with open(path, "wb") as f:
    plistlib.dump(items, f)
PY

  COMPONENT_PKG="$STAGE_DIR/SmartPinyin-component.pkg"
  pkgbuild \
    --root "$PKG_ROOT" \
    --component-plist "$COMPONENT_PLIST" \
    --scripts "$PKG_SCRIPTS" \
    --identifier "com.smartpinyin.inputmethod.SmartPinyin.pkg" \
    --version "$VERSION" \
    --install-location "/" \
    "$COMPONENT_PKG" >/dev/null

  cat > "$PKG_RES/Welcome.html" <<HTML
<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="UTF-8"><style>
body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 13px; line-height: 1.6; color: #222; }
h1 { font-size: 18px; margin-bottom: 8px; }
ul { padding-left: 18px; }
</style></head><body>
<h1>欢迎安装 SmartPinyin ${VERSION}</h1>
<p>SmartPinyin 是一款专为 Apple Silicon 设计的 macOS 原生智能输入法：</p>
<ul>
  <li><b>L1 极速拼音底座与自动纠错</b>：基于 librime 与万象词库/语法模型，全拼/简拼/整句毫秒级响应，支持快打自动纠偏与可配置模糊音；</li>
  <li><b>诗词/成语标识与智能场景词库</b>：离线精准标注「诗」「成」微胶囊，0ms 自动识别游戏/数学/计算机/美术/科学等场景动态调权，支持开源词库热更新与自定义词表导入；</li>
  <li><b>本地小模型增强（&lt; 2GB 内存）</b>：100% 离线运行语境重排、句末联想续写与中→英/多语种实时翻译；</li>
  <li><b>一键彻底自卸载</b>：随时通过输入法菜单或 SmartPinyin Setup 应用零残留卸载。</li>
</ul>
<p>安装完成后将自动打开图形化引导页，协助您启用输入源并检查权限与本地模型。</p>
</body></html>
HTML

  DIST_XML="$STAGE_DIR/distribution.xml"
  cat > "$DIST_XML" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>SmartPinyin ${VERSION}</title>
    <welcome file="Welcome.html" mime-type="text/html"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <choices-outline>
        <line choice="default">
            <line choice="com.smartpinyin.inputmethod.SmartPinyin.pkg"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="com.smartpinyin.inputmethod.SmartPinyin.pkg" visible="false">
        <pkg-ref id="com.smartpinyin.inputmethod.SmartPinyin.pkg"/>
    </choice>
    <pkg-ref id="com.smartpinyin.inputmethod.SmartPinyin.pkg" version="${VERSION}" onConclusion="none">SmartPinyin-component.pkg</pkg-ref>
</installer-gui-script>
XML

  PKG_OUT="$DIST_DIR/SmartPinyin-${VERSION}-${ARCH}${SUFFIX}.pkg"
  rm -f "$PKG_OUT"
  productbuild \
    --distribution "$DIST_XML" \
    --resources "$PKG_RES" \
    --package-path "$STAGE_DIR" \
    "$PKG_OUT" >/dev/null
  printf '    Created PKG: %s (%s)\n' "$PKG_OUT" "$(du -sh "$PKG_OUT" | awk '{print $1}')"
  LSREG_TMP="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [ -x "$LSREG_TMP" ]; then
    [ -e "$PKG_ROOT/Library/Input Methods/SmartPinyin.app" ] && "$LSREG_TMP" -u "$PKG_ROOT/Library/Input Methods/SmartPinyin.app" >/dev/null 2>&1 || true
    [ -e "$PKG_ROOT/Applications/SmartPinyin Setup.app" ] && "$LSREG_TMP" -u "$PKG_ROOT/Applications/SmartPinyin Setup.app" >/dev/null 2>&1 || true
  fi
  rm -rf "$PKG_ROOT" "$COMPONENT_PKG"
fi

# 注销构建目录中的临时 App 副本，防止污染 LaunchServices 干扰 imklaunchagent 查找已安装的 SmartPinyin.app
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREG" ]; then
  for tmp_app in \
    "$BUILD_DIR/DerivedData/Build/Products/Release/SmartPinyin.app" \
    "$BUILD_DIR/DerivedData/Build/Products/Release/SmartPinyinSetup.app" \
    "$STAGE_DIR/SmartPinyin.app" \
    "$STAGE_DIR/SmartPinyinSetup.app" \
    "$STAGE_DIR/pkg-root/Library/Input Methods/SmartPinyin.app" \
    "$STAGE_DIR/pkg-root/Applications/SmartPinyin Setup.app" \
    "$STAGE_DIR/dmg-root/Install SmartPinyin.app"; do
    [ -e "$tmp_app" ] && "$LSREG" -u "$tmp_app" >/dev/null 2>&1 || true
  done
fi

printf '==> [6/6] Packaging summary (SHA-256)\n'
for f in "$DIST_DIR"/SmartPinyin-"${VERSION}"-"${ARCH}"*; do
  [ -f "$f" ] || continue
  printf '  %s  (%s)\n' "$f" "$(du -sh "$f" | awk '{print $1}')"
  shasum -a 256 "$f"
done
