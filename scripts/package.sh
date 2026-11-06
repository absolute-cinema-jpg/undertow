#!/bin/bash
# Builds a universal release zip and prints its checksum.
#
#   scripts/package.sh 1.0.0
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/package.sh <version>}"

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
if [ "$PLIST_VERSION" != "$VERSION" ]; then
    echo "Resources/Info.plist says $PLIST_VERSION, but you asked for $VERSION" >&2
    exit 1
fi

scripts/build.sh universal
ZIP="dist/Undertow-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent dist/Undertow.app "$ZIP"
lipo -archs dist/Undertow.app/Contents/MacOS/Undertow
shasum -a 256 "$ZIP"
