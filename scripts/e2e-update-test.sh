#!/bin/bash
# A real self-update, end to end, on throwaway copies of a built app.
#
#   e2e-update-test.sh "build/My App.app" My-App-
#
# It makes two copies under a separate test bundle identifier (so the real app, its settings
# and its sandbox folder are never touched): an "old" 0.0.1 and a "new" 0.0.2. It serves the
# new one from a stand-in for GitHub on 127.0.0.1, opens the old one with
# `-UpdateFeedURL http://127.0.0.1:… --install-update` (only honoured for 127.0.0.1), and
# checks the old copy downloaded, verified, installed and restarted into the new one.
#
# Heads-up: the test copy's window (if the app opens one) appears for a few seconds.
# The app must have been built with the updater (Updater.shared.start() called at launch).
set -euo pipefail
SOURCE_APP="${1:?usage: e2e-update-test.sh <built App.app> <asset prefix, e.g. My-App->}"
PREFIX="${2:?usage: e2e-update-test.sh <built App.app> <asset prefix, e.g. My-App->}"
PORT="${PORT:-8766}"
NAME=$(basename "$SOURCE_APP")
REAL_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$SOURCE_APP/Contents/Info.plist")
TEST_ID="$REAL_ID.e2etest"
WORK=$(mktemp -d)
WORK=$(cd "$WORK" && pwd -P)
SERVER=""
# macOS may list the running copy as /var/… or /tmp/… rather than /private/…, so match on
# the end of the path only.
MATCH="$(basename "$WORK")/apps/$NAME/Contents/MacOS/"
cleanup() {
  pkill -f "$MATCH" 2>/dev/null || true
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null || true
  rm -rf "$WORK" "$HOME/Library/Containers/$TEST_ID" "$HOME/Library/Containers/$TEST_ID.Updater"
  defaults delete "$TEST_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

[ -d "$SOURCE_APP/Contents/XPCServices/Updater.xpc" ] || { echo "✗ $SOURCE_APP has no Contents/XPCServices/Updater.xpc"; exit 1; }

# Copy the app under the test identifier and version, then re-sign helper then app with
# their original entitlements.
make_copy() {  # dest version
  local dest="$1" version="$2" ents="$WORK/ents.plist"
  ditto "$SOURCE_APP" "$dest"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TEST_ID" -c "Set :CFBundleShortVersionString $version" "$dest/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TEST_ID.Updater" "$dest/Contents/XPCServices/Updater.xpc/Contents/Info.plist"
  codesign --force --sign - --options runtime "$dest/Contents/XPCServices/Updater.xpc" 2>/dev/null
  codesign -d --entitlements - --xml "$SOURCE_APP" > "$ents" 2>/dev/null || true
  if [ -s "$ents" ]; then
    codesign --force --sign - --options runtime --entitlements "$ents" "$dest" 2>/dev/null
  else
    codesign --force --sign - --options runtime "$dest" 2>/dev/null
  fi
}

mkdir -p "$WORK/apps" "$WORK/www" "$WORK/new"
make_copy "$WORK/new/$NAME" 0.0.2
(cd "$WORK/new" && ditto -c -k --sequesterRsrc --keepParent "$NAME" "$WORK/www/${PREFIX}0.0.2.zip")
make_copy "$WORK/apps/$NAME" 0.0.1
SHA=$(shasum -a 256 "$WORK/www/${PREFIX}0.0.2.zip" | cut -d' ' -f1)
SIZE=$(stat -f%z "$WORK/www/${PREFIX}0.0.2.zip")
cat > "$WORK/www/latest.json" <<EOF
{"tag_name": "v0.0.2", "name": "Test", "draft": false, "prerelease": false,
 "html_url": "https://github.com/example/example/releases/tag/v0.0.2", "body": "## What's new\n\nTest.",
 "assets": [{"name": "${PREFIX}0.0.2.zip", "size": $SIZE, "digest": "sha256:$SHA",
             "browser_download_url": "http://127.0.0.1:$PORT/${PREFIX}0.0.2.zip"}]}
EOF

(cd "$WORK/www" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >"$WORK/http.log" 2>&1) &
SERVER=$!
disown "$SERVER" 2>/dev/null || true    # no "Terminated" message when it's stopped
sleep 1
START=$(date '+%Y-%m-%d %H:%M:%S')
echo "→ Opening the 0.0.1 test copy and letting it update itself…"
open -n -g "$WORK/apps/$NAME" --args -UpdateFeedURL "http://127.0.0.1:$PORT/latest.json" --install-update

INSTALLED=""
for _ in $(seq 1 30); do
  sleep 1
  INSTALLED=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$WORK/apps/$NAME/Contents/Info.plist" 2>/dev/null || true)
  [ "$INSTALLED" = "0.0.2" ] && pgrep -f "$MATCH" >/dev/null && break
done
sleep 2

FAIL=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; FAIL=1; }
[ "$INSTALLED" = "0.0.2" ] && ok "the new version is installed in place" || bad "installed version is '$INSTALLED', expected 0.0.2"
RUNNING=$(pgrep -f "$MATCH" | wc -l | tr -d ' ')
[ "$RUNNING" = "1" ] && ok "exactly one copy is running afterwards (the restarted one)" || bad "$RUNNING copies running"
LEFT=$(ls -A "$WORK/apps")
[ "$LEFT" = "$NAME" ] && ok "nothing is left beside it" || bad "left beside it: $LEFT"
xattr "$WORK/apps/$NAME" | grep -q com.apple.quarantine && bad "the new copy is quarantined (macOS would ask before opening it)" \
  || ok "the new copy isn't quarantined, so it opens without asking"
codesign --verify --strict --deep "$WORK/apps/$NAME" && ok "its signature is intact" || bad "its signature is broken"
LOG=$(/usr/bin/log show --start "$START" --predicate "subsystem == \"$TEST_ID\" AND category == \"update\"" --info --style compact 2>/dev/null | grep -v '^Timestamp' || true)
echo "$LOG" | grep -q "now running 0.0.2 after updating" && ok "the restarted copy knows it was just updated" \
  || bad "the restarted copy didn't log 'now running 0.0.2 after updating'"
echo "--- update log:"; echo "$LOG"
echo "--- test server:"; cat "$WORK/http.log"
[ $FAIL = 0 ] && echo "End-to-end update passed." || { echo "End-to-end update FAILED."; exit 1; }
