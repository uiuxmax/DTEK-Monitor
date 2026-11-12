#!/bin/bash
# M2 native fixture UI only. Serial XCUITest on the isolated development app.
set -euo pipefail
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo 'Native Apple Silicon macOS is required; no files were written.' >&2
    exit 64
fi
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
scope=private-checkout
verifier=tools/macos/verify-preserved.swift
manifest=tools/preserved-files.json
if [[ "$#" -eq 1 && "$1" == --public-probe ]]; then
    if [[ -e "$repo/tools/preserved-files.json" || ! -f "$repo/tools/macos/probe-inputs.json" ]]; then
        echo 'Public probe mode requires the isolated source export.' >&2
        exit 64
    fi
    scope=public-probe
    verifier=tools/macos/verify-probe-inputs.swift
    manifest=tools/macos/probe-inputs.json
elif [[ "$#" -ne 0 ]]; then
    echo 'Usage: check-ui.sh [--public-probe]' >&2
    exit 64
fi
if ! /bin/bash "$repo/tools/macos/doctor.sh"; then exit 1; fi
run=$(mktemp -d "$repo/out/macos/ui-check-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX") || exit 1
mkdir "$run/profile" || exit 1
for case_id in 0 1 2 3 4 5 6 7; do
    mkdir -p "$run/case-$case_id/profile" || exit 1
    ln -s "$run/case-$case_id/profile" "$run/case-$case_id/alias" || exit 1
done
report="$run/results.plist"
/usr/bin/plutil -create xml1 "$report" || exit 1
record() { /usr/bin/plutil -insert "$1" -string "$2" "$report" || exit 1; }
require_value() {
    if [[ "$1" != "$2" ]]; then printf 'Verification failed: %s (expected %s)\n' "$3" "$2" >&2; exit 1; fi
}
record checkout "$repo"
record commit "$(/usr/bin/git -C "$repo" rev-parse HEAD)"
record input_scope "$scope"
record scope 'M2 synthetic UI only; no physical display, VoiceOver, live, timezone, sign-in or Gatekeeper acceptance'
finish() {
    local finish_code=$?
    trap - EXIT
    if [[ "$finish_code" -eq 0 ]]; then record result PASS; else record result FAIL; fi
    /usr/bin/plutil -convert json -o "$run/results.json" "$report" || exit 1
    printf 'UI results: %s\n' "$run/results.json"
    exit "$finish_code"
}
trap finish EXIT
/usr/bin/xcrun swift "$repo/$verifier" "$repo" > "$run/verified-before.json" || exit 1
inputs=(app/macos/FixtureWidget/FixtureWidgetApp.swift app/macos/FixtureWidget/FixtureModel.swift
    app/macos/FixtureWidget/TestEnvelope.swift app/macos/FixtureWidget/WidgetView.swift
    app/macos/FixtureWidget/Info.plist tests/macos/FixtureUITests.swift tests/macos/Info.plist
    app/macos/DTEKMonitor.xcodeproj/project.pbxproj
    app/macos/DTEKMonitor.xcodeproj/xcshareddata/xcschemes/DTEKFixtureWidget.xcscheme
    tools/macos/check-ui.sh tools/macos/doctor.sh tools/macos/verify-ui-result.swift "$verifier" "$manifest")
(cd "$repo" && /usr/bin/shasum -a 256 "${inputs[@]}") > "$run/inputs.sha256" || exit 1
build=(/usr/bin/xcodebuild -project "$repo/app/macos/DTEKMonitor.xcodeproj"
    -scheme DTEKFixtureWidget -configuration Debug -derivedDataPath "$run/DerivedData"
    -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
    DTEKMONITOR_UI_TEST_ROOT="$run")
"${build[@]}" build-for-testing > "$run/build.log" 2>&1 || exit 1
test_plist=$(find "$run/DerivedData/Build/Products" -path '*/DTEKFixtureUITests.xctest/Contents/Info.plist' -type f -print -quit)
if [[ -z "$test_plist" ]]; then echo 'Test bundle metadata missing' >&2; exit 1; fi
require_value "$(/usr/bin/plutil -extract DTEKFixtureRoot raw "$test_plist")" "$run" 'Harness root metadata'
app="$run/DerivedData/Build/Products/Debug/DTEKFixtureWidget.app"
binary="$app/Contents/MacOS/DTEKFixtureWidget"
require_value "$(/usr/bin/lipo -archs "$binary")" arm64 'App architecture'
require_value "$(/usr/bin/plutil -extract LSUIElement raw "$app/Contents/Info.plist")" true LSUIElement
/usr/bin/codesign --verify --deep --strict "$app" > "$run/signature.log" 2>&1 || exit 1
/usr/bin/shasum -a 256 "$binary" > "$run/executable.sha256" || exit 1
base_env=(env -u DTEKMONITOR_TEST_ROOT -u DTEKMONITOR_TEST_PROFILE
    -u DTEKMONITOR_TEST_INSTANCE -u DTEKMONITOR_AUTOSTART_TEST_MODE -u DTEKMONITOR_DISABLE_PROVIDER)
expect_rejected() {
    local name=$1
    shift
    local rejection_code=0
    "$@" > "$run/$name.log" 2>&1 || rejection_code=$?
    require_value "$rejection_code" 64 "Rejected envelope: $name"
}
expect_rejected missing-envelope "${base_env[@]}" "$binary"
valid_env=("${base_env[@]}" DTEKMONITOR_TEST_ROOT="$run" DTEKMONITOR_TEST_PROFILE="$run/profile"
    DTEKMONITOR_TEST_INSTANCE="$(basename "$run")" DTEKMONITOR_AUTOSTART_TEST_MODE=1
    DTEKMONITOR_DISABLE_PROVIDER=1)
expect_rejected real-backend "${valid_env[@]}" DTEKMONITOR_AUTOSTART_TEST_MODE=0 "$binary"
expect_rejected network-enabled "${valid_env[@]}" DTEKMONITOR_DISABLE_PROVIDER=0 "$binary"
summary_verifier="$repo/tools/macos/verify-ui-result.swift"
# Regression for the observed false-green run: a primary failing/skipped or
# malformed report must produce a nonzero exit, even if the outer shell continues.
for invalid in failed skipped partial malformed; do
    case "$invalid" in
        failed) fixture='{"result":"Failed","failedTests":6,"passedTests":7,"skippedTests":0,"totalTestCount":13}' ;;
        skipped) fixture='{"result":"Passed","failedTests":0,"passedTests":12,"skippedTests":1,"totalTestCount":13}' ;;
        partial) fixture='{"result":"Passed","failedTests":0,"passedTests":12,"skippedTests":0,"totalTestCount":12}' ;;
        malformed) fixture='{}' ;;
    esac
    printf '%s\n' "$fixture" > "$run/summary-$invalid.json"
    verifier_code=0
    /usr/bin/xcrun swift "$summary_verifier" "$run/summary-$invalid.json" > "$run/summary-$invalid.log" 2>&1 || verifier_code=$?
    if [[ "$verifier_code" -ne 1 ]]; then echo 'Summary verifier failed its rejection regression' >&2; exit 1; fi
done
if "${build[@]}" test-without-building -resultBundlePath "$run/Tests.xcresult" > "$run/tests.log" 2>&1; then
    test_code=0
else
    test_code=$?
fi
if ! /usr/bin/xcrun xcresulttool get test-results summary --path "$run/Tests.xcresult" > "$run/test-summary.json"; then exit 1; fi
if ! /usr/bin/xcrun swift "$summary_verifier" "$run/test-summary.json" > "$run/summary-verification.log" 2>&1; then exit 1; fi
if [[ "$test_code" -ne 0 ]]; then exit "$test_code"; fi
(cd "$repo" && /usr/bin/shasum -a 256 -c "$run/inputs.sha256") > "$run/inputs-after.log" || exit 1
/usr/bin/xcrun swift "$repo/$verifier" "$repo" > "$run/verified-after.json" || exit 1
cmp "$run/verified-before.json" "$run/verified-after.json" || exit 1
record model_tests 6
record ui_tests 7
record rejected_app_envelopes 3
record rejected_invalid_summaries 4
record architecture arm64
record evidence 'Tests.xcresult, test-summary.json, tests.log, build.log, inputs.sha256, executable.sha256'
