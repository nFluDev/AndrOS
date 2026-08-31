#!/bin/bash
# AndrOS sanal kamera uzantisini derler ve uygulama paketine koyar.
#
# Sistem uzantilari uygulamanin ICINDEN kuruluyor
# (Contents/Library/SystemExtensions) ve uygulama /Applications altinda
# olmak zorunda. Imzasiz surumde `systemextensionsctl developer on`
# gerekiyor — acik kaynak surumu icin README'de yaziyor.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/mac/CameraExtension"
OUT="$ROOT/build/AndrOSCamera.systemextension"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp "$SRC/Info.plist" "$OUT/Contents/Info.plist"

swiftc -O -parse-as-library \
    -target arm64-apple-macos13.0 -target x86_64-apple-macos13.0 2>/dev/null || true

# Tek mimari: bu makinenin mimarisi. Cok mimarili paket icin ayri ayri
# derleyip `lipo` ile birlestirmek gerekiyor (README).
ARCH="$(uname -m)"
clang -c "$SRC/CameraShim.c" -I "$SRC/include" -O2 -o "$ROOT/build/camshim.o"
swiftc -O \
    -target "${ARCH}-apple-macos13.0" \
    -import-objc-header "$SRC/include/AndrOSCameraShim.h" \
    -I "$SRC/include" \
    -framework CoreMediaIO -framework CoreMedia -framework CoreVideo \
    -framework Foundation \
    "$ROOT/build/camshim.o" \
    "$SRC/Provider.swift" "$SRC/main.swift" \
    -o "$OUT/Contents/MacOS/AndrOSCamera"

codesign --force --sign - --entitlements "$SRC/Extension.entitlements" "$OUT"
echo "Derlendi: $OUT"
