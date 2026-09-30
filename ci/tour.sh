#!/bin/bash
# Builds the UI tour and runs it against the app smoke.sh already installed and seeded.
set -euo pipefail
UDID="$1"
OUT="$2"
brew install xcodegen > /dev/null
python3 ci/prepare_tour.py
cd ci/tour
xcodegen generate
set -o pipefail
xcodebuild build-for-testing -project GoldieTour.xcodeproj -scheme GoldieTour \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$OUT/tour-build" CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$OUT/tour-build.log" | grep -E "error:|BUILD (SUCCEEDED|FAILED)|TEST BUILD (SUCCEEDED|FAILED)" || true
TEST_RUNNER_TOUR_OUTPUT="$OUT" xcodebuild test-without-building -project GoldieTour.xcodeproj -scheme GoldieTour \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$OUT/tour-build" -resultBundlePath "$OUT/Tour.xcresult" \
    2>&1 | tee "$OUT/tour.log" | grep -E "Test Case|error|XCTAssert|TEST (SUCCEEDED|FAILED)"
ls "$OUT"/*.png
