#!/bin/bash
# Android uygulamasini derler ve (cihaz varsa) yukler.
#
# Gradle ve Android SDK, AndrOS'un kendi destek klasorunde tutuluyor:
# sistem geneline bir sey kurulmuyor, silmek isteyince tek klasor.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/AndrOS"
GRADLE="$SUPPORT/tools/gradle-8.11.1/bin/gradle"
SDK="$SUPPORT/android-sdk"

[ -x "$GRADLE" ] || { echo "Gradle yok: $GRADLE"; exit 1; }
[ -d "$SDK" ]    || { echo "Android SDK yok: $SDK"; exit 1; }

cd "$ROOT/android"
"$GRADLE" --no-daemon "${1:-assembleDebug}"

APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
echo "APK: $APK ($(du -h "$APK" | cut -f1))"

if [ "$2" = "install" ]; then
  ADB="$SDK/platform-tools/adb"
  "$ADB" install -r "$APK"
  echo "Yuklendi."
fi
