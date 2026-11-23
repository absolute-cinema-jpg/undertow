#!/bin/bash
# Builds a universal release zip, with the .sha256 file the updater checks.
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
# Zips the way the updater expects, writes the .sha256 it checks, and verifies the result:
# version, signature, the updater helper inside, and both architectures.
scripts/make-release.sh dist/Undertow.app Undertow- dist
