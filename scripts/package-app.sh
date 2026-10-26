#!/bin/bash
# 打包 Portside.app(工单 12:自用版,不签名公证,仅 ad-hoc 保证 Apple Silicon 可运行)。
# 用法:
#   scripts/package-app.sh             # 组装到 .build/Portside.app
#   scripts/package-app.sh --install   # 组装并安装:优先 /Applications,无权限回退 ~/Applications
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▸ swift build -c release"
swift build -c release

APP="$ROOT/.build/Portside.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/portside" "$APP/Contents/MacOS/portside"
cp "$ROOT/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Info.plist:无 LSUIElement——保持工单 10 的常规 Dock 形态(Dock 出现锚形应用图标)。
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Portside</string>
	<key>CFBundleDisplayName</key><string>Portside · 服务码头</string>
	<key>CFBundleIdentifier</key><string>app.portside.Portside</string>
	<key>CFBundleExecutable</key><string>portside</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
	<key>CFBundleVersion</key><string>1.0.0</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "▸ ad-hoc codesign"
codesign --force -s - "$APP"

if [[ "${1:-}" == "--zip" ]]; then
    # 发布包:ditto 保留签名与元数据,keepParent 让解压直接得到 Portside.app
    ZIP="$ROOT/.build/Portside-1.0.0.zip"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    echo "✅ 发布包:$ZIP"
elif [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications"
    if ! cp -R "$APP" "$DEST/" 2>/dev/null; then
        DEST="$HOME/Applications"
        mkdir -p "$DEST"
        cp -R "$APP" "$DEST/"
        echo "▸ /Applications 无写权限,回退 ~/Applications"
    fi
    # 通知 LaunchServices:Spotlight/Launchpad 尽快可见
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/Portside.app" 2>/dev/null || true
    echo "✅ 已安装:$DEST/Portside.app"
else
    echo "✅ 已组装:$APP(加 --install 装入应用程序)"
fi
