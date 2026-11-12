#!/bin/bash
# M1/M3/M4 native core, timezone and isolated profile/data probe. No provider requests.
set -euo pipefail
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo 'Native Apple Silicon macOS is required; no files were written.' >&2
    exit 64
fi
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
scope=private-checkout
if [[ "$#" -eq 1 && "$1" == --public-probe ]]; then
    # The public synthetic export intentionally contains no historical inputs.
    # This mode cannot bypass preservation checks in the private checkout.
    if [[ -e "$repo/tools/preserved-files.json" || ! -f "$repo/tools/macos/probe-inputs.json" ]]; then
        echo 'Public probe mode requires the isolated source export.' >&2
        exit 64
    fi
    scope=public-probe
elif [[ "$#" -ne 0 ]]; then
    echo 'Usage: check.sh [--public-probe]' >&2
    exit 64
fi
/bin/bash "$repo/tools/macos/doctor.sh"
run=$(mktemp -d "$repo/out/macos/check-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
mkdir "$run/profile"
report="$run/results.plist"
/usr/bin/plutil -create xml1 "$report"
record() { /usr/bin/plutil -insert "$1" -string "$2" "$report"; }
record checkout "$repo"
record commit "$(/usr/bin/git -C "$repo" rev-parse HEAD)"
record started_at_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
record architecture arm64
record scope 'M1/M3/M4 core, bridge, Foundation Kyiv, JSON and isolated profiles; no live, physical UI, login or Gatekeeper acceptance'
record input_scope "$scope"
finish() {
    code=$?
    trap - EXIT
    if [[ "$code" -eq 0 ]]; then record result PASS; else record result FAIL; fi
    record finished_at_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    /usr/bin/plutil -convert json -o "$run/results.json" "$report"
    printf 'Results: %s\n' "$run/results.json"
    exit "$code"
}
trap finish EXIT
/usr/bin/git -C "$repo" status --porcelain > "$run/working-tree.txt"
/usr/bin/xcodebuild -version > "$run/toolchain.txt"
/usr/bin/xcrun --sdk macosx --show-sdk-version >> "$run/toolchain.txt"
if [[ "$scope" == public-probe ]]; then
    verifier=tools/macos/verify-probe-inputs.swift
    manifest=tools/macos/probe-inputs.json
else
    verifier=tools/macos/verify-preserved.swift
    manifest=tools/preserved-files.json
fi
/usr/bin/xcrun swift "$repo/$verifier" "$repo" > "$run/verified-before.json"
# Record every build input, including shared engine/tests, before compilation.
inputs=(app/macos/Session/MonitorBridge.h app/macos/Session/MonitorBridge.mm
    app/macos/Session/MonitorSession.swift app/macos/Session/NativeLookupWorker.swift
    app/macos/Network/SessionPolicy.swift app/macos/Network/HTTPSAttempt.swift
    app/macos/Network/NetworkHTTPSAttempt.swift app/macos/Network/RawHTTPResponse.swift
    app/macos/FixtureWidget/TestEnvelope.swift tests/macos/MonitorSessionTests.swift
    tests/macos/monitor_bridge_tests.h tests/macos/monitor_bridge_tests.mm app/macos/CoreProbe/main.swift app/macos/CoreProbe/CoreProbeBridge.h
    app/macos/CoreProbe/CoreProbeBridge.mm app/macos/CoreProbe/BridgingHeader.h
    app/macos/DTEKMonitor.xcodeproj/project.pbxproj
    app/macos/DTEKMonitor.xcodeproj/xcshareddata/xcschemes/DTEKCoreProbe.xcscheme
    research/schedule-engine/schedule_engine.h research/schedule-engine/schedule_engine.cpp
    research/schedule-engine/test_support.h research/schedule-engine/portable_tests.cpp
    research/schedule-engine/kyiv_time_projection.h research/schedule-engine/kyiv_timezone_cases.h
    app/macos/Time/foundation_kyiv_timezone.h app/macos/Time/foundation_kyiv_timezone.mm
    tests/macos/timezone_tests.h tests/macos/timezone_tests.mm
    app/macos/Data/foundation_json.h app/macos/Data/foundation_json.mm
    app/macos/Data/foundation_address_draft.mm app/macos/Data/foundation_address_search.h
    app/macos/Data/foundation_yasno_adapter.mm app/macos/Data/foundation_profile.h app/macos/Data/foundation_profile.mm
    tests/macos/data_tests.h tests/macos/data_tests.mm app/yasno_schedule_adapter.h app/address_draft.h
    app/schedule_flow.h app/schedule_cache.h app/popup_schedule.h app/log_retention.h
    research/schedule-engine/windows_kyiv_timezone.h
    app/macos/Data/foundation_yasno_lookup.h app/macos/Data/foundation_yasno_lookup.mm tests/macos/lookup_tests.h tests/macos/lookup_tests.mm
    app/yasno_lookup.h app/yasno_lookup_types.h app/https_contract.h app/https_resource.h app/https_resource.cpp
    tools/macos/doctor.sh tools/macos/check.sh "$verifier" "$manifest")
(cd "$repo" && /usr/bin/shasum -a 256 "${inputs[@]}") > "$run/inputs.sha256"
/usr/bin/xcodebuild -project "$repo/app/macos/DTEKMonitor.xcodeproj" \
    -scheme DTEKCoreProbe -configuration Debug -derivedDataPath "$run/DerivedData" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES \
    > "$run/build.log" 2>&1
probe="$run/DerivedData/Build/Products/Debug/DTEKCoreProbe"
[[ "$(/usr/bin/lipo -archs "$probe")" == arm64 ]]
/usr/bin/codesign --verify --strict "$probe" > "$run/signature.log" 2>&1
/usr/bin/otool -L "$probe" > "$run/linked-libraries.txt"
/usr/bin/shasum -a 256 "$probe" > "$run/executable.sha256"
base_env=(env -u DTEKMONITOR_TEST_ROOT -u DTEKMONITOR_TEST_PROFILE
    -u DTEKMONITOR_TEST_INSTANCE -u DTEKMONITOR_AUTOSTART_TEST_MODE -u DTEKMONITOR_DISABLE_PROVIDER)
expect_rejected() {
    name=$1
    shift
    code=0
    "$@" > "$run/$name.log" 2>&1 || code=$?
    [[ "$code" -eq 64 ]]
}
expect_rejected missing-envelope "${base_env[@]}" "$probe"
valid_env=("${base_env[@]}" DTEKMONITOR_TEST_ROOT="$run" DTEKMONITOR_TEST_PROFILE="$run/profile"
    DTEKMONITOR_TEST_INSTANCE="$(basename "$run")" DTEKMONITOR_AUTOSTART_TEST_MODE=1
    DTEKMONITOR_DISABLE_PROVIDER=1)
expect_rejected unsafe-profile "${valid_env[@]}" DTEKMONITOR_TEST_PROFILE="$run" "$probe"
expect_rejected invalid-instance "${valid_env[@]}" DTEKMONITOR_TEST_INSTANCE='../escape' "$probe"
expect_rejected real-backend "${valid_env[@]}" DTEKMONITOR_AUTOSTART_TEST_MODE=0 "$probe"
expect_rejected network-enabled "${valid_env[@]}" DTEKMONITOR_DISABLE_PROVIDER=0 "$probe"
mkdir "$run/symlink-case" "$run/outside"
ln -s "$run/outside" "$run/symlink-case/profile"
expect_rejected symlink-profile "${valid_env[@]}" DTEKMONITOR_TEST_ROOT="$run/symlink-case" \
    DTEKMONITOR_TEST_PROFILE="$run/symlink-case/profile" "$probe"
"${valid_env[@]}" "$probe" > "$run/probe.log" 2>&1
grep -q '^RESULT 67/67 portable checks; 3 bridge scenarios passed$' "$run/probe.log"
grep -q '^RESULT 60/60 Kyiv timezone checks passed$' "$run/probe.log" || exit 1
grep -q '^RESULT 111/111 Foundation data checks passed$' "$run/probe.log" || exit 1
grep -q '^RESULT 88/88 Foundation lookup checks passed$' "$run/probe.log" || exit 1
grep -q '^RESULT 26/26 monitor receipt bridge checks passed$' "$run/probe.log" || exit 1
"${valid_env[@]}" "$probe" --restore-data-probe > "$run/restart.log" 2>&1 || exit 1
grep -q '^RESULT 5/5 Foundation restart checks passed$' "$run/restart.log" || exit 1
(cd "$repo" && /usr/bin/shasum -a 256 -c "$run/inputs.sha256") > "$run/inputs-after.log"
/usr/bin/xcrun swift "$repo/$verifier" "$repo" > "$run/verified-after.json"
cmp "$run/verified-before.json" "$run/verified-after.json"
record portable_checks 67
record bridge_scenarios 3
record timezone_checks 60
record data_checks 111
record data_restart_checks 5
record lookup_checks 88
record monitor_bridge_checks 26
record rejected_envelopes 6
if [[ "$scope" == private-checkout ]]; then record preserved_files 504; fi
record evidence 'build.log, probe.log, inputs.sha256, signature.log, toolchain.txt, linked-libraries.txt'
