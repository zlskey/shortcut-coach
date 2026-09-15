#!/bin/bash
# Builds ShortcutCoach.app into ./build and code-signs it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ShortcutCoach.app"
# Ad-hoc by default (no keychain needed). Set SIGN_IDENTITY to your Apple Development
# identity to keep the Accessibility permission across rebuilds.
IDENTITY="${SIGN_IDENTITY:--}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target arm64-apple-macos13.0 \
    -framework AppKit -framework ApplicationServices -framework CoreAudio \
    -framework AudioToolbox -framework ServiceManagement \
    -o "$APP/Contents/MacOS/ShortcutCoach" \
    Sources/*.swift

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --identifier com.shortcutcoach.app --sign "$IDENTITY" "$APP"

echo "Built $APP  (signed with: $IDENTITY)"
