#!/bin/bash
# Build the BiliLyu macOS app bundle.
#
#   ./macapp/build.sh              build the .app into ./dist
#   ./macapp/build.sh selftest     build, then run the in-app engine self test
#   ./macapp/build.sh install      build, then copy the .app into /Applications
#
set -euo pipefail

MACAPP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$MACAPP/.." && pwd)"
BUILD="$MACAPP/build"
DIST="$ROOT/dist"

APP_NAME="BiliLyu 视频转换器"
EXEC_NAME="BiliLyu"
BUNDLE_ID="com.bililyu.converter"
VERSION="1.0.0"
MIN_MACOS="13.0"

APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

# 图标：装有 Pillow 就现场重新生成，没有就直接用仓库里预置好的 icns，
# 这样 clone 下来不装任何 Python 依赖也能构建。可用 PYTHON= 指定解释器。
PRESET_ICON="$MACAPP/icon/AppIcon.icns"
if [ -z "${PYTHON:-}" ]; then
  for candidate in "$(command -v python3 2>/dev/null)" \
                   /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -c "import PIL" >/dev/null 2>&1; then
      PYTHON="$candidate"; break
    fi
  done
fi
HAVE_PIL=no
if [ -n "${PYTHON:-}" ] && "$PYTHON" -c "import PIL" >/dev/null 2>&1; then HAVE_PIL=yes; fi
if [ "$HAVE_PIL" = no ] && [ ! -f "$PRESET_ICON" ]; then
  echo "!! 既没有 Pillow 也没有预置图标 $PRESET_ICON" >&2
  echo "   装一个: pip3 install Pillow  ，或 PYTHON=/path/to/python3 ./macapp/build.sh" >&2
  exit 1
fi

echo "==> 清理"
rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD" "$CONTENTS/MacOS" "$CONTENTS/Resources"

FFMPEG_SRC="${FFMPEG_SRC:-$MACAPP/vendor/ffmpeg}"
if [ ! -x "$FFMPEG_SRC" ]; then
  echo "!! 找不到内置 ffmpeg: $FFMPEG_SRC" >&2
  echo "   下载: curl -L -o macapp/vendor/ffmpeg \\" >&2
  echo "     https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64" >&2
  exit 1
fi

echo "==> 编译 Swift 宿主程序"
# The default module cache lives under /var/folders, which the build sandbox may
# not allow writing; keep it next to the build output instead.
mkdir -p "$BUILD/modulecache"
export CLANG_MODULE_CACHE_PATH="$BUILD/modulecache"
swiftc -O \
  -module-cache-path "$BUILD/modulecache" \
  -target "arm64-apple-macos$MIN_MACOS" \
  -framework AppKit -framework WebKit \
  -o "$BUILD/$EXEC_NAME" \
  "$MACAPP/src/main.swift" \
  "$MACAPP/src/Native.swift"

if [ "$HAVE_PIL" = yes ]; then
  echo "==> 生成图标 (Pillow)"
  "$PYTHON" "$MACAPP/icon/make_icon.py" "$BUILD" >/dev/null
  cp "$BUILD/AppIcon.icns" "$PRESET_ICON"          # 顺手刷新仓库里预置的那份
else
  echo "==> 使用预置图标（本机没装 Pillow）"
fi
cp "$PRESET_ICON" "$CONTENTS/Resources/AppIcon.icns"

echo "==> 打包网页资源"
WEB="$CONTENTS/Resources/web"
mkdir -p "$WEB/vendor"
cp "$ROOT/index.html" "$WEB/index.html"
cp "$ROOT/vendor/ffmpeg.min.js" "$ROOT/vendor/ffmpeg-core.js" \
   "$ROOT/vendor/ffmpeg-core.wasm" "$ROOT/vendor/ffmpeg-core.worker.js" "$WEB/vendor/"

echo "==> 内置 ffmpeg"
mkdir -p "$CONTENTS/Resources/bin"
cp "$FFMPEG_SRC" "$CONTENTS/Resources/bin/ffmpeg"
chmod +x "$CONTENTS/Resources/bin/ffmpeg"
codesign --force --sign - --timestamp=none "$CONTENTS/Resources/bin/ffmpeg" 2>/dev/null || true

echo "==> 写入 Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key>
  <array><string>zh-Hans</string><string>en</string></array>
  <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSRequiresAquaSystemAppearance</key><false/>
  <key>NSHumanReadableCopyright</key><string>BiliLyu · 本地视频转换 · 全程不联网上传</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><false/>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
PLIST

# Real .lproj folders make WebKit report the matching navigator.language, so the
# page opens in Chinese on a Chinese system instead of falling back to English.
mkdir -p "$CONTENTS/Resources/zh-Hans.lproj" "$CONTENTS/Resources/en.lproj"
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp "$BUILD/$EXEC_NAME" "$CONTENTS/MacOS/$EXEC_NAME"

echo "==> 临时签名 (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP" >/dev/null 2>&1 \
  || codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "    签名校验通过"

SIZE="$(du -sh "$APP" | cut -f1)"
echo
echo "==> 完成: $APP  ($SIZE)"

case "${1:-build}" in
  selftest)
    echo
    echo "==> 运行自检 (ffmpeg.wasm 引擎 + 转换流程)"
    "$CONTENTS/MacOS/$EXEC_NAME" --selftest
    ;;
  install)
    echo
    echo "==> 安装到 /Applications"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "    已安装: /Applications/$APP_NAME.app"
    ;;
esac
