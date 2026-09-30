#!/bin/bash
# Launches the real app in the simulator: first with nothing set up, then with a seeded Goldie folder.
# Fails if the app crashes or doesn't build the finished days' animations on its own.
set -euo pipefail
UDID="$1"
PRODUCTS="$2"
OUT="$3"
APP=$(find "$PRODUCTS" -maxdepth 4 -name "*.app" -path "*iphonesimulator*" | head -1)
BUNDLE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
echo "App: $APP ($BUNDLE)"

# Save the list, then search it: piping into `grep -q` can end in a broken pipe, which pipefail reports as "not running".
running() {
    xcrun simctl spawn "$UDID" launchctl list > "$OUT/launchctl.txt"
    grep -q "$BUNDLE" "$OUT/launchctl.txt"
}

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"

echo "== First launch (nothing set up yet)"
xcrun simctl launch "$UDID" "$BUNDLE"
sleep 12
xcrun simctl io "$UDID" screenshot "$OUT/1-first-launch.png"
running || { echo "FAIL: app is not running after first launch (crashed?)"; exit 1; }
echo "PASS: app launched and is still running"
xcrun simctl terminate "$UDID" "$BUNDLE"

echo "== Seeded launch (a Goldie folder with 3 days of screenshots)"
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
COUNT=0
BOOKMARK=$(swift ci/seed.swift "$DATA/Documents/GoldieShots")
xcrun simctl spawn "$UDID" defaults write "$BUNDLE" screenshotFolderBookmark -data "$BOOKMARK"
xcrun simctl launch "$UDID" "$BUNDLE"
for i in $(seq 1 18); do   # up to 90 s for the two finished days to build
    sleep 5
    COUNT=$( (ls "$DATA/Documents/Animations"/*.mp4 2>/dev/null || true) | wc -l | tr -d ' ')  # none yet is 0, not an error
    [ "$COUNT" = "2" ] && break
done
sleep 3
xcrun simctl io "$UDID" screenshot "$OUT/2-seeded.png"
ls -la "$DATA/Documents/Animations" || true
running || { echo "FAIL: app is not running after the seeded launch (crashed?)"; exit 1; }
[ "$COUNT" = "2" ] || { echo "FAIL: expected 2 animations for the finished days, found $COUNT"; exit 1; }
echo "PASS: app built both finished days' animations by itself and is still running"
