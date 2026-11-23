#!/bin/bash
# Compiles the updater helper and embeds it in a built app as Contents/XPCServices/Updater.xpc,
# signed. Run it after the app is assembled and BEFORE the app itself is signed: the app's
# signature must be made last so it seals the helper inside it.
#
#   embed-updater-helper.sh "build/My App.app" Sources            # Sources has Updater/ and UpdateShared.swift
#   SIGN_IDENTITY="Developer ID Application: …" embed-updater-helper.sh …   # default: ad-hoc ("-")
#   MIN_MACOS=13.0 (default)
#
# The helper is deliberately signed WITHOUT the App Sandbox entitlement: it confines itself
# with its own, stricter sandbox when it starts (Updater/main.swift).
set -euo pipefail
APP="${1:?usage: embed-updater-helper.sh <App.app> <sources dir>}"
SRC="${2:?usage: embed-updater-helper.sh <App.app> <sources dir>}"
IDENTITY="${SIGN_IDENTITY:--}"
MIN="${MIN_MACOS:-13.0}"
[ -f "$SRC/UpdateShared.swift" ] && [ -f "$SRC/Updater/main.swift" ] && [ -f "$SRC/Updater/Installer.swift" ] \
  || { echo "error: $SRC needs UpdateShared.swift, Updater/main.swift and Updater/Installer.swift" >&2; exit 1; }
[ -f "$APP/Contents/Info.plist" ] || { echo "error: $APP isn't a built app" >&2; exit 1; }

ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "→ Compiling the updater helper (Apple Silicon + Intel)…"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos$MIN" "$SRC"/Updater/*.swift "$SRC/UpdateShared.swift" -o "$TMP/Updater-$arch"
done

XPC="$APP/Contents/XPCServices/Updater.xpc"
rm -rf "$XPC"
mkdir -p "$XPC/Contents/MacOS"
lipo -create "$TMP"/Updater-* -output "$XPC/Contents/MacOS/Updater"
PLIST="$XPC/Contents/Info.plist"
plutil -create xml1 "$PLIST"
plutil -insert CFBundleIdentifier -string "$ID.Updater" "$PLIST"          # the app looks it up by this name
plutil -insert CFBundleName -string "Updater" "$PLIST"
plutil -insert CFBundleExecutable -string Updater "$PLIST"
plutil -insert CFBundlePackageType -string 'XPC!' "$PLIST"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -insert LSMinimumSystemVersion -string "$MIN" "$PLIST"
plutil -insert XPCService -xml '<dict><key>ServiceType</key><string>Application</string></dict>' "$PLIST"

codesign --force --sign "$IDENTITY" --options runtime "$XPC"
echo "✓ Embedded $ID.Updater. Now sign the app itself (without --deep)."
