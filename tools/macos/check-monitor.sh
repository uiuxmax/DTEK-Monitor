#!/bin/bash
# M6/M7 connected UI and fake Login Items. Serial after the fixture UI suite.
set -euo pipefail
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || exit 64
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
if [[ "$#" -eq 1 && "$1" == --public-probe ]]; then
    [[ ! -e "$repo/tools/preserved-files.json" && -f "$repo/tools/macos/probe-inputs.json" ]] || exit 64
    verifier=tools/macos/verify-probe-inputs.swift
elif [[ "$#" -eq 0 ]]; then verifier=tools/macos/verify-preserved.swift
else exit 64; fi
run=$(mktemp -d "$repo/out/macos/monitor-ui-check-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
mkdir "$run/profile"
for case_id in 0 1 2 3 4 5 6 7; do mkdir -p "$run/case-$case_id/profile"; done
report="$run/results.plist"
/usr/bin/plutil -create xml1 "$report"
record() { /usr/bin/plutil -insert "$1" -string "$2" "$report" || exit 1; }
record checkout "$repo"
record commit "$(/usr/bin/git -C "$repo" rev-parse HEAD)"
record scope 'M6 connected synthetic UI/M7 fake login only; Release compiles but is never run'
finish() {
    code=$?; trap - EXIT
    if [[ "$code" -eq 0 ]]; then record result PASS; else record result FAIL; fi
    /usr/bin/plutil -convert json -o "$run/results.json" "$report" || exit 1
    printf 'Monitor results: %s\n' "$run/results.json"
    exit "$code"
}
trap finish EXIT
/usr/bin/xcrun swift "$repo/$verifier" "$repo" > "$run/verified-before.json" || exit 1
inputs=(tests/macos/MonitorUITests.swift tests/macos/MonitorInfo.plist tests/macos/LoginItemTests.swift
    app/assets/power-on-v1.png app/assets/power-off-v1.png app/assets/notification-v1.png
    tools/macos/check-monitor.sh tools/macos/verify-ui-result.swift tools/macos/select-prior-run.py app/https_resource.cpp app/https_resource.h
    app/https_contract.h app/yasno_lookup_types.h app/yasno_schedule_adapter.h app/address_draft.h
    app/schedule_flow.h app/schedule_cache.h app/popup_schedule.h app/log_retention.h
    research/schedule-engine/schedule_engine.cpp research/schedule-engine/schedule_engine.h
    research/schedule-engine/windows_kyiv_timezone.h research/schedule-engine/kyiv_time_projection.h)
while IFS= read -r -d '' source; do inputs+=("$source"); done < <(/usr/bin/find "$repo/app/macos" -type f \( \
    -name '*.swift' -o -name '*.mm' -o -name '*.h' -o -name '*.plist' -o -name 'project.pbxproj' -o -name '*.xcscheme' \) -print0)
(cd "$repo" && /usr/bin/shasum -a 256 "${inputs[@]}") > "$run/inputs.sha256" || exit 1
build=(/usr/bin/xcodebuild -project "$repo/app/macos/DTEKMonitor.xcodeproj" -scheme DTEKMonitor
    -configuration Debug -derivedDataPath "$run/DerivedData" -destination 'platform=macOS,arch=arm64'
    -parallel-testing-enabled NO ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
    DTEKMONITOR_UI_TEST_ROOT="$run")
"${build[@]}" build-for-testing > "$run/build.log" 2>&1 || exit 1
app="$run/DerivedData/Build/Products/Debug/DTEKMonitor.app"
binary="$app/Contents/MacOS/DTEKMonitor"
[[ "$(/usr/bin/lipo -archs "$binary")" == arm64 ]] || exit 1
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" == local.dtekmonitor.MonitorTest ]] || exit 1
[[ "$(/usr/bin/plutil -extract LSUIElement raw "$app/Contents/Info.plist")" == true ]] || exit 1
/usr/bin/codesign --verify --deep --strict "$app" > "$run/signature.log" 2>&1 || exit 1
test_plist=$(find "$run/DerivedData/Build/Products" -path '*/DTEKMonitorUITests.xctest/Contents/Info.plist' -type f -print -quit)
[[ -n "$test_plist" && "$(/usr/bin/plutil -extract DTEKMonitorRoot raw "$test_plist")" == "$run" ]] || exit 1
base=(env -u DTEKMONITOR_TEST_ROOT -u DTEKMONITOR_TEST_PROFILE -u DTEKMONITOR_TEST_INSTANCE
    -u DTEKMONITOR_AUTOSTART_TEST_MODE -u DTEKMONITOR_DISABLE_PROVIDER)
valid=("${base[@]}" DTEKMONITOR_TEST_ROOT="$run" DTEKMONITOR_TEST_PROFILE="$run/profile"
    DTEKMONITOR_TEST_INSTANCE="monitor-envelope" DTEKMONITOR_AUTOSTART_TEST_MODE=1 DTEKMONITOR_DISABLE_PROVIDER=1)
reject() { local code=0; "$@" > "$run/rejected.log" 2>&1 || code=$?; [[ "$code" -eq 64 ]] || exit 1; }
reject "${base[@]}" "$binary"
reject "${valid[@]}" DTEKMONITOR_AUTOSTART_TEST_MODE=0 "$binary"
reject "${valid[@]}" DTEKMONITOR_DISABLE_PROVIDER=0 "$binary"
if [[ -n "${DTEKMONITOR_CORE_RESULTS:-}" ]]; then
    prior="$DTEKMONITOR_CORE_RESULTS"
else
    reports=("$repo"/out/macos/check-*/results.json)
    [[ "${#reports[@]}" -eq 1 && -f "${reports[0]}" ]] || exit 64
    prior="${reports[0]}"
fi
probe=$(python3 -B "$repo/tools/macos/select-prior-run.py" core "$repo" "$prior") || exit 1
"${valid[@]}" "$probe" --login-probe > "$run/login.log" 2>&1 || exit 1
grep -q '^RESULT 14/14 fake Login Item checks passed$' "$run/login.log" || exit 1
# Build the personal configuration without starting it or registering anything.
/usr/bin/xcodebuild -project "$repo/app/macos/DTEKMonitor.xcodeproj" -scheme DTEKMonitor -configuration Release \
    -derivedDataPath "$run/PersonalData" -destination 'generic/platform=macOS' \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES \
    build > "$run/release-build.log" 2>&1 || exit 1
personal="$run/PersonalData/Build/Products/Release/DTEKMonitor.app"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$personal/Contents/Info.plist")" == local.dtekmonitor.Monitor ]] || exit 1
[[ "$(/usr/bin/lipo -archs "$personal/Contents/MacOS/DTEKMonitor")" == arm64 ]] || exit 1
/usr/bin/codesign --verify --deep --strict "$personal" > "$run/release-signature.log" 2>&1 || exit 1
for asset in power-on-v1.png power-off-v1.png notification-v1.png; do
    cmp "$repo/app/assets/$asset" "$app/Contents/Resources/$asset" || exit 1
    cmp "$repo/app/assets/$asset" "$personal/Contents/Resources/$asset" || exit 1
done
summary_verifier="$repo/tools/macos/verify-ui-result.swift"
for invalid in failed skipped partial malformed wrong-target; do
    case "$invalid" in
        failed) fixture='{"result":"Failed","failedTests":1,"passedTests":7,"skippedTests":0,"totalTestCount":8}' ;;
        skipped) fixture='{"result":"Passed","failedTests":0,"passedTests":7,"skippedTests":1,"totalTestCount":8}' ;;
        partial) fixture='{"result":"Passed","failedTests":0,"passedTests":7,"skippedTests":0,"totalTestCount":7}' ;;
        malformed) fixture='{}' ;;
        wrong-target) fixture='{"result":"Passed","failedTests":0,"passedTests":13,"skippedTests":0,"totalTestCount":13}' ;;
    esac
    printf '%s\n' "$fixture" > "$run/summary-$invalid.json"
    code=0
    /usr/bin/xcrun swift "$summary_verifier" "$run/summary-$invalid.json" 8 > "$run/summary-$invalid.log" 2>&1 || code=$?
    [[ "$code" -eq 1 ]] || exit 1
done
code=0
"${build[@]}" test-without-building -resultBundlePath "$run/Tests.xcresult" > "$run/tests.log" 2>&1 || code=$?
/usr/bin/xcrun xcresulttool get test-results summary --path "$run/Tests.xcresult" > "$run/test-summary.json" || exit 1
/usr/bin/xcrun swift "$summary_verifier" "$run/test-summary.json" 8 > "$run/summary-verification.log" 2>&1 || exit 1
[[ "$code" -eq 0 ]] || exit "$code"
(cd "$repo" && /usr/bin/shasum -a 256 -c "$run/inputs.sha256") > "$run/inputs-after.log" || exit 1
/usr/bin/xcrun swift "$repo/$verifier" "$repo" > "$run/verified-after.json" || exit 1
cmp "$run/verified-before.json" "$run/verified-after.json" || exit 1
/usr/bin/shasum -a 256 "$personal/Contents/MacOS/DTEKMonitor" \
    "$personal/Contents/Resources/power-on-v1.png" "$personal/Contents/Resources/power-off-v1.png" \
    "$personal/Contents/Resources/notification-v1.png" > "$run/personal-files.sha256" || exit 1
record ui_checks 8
record fake_login_checks 14
record rejected_app_envelopes 3
record rejected_invalid_summaries 5
record architecture arm64
record personal_build 'Compiled and signature-verified; never executed in CI'
