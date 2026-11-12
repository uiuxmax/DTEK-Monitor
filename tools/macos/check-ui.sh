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
/bin/bash "$repo/tools/macos/doctor.sh"
run=$(mktemp -d "$repo/out/macos/ui-check-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
mkdir "$run/profile"
for case_id in 0 1 2 3 4 5 6 7; do
    mkdir -p "$run/case-$case_id/profile"
    ln -s "$run/case-$case_id/profile" "$run/case-$case_id/alias"
done
report="$run/results.plist"
/usr/bin/plutil -create xml1 "$report"
record() { /usr/bin/plutil -insert "$1" -string "$2" "$report"; }
record checkout "$repo"
record commit "$(/usr/bin/git -C "$repo" rev-parse HEAD)"
record input_scope "$scope"
record scope 'M2 synthetic UI only; no physical display, VoiceOver, live, timezone, sign-in or Gatekeeper acceptance'
finish() {
    code=$?
    trap - EXIT
    if [[ "$code" -eq 0 ]]; then record result PASS; else record result FAIL; fi
    /usr/bin/plutil -convert json -o "$run/results.json" "$report"
    printf 'UI results: %s\n' "$run/results.json"
    exit "$code"
}
trap finish EXIT
/usr/bin/xcrun swift "$repo/$verifier" "$repo" > "$run/verified-before.json"
inputs=(app/macos/FixtureWidget/FixtureWidgetApp.swift app/macos/FixtureWidget/FixtureModel.swift
    app/macos/FixtureWidget/TestEnvelope.swift app/macos/FixtureWidget/WidgetView.swift
    app/macos/FixtureWidget/Info.plist tests/macos/FixtureUITests.swift
    app/macos/DTEKMonitor.xcodeproj/project.pbxproj
    app/macos/DTEKMonitor.xcodeproj/xcshareddata/xcschemes/DTEKFixtureWidget.xcscheme
    tools/macos/check-ui.sh tools/macos/doctor.sh "$verifier" "$manifest")
(cd "$repo" && /usr/bin/shasum -a 256 "${inputs[@]}") > "$run/inputs.sha256"
build=(/usr/bin/xcodebuild -project "$repo/app/macos/DTEKMonitor.xcodeproj"
    -scheme DTEKFixtureWidget -configuration Debug -derivedDataPath "$run/DerivedData"
    -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
    DTEKMONITOR_UI_TEST_ROOT="$run")
"${build[@]}" build-for-testing > "$run/build.log" 2>&1
app="$run/DerivedData/Build/Products/Debug/DTEKFixtureWidget.app"
binary="$app/Contents/MacOS/DTEKFixtureWidget"
[[ "$(/usr/bin/lipo -archs "$binary")" == arm64 ]]
[[ "$(/usr/bin/plutil -extract LSUIElement raw "$app/Contents/Info.plist")" == true ]]
/usr/bin/codesign --verify --deep --strict "$app" > "$run/signature.log" 2>&1
/usr/bin/shasum -a 256 "$binary" > "$run/executable.sha256"
base_env=(env -u DTEKMONITOR_TEST_ROOT -u DTEKMONITOR_TEST_PROFILE
    -u DTEKMONITOR_TEST_INSTANCE -u DTEKMONITOR_AUTOSTART_TEST_MODE -u DTEKMONITOR_DISABLE_PROVIDER)
expect_rejected() {
    name=$1
    shift
    code=0
    "$@" > "$run/$name.log" 2>&1 || code=$?
    [[ "$code" -eq 64 ]]
}
expect_rejected missing-envelope "${base_env[@]}" "$binary"
valid_env=("${base_env[@]}" DTEKMONITOR_TEST_ROOT="$run" DTEKMONITOR_TEST_PROFILE="$run/profile"
    DTEKMONITOR_TEST_INSTANCE="$(basename "$run")" DTEKMONITOR_AUTOSTART_TEST_MODE=1
    DTEKMONITOR_DISABLE_PROVIDER=1)
expect_rejected real-backend "${valid_env[@]}" DTEKMONITOR_AUTOSTART_TEST_MODE=0 "$binary"
expect_rejected network-enabled "${valid_env[@]}" DTEKMONITOR_DISABLE_PROVIDER=0 "$binary"
"${build[@]}" test-without-building -resultBundlePath "$run/Tests.xcresult" > "$run/tests.log" 2>&1
/usr/bin/xcrun xcresulttool get test-results summary --path "$run/Tests.xcresult" > "$run/test-summary.json"
[[ "$(/usr/bin/plutil -extract failedTests raw "$run/test-summary.json")" == 0 ]]
[[ "$(/usr/bin/plutil -extract passedTests raw "$run/test-summary.json")" == 13 ]]
[[ "$(/usr/bin/plutil -extract skippedTests raw "$run/test-summary.json")" == 0 ]]
(cd "$repo" && /usr/bin/shasum -a 256 -c "$run/inputs.sha256") > "$run/inputs-after.log"
/usr/bin/xcrun swift "$repo/$verifier" "$repo" > "$run/verified-after.json"
cmp "$run/verified-before.json" "$run/verified-after.json"
record model_tests 6
record ui_tests 7
record rejected_app_envelopes 3
record architecture arm64
record evidence 'Tests.xcresult, test-summary.json, tests.log, build.log, inputs.sha256, executable.sha256'
