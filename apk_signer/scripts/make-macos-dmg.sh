#!/bin/bash
# 构建 macOS 发布版并打包成 DMG 安装镜像。
#
# 用法（需已安装完整版 Xcode）：
#   ./scripts/make-macos-dmg.sh              # 构建 + 打包
#   SKIP_BUILD=1 ./scripts/make-macos-dmg.sh # 复用已有 .app，只重新打包
#   CODESIGN_IDENTITY="Developer ID Application: xxx" ./scripts/make-macos-dmg.sh
#
# 默认 ad-hoc 签名（"-"），可直接本机运行；没有开发者证书时别人下载后
# 需要右键「打开」或执行 `xattr -dr com.apple.quarantine /Applications/APK\ Signer.app`。
#
# 产物：dist/apk_signer-<版本>.dmg（x64）/ dist/apk_signer-<版本>-arm64.dmg（arm64）

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$ROOT_DIR"

# 若 Flutter 未加入 PATH，尝试常见安装位置（如 ~/development/flutter）
if ! command -v flutter >/dev/null 2>&1; then
  for d in "$HOME/development/flutter/bin" "/opt/homebrew/bin" "/usr/local/bin"; do
    if [ -x "$d/flutter" ]; then
      PATH="$d:$PATH"
      export PATH
      break
    fi
  done
fi
command -v flutter >/dev/null 2>&1 || {
  echo "[dmg] 未找到 flutter，请先安装 Flutter SDK 并加入 PATH" >&2
  exit 1
}

APP_NAME="apk_signer"
APP_DISPLAY_NAME="APK Signer"
APP="$ROOT_DIR/build/macos/Build/Products/Release/$APP_NAME.app"
DIST="$ROOT_DIR/dist"

VERSION=$(sed -n 's/^version:[[:space:]]*\([0-9][^+ ]*\).*/\1/p' pubspec.yaml | head -n 1)
[ -n "$VERSION" ] || VERSION="0.0.0"

case "$(uname -m)" in
  arm64)  ARCH="arm64"; ARCH_SUFFIX="-arm64" ;;
  x86_64) ARCH="x64";   ARCH_SUFFIX="" ;;
  *)      ARCH="$(uname -m)"; ARCH_SUFFIX="-$ARCH" ;;
esac

DMG="$DIST/${APP_NAME}-${VERSION}${ARCH_SUFFIX}.dmg"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "[dmg] flutter build macos --release"
  flutter pub get
  flutter build macos --release
fi

if [ ! -d "$APP" ]; then
  echo "[dmg] 未找到 $APP，请先执行 flutter build macos --release" >&2
  exit 1
fi

SIGN_ID="${CODESIGN_IDENTITY:--}"
echo "[dmg] 签名身份：$SIGN_ID"

# 清掉本地自检/签名测试留下的日志，避免打进安装包
rm -f "$APP/Contents/MacOS/selftest.log" "$APP/Contents/MacOS/signtest.log"

# 内置 JRE 里的 java/keytool/*.dylib 是 Xcode 构建后拷贝进去的，不属于
# Xcode 正常签名范围，需要逐个签名，否则在其他 Mac 上会被 Gatekeeper 拒绝。
if [ -d "$APP/Contents/Resources/signer" ]; then
  echo "[dmg] 签名内置 JRE 二进制…"
  while IFS= read -r -d '' f; do
    if file "$f" | grep -q "Mach-O"; then
      codesign --force --sign "$SIGN_ID" "$f" >/dev/null 2>&1 || {
        echo "[dmg] 签名失败：$f" >&2
        exit 1
      }
    fi
  done < <(find "$APP/Contents/Resources/signer" -type f -print0)
fi

echo "[dmg] 重新签名 app bundle…"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "[dmg] 签名校验通过"

echo "[dmg] 制作 DMG…"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/apk_signer_dmg.XXXXXX")
STAGE="$WORK/stage"
mkdir -p "$STAGE"
cleanup() {
  hdiutil detach "/Volumes/$APP_DISPLAY_NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$DIST"
rm -f "$DMG"

# 与 electron-builder 默认 DMG 一样的拖拽安装窗口：固定窗口大小、图标位置、
# Applications 快捷方式。
#   1) 优先用 dmgbuild（直接写 .DS_Store，不依赖 Finder 自动化权限）
#   2) 没有 dmgbuild 时退回 Finder + AppleScript（需自动化授权）
#   3) 都不可用 / DMG_LAYOUT=0 时生成普通 DMG
DMG_CREATED=0
if [ "${DMG_LAYOUT:-1}" = "1" ]; then
  DMGBUILD_BIN="${DMGBUILD:-}"
  if [ -z "$DMGBUILD_BIN" ]; then
    DMGBUILD_BIN=$(command -v dmgbuild || true)
  fi
  if [ -z "$DMGBUILD_BIN" ] && [ -x "$HOME/.local/share/apk-signer/dmgvenv/bin/dmgbuild" ]; then
    DMGBUILD_BIN="$HOME/.local/share/apk-signer/dmgvenv/bin/dmgbuild"
  fi

  if [ -n "$DMGBUILD_BIN" ] && [ -x "$DMGBUILD_BIN" ]; then
    echo "[dmg] 用 dmgbuild 生成安装窗口布局…"
    cat > "$WORK/dmgbuild.py" <<EOF
files = ['$STAGE/$APP_NAME.app']
symlinks = {'Applications': '/Applications'}
icon_locations = {'$APP_NAME.app': (150, 195), 'Applications': (390, 195)}
window_rect = ((100, 100), (540, 380))
default_view = 'icon-view'
icon_size = 96
text_size = 13
format = 'UDZO'
compression_level = 9
EOF
    if "$DMGBUILD_BIN" -s "$WORK/dmgbuild.py" "$APP_DISPLAY_NAME" "$DMG"; then
      DMG_CREATED=1
    else
      echo "[dmg] 警告：dmgbuild 失败，尝试 Finder 布局" >&2
      rm -f "$DMG"
    fi
  fi

  if [ "$DMG_CREATED" != "1" ] && command -v osascript >/dev/null 2>&1; then
    RW="$WORK/rw.dmg"
    hdiutil create -volname "$APP_DISPLAY_NAME" -srcfolder "$STAGE" \
      -fs HFS+ -format UDRW -ov "$RW" >/dev/null
    hdiutil resize -size +20m "$RW" >/dev/null 2>&1 || true
    hdiutil detach "/Volumes/$APP_DISPLAY_NAME" >/dev/null 2>&1 || true
    if hdiutil attach "$RW" -mountpoint "/Volumes/$APP_DISPLAY_NAME" \
        -nobrowse -noautoopen >/dev/null; then
      sleep 1
      APPLESCRIPT="$WORK/layout.applescript"
      cat > "$APPLESCRIPT" <<'APPLESCRIPT_EOF'
on run argv
  set volName to item 1 of argv
  set appName to item 2 of argv
  tell application "Finder"
    tell disk (volName as text)
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {100, 100, 640, 480}
      set vo to the icon view options of container window
      set arrangement of vo to not arranged
      set icon size of vo to 96
      set text size of vo to 13
      set position of item (appName as text) of container window to {150, 195}
      set position of item "Applications" of container window to {390, 195}
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
APPLESCRIPT_EOF
      if ! perl -e 'alarm shift; exec @ARGV' 60 osascript "$APPLESCRIPT" \
          "$APP_DISPLAY_NAME" "$APP_NAME.app"; then
        echo "[dmg] 警告：未能设置 DMG 窗口布局（Finder 自动化权限？），继续打包"
      fi
      sync
      hdiutil detach "/Volumes/$APP_DISPLAY_NAME" >/dev/null 2>&1 \
        || hdiutil detach "/Volumes/$APP_DISPLAY_NAME" -force >/dev/null 2>&1 || true
    fi
    hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
    DMG_CREATED=1
  fi
fi

if [ "$DMG_CREATED" != "1" ]; then
  hdiutil create -volname "$APP_DISPLAY_NAME" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
fi

hdiutil verify "$DMG" >/dev/null
echo "[dmg] 完成：$DMG"
ls -lh "$DMG"
