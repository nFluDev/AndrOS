#!/bin/bash
# AndrOS ses surucusunu derler ve /Library/Audio/Plug-Ins/HAL altina kurar.
#
# Neden buraya: macOS 12.3'ten beri kullanicidan yuklenen ses
# eklentileri icin desteklenen tek yol AudioServerPlugIn ve coreaudiod
# yalnizca bu klasoru tariyor. Kurulum root gerektiriyor.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/mac/AudioDriver"
BUILD="$ROOT/build/AndrOSAudio.driver"
DEST="/Library/Audio/Plug-Ins/HAL/AndrOSAudio.driver"

rm -rf "$BUILD"
mkdir -p "$BUILD/Contents/MacOS"
cp "$SRC/Info.plist" "$BUILD/Contents/Info.plist"

clang -bundle -O2 -fmodules \
      -mmacosx-version-min=13.0 \
      -framework CoreFoundation -framework CoreAudio \
      -I "$SRC" \
      -o "$BUILD/Contents/MacOS/AndrOSAudio" \
      "$SRC/AndrOSAudio.c"

# Imzasiz paket coreaudiod tarafindan reddedilir; kendinden imzali yeterli.
codesign --force --sign - "$BUILD"

echo "Derlendi: $BUILD"
if [ "$1" = "install" ]; then
  sudo rm -rf "$DEST"
  sudo mkdir -p "$(dirname "$DEST")"
  sudo cp -R "$BUILD" "$DEST"
  sudo chown -R root:wheel "$DEST"
  sudo killall coreaudiod 2>/dev/null || true
  echo "Kuruldu: $DEST (coreaudiod yeniden baslatildi)"
fi
