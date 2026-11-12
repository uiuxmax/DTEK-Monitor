#!/bin/bash
# M6 worker/receipt/actor integration; synthetic loopback only.
set -euo pipefail
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || exit 64
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
if [[ "$#" -eq 1 && "$1" == --public-probe ]]; then
    [[ ! -e "$repo/tools/preserved-files.json" && -f "$repo/tools/macos/probe-inputs.json" ]] || exit 64
    verifier=tools/macos/verify-probe-inputs.swift
elif [[ "$#" -eq 0 ]]; then verifier=tools/macos/verify-preserved.swift
else exit 64; fi
run=$(mktemp -d "$repo/out/macos/session-check-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
mkdir "$run/profile"
/usr/bin/xcrun swift "$repo/$verifier" "$repo" > "$run/verified-before.json"
probes=("$repo"/out/macos/check-*/DerivedData/Build/Products/Debug/DTEKCoreProbe)
[[ "${#probes[@]}" -eq 1 && -f "${probes[0]}" ]] || exit 64
probe="${probes[0]}"
[[ "$(/usr/bin/lipo -archs "$probe")" == arm64 ]]
/usr/bin/codesign --verify --strict "$probe"
env DTEKMONITOR_TEST_ROOT="$run" DTEKMONITOR_TEST_PROFILE="$run/profile" \
    DTEKMONITOR_TEST_INSTANCE="$(basename "$run")" DTEKMONITOR_AUTOSTART_TEST_MODE=1 DTEKMONITOR_DISABLE_PROVIDER=1 \
    python3 -B "$repo/tests/macos/session_wire_server.py" "$probe" "$run/profile" > "$run/runner.log" 2>&1
grep -q '^RESULT 16/16 connected session checks passed$' "$run/session.log"
/usr/bin/xcrun swift "$repo/$verifier" "$repo" > "$run/verified-after.json"
cmp "$run/verified-before.json" "$run/verified-after.json"
printf 'Results: %s\n' "$run/results.json"
