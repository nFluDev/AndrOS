#!/bin/bash
# AndrOS.app paketini olusturur. LSUIElement=1 -> dock'ta HIC gorunmez,
# yalniz menu cubugunda tek simge birakir.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/AndrOS.app"

swift build -c release --package-path "$ROOT/mac"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/mac/.build/release/AndrOSApp" "$APP/Contents/MacOS/AndrOS"
# Sunucu jar'ini paketin icine goem: sistemdeki scrcpy kurulumuna bagimli kalma.
cp "$ROOT/vendor/scrcpy-server" "$APP/Contents/Resources/scrcpy-server"
cp "$ROOT/vendor/VERSION"       "$APP/Contents/Resources/VERSION"
cp "$ROOT/build/AndrOS.icns"    "$APP/Contents/Resources/AndrOS.icns"

# Ses surucusu PAKETIN ICINDE geliyor: uygulamayi indiren herkes
# kaynaktan derlemeden kurabilsin (kurulumu uygulama kendi yapiyor,
# macOS'un parola penceresiyle).
"$ROOT/tools/audio-driver.sh" >/dev/null
cp -R "$ROOT/build/AndrOSAudio.driver" "$APP/Contents/Resources/AndrOSAudio.driver"

# Sanal kamera SISTEM UZANTISI. Uygulamanin icinden kuruluyor; macOS
# yalnizca Contents/Library/SystemExtensions altindakini kabul ediyor
# ve uygulamanin /Applications altinda olmasini sart kosuyor.
"$ROOT/tools/camera-extension.sh" >/dev/null
mkdir -p "$APP/Contents/Library/SystemExtensions"
cp -R "$ROOT/build/AndrOSCamera.systemextension" \
      "$APP/Contents/Library/SystemExtensions/dev.naer.andros.camera.systemextension"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>AndrOS</string>
    <key>CFBundleDisplayName</key>       <string>AndrOS</string>
    <key>CFBundleIdentifier</key>        <string>dev.naer.andros</string>
    <key>CFBundleExecutable</key>        <string>AndrOS</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>CFBundleIconFile</key>          <string>AndrOS</string>
</dict>
</plist>
PLIST

# Once uzanti, sonra uygulama: ic paketler disaridan once imzalanmali.
codesign --force --sign - --entitlements "$ROOT/mac/CameraExtension/Extension.entitlements" \
    "$APP/Contents/Library/SystemExtensions/dev.naer.andros.camera.systemextension" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/Resources/AndrOSAudio.driver" 2>/dev/null || true
codesign --force --sign - --entitlements "$ROOT/mac/CameraExtension/App.entitlements" \
    "$APP" 2>/dev/null || echo "  (imzasiz, sorun degil)"
echo "Hazir: $APP"
