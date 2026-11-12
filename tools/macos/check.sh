#!/bin/bash
# M1 only: native arm64 console probe. No widget UI or provider requests.
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
record scope 'M1 synthetic core and bridge only; no macOS UI/live/timezone/login acceptance'
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
inputs=(app/macos/CoreProbe/main.swift app/macos/CoreProbe/CoreProbeBridge.h
    app/macos/CoreProbe/CoreProbeBridge.mm app/macos/CoreProbe/BridgingHeader.h
    app/macos/DTEKMonitor.xcodeproj/project.pbxproj
    app/macos/DTEKMonitor.xcodeproj/xcshareddata/xcschemes/DTEKCoreProbe.xcscheme
    research/schedule-engine/schedule_engine.h research/schedule-engine/schedule_engine.cpp
    research/schedule-engine/test_support.h research/schedule-engine/portable_tests.cpp
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
(cd "$repo" && /usr/bin/shasum -a 256 -c "$run/inputs.sha256") > "$run/inputs-after.log"
/usr/bin/xcrun swift "$repo/$verifier" "$repo" > "$run/verified-after.json"
cmp "$run/verified-before.json" "$run/verified-after.json"
record portable_checks 67
record bridge_scenarios 3
record rejected_envelopes 6
if [[ "$scope" == private-checkout ]]; then record preserved_files 504; fi
record evidence 'build.log, probe.log, inputs.sha256, signature.log, toolchain.txt, linked-libraries.txt'
