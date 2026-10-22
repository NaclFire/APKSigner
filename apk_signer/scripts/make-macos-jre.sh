#!/bin/sh
# 生成 macOS 专用的内置精简 JRE（assets/signer-macos/jre）。
#
# 背景：assets/signer/jre 是从 Windows JDK 17 jlink 出来的 Windows 二进制，
# macOS 无法使用。此脚本用 Adoptium Temurin JDK 17（对应本机构型）现场生成，
# 模块清单与 Windows 版完全一致（取自 assets/signer/jre/release 的 MODULES 行），
# 并像 Windows 版一样手工补入 jlink 不带的 keytool。
#
# 幂等：assets/signer-macos/jre/bin/java 已存在时直接退出。
# 由 Xcode Runner 的 "Copy Signer Runtime" Run Script 构建阶段自动调用。

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
DEST="$ROOT_DIR/assets/signer-macos"
JRE="$DEST/jre"

MODULES="java.base,java.logging,java.security.sasl,java.naming,java.security.jgss,java.smartcardio,java.xml,jdk.security.auth,jdk.unsupported"

if [ -x "$JRE/bin/java" ]; then
  echo "[make-macos-jre] 已存在，跳过：$JRE"
  exit 0
fi

case "$(uname -m)" in
  arm64)  ADOPT_ARCH=aarch64 ;;
  x86_64) ADOPT_ARCH=x64 ;;
  *) echo "[make-macos-jre] 未知架构 $(uname -m)" >&2; exit 1 ;;
esac

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
JAR="$TMP/jdk17.tar.gz"

echo "[make-macos-jre] 下载 Temurin JDK 17 (mac/$ADOPT_ARCH) ..."
URL="https://api.adoptium.net/v3/binary/latest/17/ga/mac/${ADOPT_ARCH}/jdk/hotspot/normal/eclipse"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "$JAR" "$URL"
else
  wget -q -O "$JAR" "$URL"
fi

echo "[make-macos-jre] 解压并生成 JRE ..."
tar -xzf "$JAR" -C "$TMP"
JDK_HOME=$(find "$TMP" -maxdepth 1 -type d -name "jdk-17*" | head -n 1)
if [ -z "$JDK_HOME" ] || [ ! -x "$JDK_HOME/bin/jlink" ]; then
  echo "[make-macos-jre] 未找到 jlink（$JDK_HOME）" >&2
  exit 1
fi
JDK_HOME=$(cd "$JDK_HOME" && pwd -P)

rm -rf "$JRE"
"$JDK_HOME/bin/jlink" \
  --no-header-files --no-man-pages --strip-debug \
  --add-modules "$MODULES" \
  --output "$JRE"

# jlink 不带 keytool，手工补入（与 Windows 版做法一致）
cp "$JDK_HOME/bin/keytool" "$JRE/bin/keytool"
chmod +x "$JRE/bin/keytool"

# 与 apksigner.jar 放在一起，供构建阶段整体拷贝进 .app
mkdir -p "$DEST"
cp "$ROOT_DIR/assets/signer/apksigner.jar" "$DEST/apksigner.jar"

echo "[make-macos-jre] 完成：$JRE"
