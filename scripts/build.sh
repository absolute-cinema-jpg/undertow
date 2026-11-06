#!/bin/bash
# Builds Undertow with plain swiftc. Needs only the Command Line Tools, not Xcode
# (SwiftPM fails on a CLT-only install because it asks xcrun for a platform path).
#
#   scripts/build.sh            build dist/Undertow.app for this Mac
#   scripts/build.sh universal  build dist/Undertow.app for Apple Silicon and Intel
#   scripts/build.sh debug      build without optimisation (faster to compile)
#   scripts/build.sh checks     build and run the checks
set -euo pipefail

cd "$(dirname "$0")/.."
MODE="${1:-release}"
OPT="-O"
[ "$MODE" = "debug" ] && OPT="-Onone"
SHIM_INCLUDE="Sources/CShim/include"
HOST="$(uname -m)"

# Compiles the shim and core library for one architecture, into .build/<arch>.
build_core() {
    local arch="$1" dir=".build/$1"
    mkdir -p "$dir"
    clang -c -O2 -arch "$arch" -I "$SHIM_INCLUDE" Sources/CShim/shim.c -o "$dir/shim.o" -mmacosx-version-min=13.0
    swiftc -target "$arch-apple-macosx13.0" -I "$SHIM_INCLUDE" -I "$dir" $OPT -whole-module-optimization -parse-as-library \
        -module-name UndertowCore -emit-module -emit-module-path "$dir/UndertowCore.swiftmodule" \
        -emit-library -static -o "$dir/libUndertowCore.a" \
        Sources/UndertowCore/*.swift
}

link_flags() {
    local dir=".build/$1"
    echo "-L $dir -lUndertowCore -Xlinker $dir/shim.o -lsqlite3 -framework Security -framework SystemConfiguration -framework CoreGraphics"
}

build_app() {
    local arch="$1" dir=".build/$1"
    build_core "$arch"
    swiftc -target "$arch-apple-macosx13.0" -I "$SHIM_INCLUDE" -I "$dir" $OPT -whole-module-optimization -module-name Undertow \
        $(link_flags "$arch") -framework AppKit -framework SwiftUI -framework ServiceManagement -framework UserNotifications \
        -o "$dir/Undertow" Sources/Undertow/*.swift
}

if [ "$MODE" = "checks" ]; then
    build_core "$HOST"
    swiftc -target "$HOST-apple-macosx13.0" -I "$SHIM_INCLUDE" -I ".build/$HOST" -Onone $(link_flags "$HOST") \
        -o ".build/$HOST/UndertowChecks" Sources/UndertowChecks/main.swift
    exec ".build/$HOST/UndertowChecks"
fi

APP="dist/Undertow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "$MODE" = "universal" ]; then
    build_app arm64
    build_app x86_64
    lipo -create .build/arm64/Undertow .build/x86_64/Undertow -output "$APP/Contents/MacOS/Undertow"
else
    build_app "$HOST"
    cp ".build/$HOST/Undertow" "$APP/Contents/MacOS/Undertow"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ ! -f .build/AppIcon.icns ]; then
    swiftc -framework AppKit -o .build/make_icon scripts/make_icon.swift
    .build/make_icon .build/AppIcon.iconset
    iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns
fi
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"  # the GPL requires the license to travel with the binary

# Ad-hoc signature: enough to run on this Mac. Distributing without a warning would need a
# Developer ID certificate and notarisation. The hardened runtime stops other processes
# injecting code into Undertow through environment variables such as DYLD_INSERT_LIBRARIES.
codesign --force --options runtime --sign - "$APP" 2>/dev/null

echo "Built $APP"
