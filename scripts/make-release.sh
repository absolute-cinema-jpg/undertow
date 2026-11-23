#!/bin/bash
# Packages a built app the way the updater expects, and checks the package.
#
#   make-release.sh "build/My App.app" My-App- <out dir>
#
# Produces <out>/<prefix><version>.zip and <prefix><version>.zip.sha256, unzips a copy and
# checks its version, signature, helper and architectures. It does NOT publish. To publish
# (only when the person asks), with the version tag matching CFBundleShortVersionString:
#   gh release create v<version> <out>/<prefix><version>.zip <out>/<prefix><version>.zip.sha256 \
#      --target main --title "<App> <version>" --notes-file notes.md
set -euo pipefail
APP="${1:?usage: make-release.sh <App.app> <asset prefix> <out dir>}"
PREFIX="${2:?usage: make-release.sh <App.app> <asset prefix> <out dir>}"
OUT="${3:?usage: make-release.sh <App.app> <asset prefix> <out dir>}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="$OUT/$PREFIX$VERSION.zip"
mkdir -p "$OUT"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

CHECK=$(mktemp -d)
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$ZIP" "$CHECK"
COPY="$CHECK/$(basename "$APP")"
FAIL=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; FAIL=1; }
[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$COPY/Contents/Info.plist")" = "$VERSION" ] \
  && ok "version $VERSION" || bad "version mismatch"
codesign --verify --strict --deep "$COPY" && ok "signature valid" || bad "signature invalid"
[ -x "$COPY/Contents/XPCServices/Updater.xpc/Contents/MacOS/Updater" ] && ok "updater helper inside" \
  || bad "no updater helper: this version couldn't update itself later"
for bin in "$COPY/Contents/MacOS/"* "$COPY/Contents/XPCServices/Updater.xpc/Contents/MacOS/Updater"; do
  [ -f "$bin" ] && echo "    $(basename "$bin"): $(lipo -archs "$bin" 2>/dev/null)"
done
echo "  zip: $ZIP ($(stat -f%z "$ZIP") bytes)"
echo "  sha256: $(cut -d' ' -f1 "$ZIP.sha256")"
[ $FAIL = 0 ] || exit 1
