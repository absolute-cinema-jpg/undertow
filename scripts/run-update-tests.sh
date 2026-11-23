#!/bin/bash
# Runs the updater's tests against an app's copy of the updater files.
#   run-update-tests.sh Sources      # Sources has UpdateConfig.swift, UpdateShared.swift, UpdateLogic.swift, Updater/Installer.swift
# Silent (no sounds, no windows). Builds tiny signed test apps in a temp folder and removes them.
set -euo pipefail
SRC="${1:?usage: run-update-tests.sh <sources dir>}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TESTS="${UPDATE_TESTS:-$HERE/Tests/UpdateTests.swift}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swiftc -parse-as-library "$SRC/UpdateConfig.swift" "$SRC/UpdateShared.swift" "$SRC/UpdateLogic.swift" \
  "$SRC/Updater/Installer.swift" "$TESTS" -o "$OUT/update-tests"
"$OUT/update-tests"
