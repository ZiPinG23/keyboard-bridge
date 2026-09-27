#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/dist/KeyboardBridge.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/KeyboardBridge "$APP/Contents/MacOS/KeyboardBridge"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.keyboardbridge.mac</string>
<key>CFBundleName</key><string>KeyboardBridge</string>
<key>CFBundleExecutable</key><string>KeyboardBridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>发现并连接你的键盘桥接收器，通过蓝牙转发键盘输入。</string>
<key>NSLocalNetworkUsageDescription</key><string>连接你配对的键盘接收器并发送键盘输入。</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
