#!/bin/bash
# AndrOS'u /Applications'a kurar ve LaunchServices kaydini tazeler.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/tools/bundle.sh"

pkill -f "AndrOS.app/Contents/MacOS/AndrOS" 2>/dev/null || true
sleep 1
rm -rf /Applications/AndrOS.app
cp -R "$ROOT/build/AndrOS.app" /Applications/AndrOS.app

# build/ kopyasinin kaydini SIL, yoksa Launchpad/Spotlight iki AndrOS gosterir
# ve yanlis olani acabilir. Sadece /Applications kayitli kalsin.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -u "$ROOT/build/AndrOS.app" 2>/dev/null || true
"$LSREG" -f /Applications/AndrOS.app  2>/dev/null || true

echo "Kuruldu: /Applications/AndrOS.app"
