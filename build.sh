#!/bin/bash
# Builds ShortcutCoach.app into ./build and code-signs it.
#
#   ./build.sh                                  arm64, ad-hoc signed
#   ARCHS="arm64 x86_64" ./build.sh             universal
#   VERSION=1.2 ./build.sh                      stamp a version into Info.plist
#   SIGN_IDENTITY="Apple Development: …" ./build.sh
#
# Signing matters more than it looks: macOS ties the Accessibility permission to the
# signature, so an ad-hoc build has to be re-approved after every rebuild, while a build
# signed with a stable identity keeps the permission across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ShortcutCoach.app"
BIN="$APP/Contents/MacOS/ShortcutCoach"
ARCHS="${ARCHS:-arm64}"
IDENTITY="${SIGN_IDENTITY:--}"
DEPLOYMENT_TARGET=13.0

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

slices=()
for arch in $ARCHS; do
    echo "Compiling ${arch}..."   # keep it ASCII: bash 3.2 folds a following multibyte char into the name
    swiftc -O -target "$arch-apple-macos$DEPLOYMENT_TARGET" \
        -framework AppKit -framework ApplicationServices -framework CoreAudio \
        -framework AudioToolbox -framework ServiceManagement \
        -o "build/ShortcutCoach-$arch" \
        Sources/*.swift
    slices+=("build/ShortcutCoach-$arch")
done

if [ "${#slices[@]}" -gt 1 ]; then
    lipo -create -output "$BIN" "${slices[@]}"
else
    cp "${slices[0]}" "$BIN"
fi
rm -f "${slices[@]}"

cp Info.plist "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

codesign --force --options runtime --identifier com.shortcutcoach.app --sign "$IDENTITY" "$APP"

echo "Built $APP  ($ARCHS, signed with: $IDENTITY)"
