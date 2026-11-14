#!/bin/bash
# Controlled native M5 measurements; no provider traffic or trust-store changes.
set -euo pipefail
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then exit 64; fi
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
candidate=urlsession
if [[ "${1-}" == --network-candidate ]]; then candidate=network; shift; fi
if [[ "$#" -eq 1 && "$1" == --public-probe ]]; then
    [[ ! -e "$repo/tools/preserved-files.json" && -f "$repo/tools/macos/probe-inputs.json" ]] || exit 64
    verifier=tools/macos/verify-probe-inputs.swift
elif [[ "$#" -eq 0 ]]; then
    verifier=tools/macos/verify-preserved.swift
else
    exit 64
fi
mkdir -p "$repo/out/macos"
run=$(mktemp -d "$repo/out/macos/https-check-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
mkdir "$run/profile"
/usr/bin/xcrun swift "$repo/$verifier" "$repo" > "$run/verified-before.json" || exit 1
inputs=(app/macos/Network/HTTPSAttempt.swift app/macos/FixtureWidget/TestEnvelope.swift
    tests/macos/HTTPSProbe.swift tests/macos/https_wire_server.py tools/macos/check-https.sh "$verifier")
extra_sources=()
production_sources=()
extra_flags=()
wire_flags=()
if [[ "$candidate" == network ]]; then
    extra_sources=("$repo/app/macos/Network/RawHTTPResponse.swift" "$repo/app/macos/Network/NetworkHTTPSAttempt.swift" "$repo/tests/macos/RawHTTPTests.swift" "$repo/app/macos/Network/SessionPolicy.swift" "$repo/tests/macos/SessionPolicyTests.swift")
    production_sources=("$repo/app/macos/Network/RawHTTPResponse.swift" "$repo/app/macos/Network/NetworkHTTPSAttempt.swift" "$repo/app/macos/Network/SessionPolicy.swift")
    inputs+=(app/macos/Network/RawHTTPResponse.swift app/macos/Network/NetworkHTTPSAttempt.swift tests/macos/RawHTTPTests.swift app/macos/Network/SessionPolicy.swift tests/macos/SessionPolicyTests.swift)
    extra_flags=(-D DTEKMONITOR_NETWORK_CANDIDATE)
    wire_flags=(--network)
fi
(cd "$repo" && /usr/bin/shasum -a 256 "${inputs[@]}") > "$run/inputs.sha256"
/usr/bin/xcrun swiftc -swift-version 5 -D DTEKMONITOR_MAC_TEST_BUILD -target arm64-apple-macosx13.0 \
    ${extra_flags[@]+"${extra_flags[@]}"} ${extra_sources[@]+"${extra_sources[@]}"} \
    "$repo/app/macos/Network/HTTPSAttempt.swift" "$repo/app/macos/FixtureWidget/TestEnvelope.swift" \
    "$repo/tests/macos/HTTPSProbe.swift" -o "$run/HTTPSProbe" > "$run/build.log" 2>&1 || exit 1
[[ "$(/usr/bin/lipo -archs "$run/HTTPSProbe")" == arm64 ]] || exit 1
/usr/bin/codesign --verify --strict "$run/HTTPSProbe" > "$run/signature.log" 2>&1 || exit 1
# Compile the normal-TLS branch too, without starting an executable or provider request.
/usr/bin/xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -parse-as-library -emit-module \
    -emit-module-path "$run/HTTPSCandidate.swiftmodule" "$repo/app/macos/Network/HTTPSAttempt.swift" \
    ${production_sources[@]+"${production_sources[@]}"} \
    > "$run/production-build.log" 2>&1 || exit 1
base=(env -u DTEKMONITOR_TEST_ROOT -u DTEKMONITOR_TEST_PROFILE -u DTEKMONITOR_TEST_INSTANCE
    -u DTEKMONITOR_AUTOSTART_TEST_MODE -u DTEKMONITOR_DISABLE_PROVIDER)
valid=("${base[@]}" DTEKMONITOR_TEST_ROOT="$run" DTEKMONITOR_TEST_PROFILE="$run/profile"
    DTEKMONITOR_TEST_INSTANCE="$(basename "$run")" DTEKMONITOR_AUTOSTART_TEST_MODE=1 DTEKMONITOR_DISABLE_PROVIDER=1)
reject() {
    local code=0
    "$@" > "$run/rejected.log" 2>&1 || code=$?
    [[ "$code" -eq 64 ]] || exit 1
}
reject "${base[@]}" "$run/HTTPSProbe" 1 trusted 2000 "$run/profile/rejected.json"
reject "${valid[@]}" DTEKMONITOR_DISABLE_PROVIDER=0 "$run/HTTPSProbe" 1 trusted 2000 "$run/profile/rejected.json"
reject "${valid[@]}" DTEKMONITOR_TEST_PROFILE="$run" "$run/HTTPSProbe" 1 trusted 2000 "$run/profile/rejected.json"
"${valid[@]}" "$run/HTTPSProbe" --resources > "$run/resources.log" 2>&1 || exit 1
grep -q '^RESULT 16/16 resource and provider-guard checks passed$' "$run/resources.log" || exit 1
if [[ "$candidate" == network ]]; then
    "${valid[@]}" "$run/HTTPSProbe" --parser > "$run/parser.log" 2>&1 || exit 1
    grep -q '^RESULT 248/248 raw HTTP parser checks passed; 81 vectors with 3 segment sizes$' "$run/parser.log" || exit 1
    "${valid[@]}" "$run/HTTPSProbe" --lifecycle > "$run/lifecycle.log" 2>&1 || exit 1
    grep -q '^RESULT 49/49 lifecycle policy checks passed$' "$run/lifecycle.log" || exit 1
fi
python_path=$(command -v python3)
"${valid[@]}" "$python_path" -B "$repo/tests/macos/https_wire_server.py" "$run/HTTPSProbe" "$run/profile" ${wire_flags[@]+"${wire_flags[@]}"} \
    > "$run/wire.log" 2>&1 || exit 1
"$python_path" - "$run/results.json" "$candidate" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding='utf-8'))
assert report['result'] == 'PASS' and report['readiness'] == 'PARTIAL'
cases = report['cases']
assert len({case['case'] for case in cases}) == len(cases)
if sys.argv[2] == 'network':
    assert report['transport'] == 'Network.framework/raw HTTP1'
    assert report['critical_transport_checks'] == 'PASS' and len(cases) == 37
else:
    assert report['transport'] == 'URLSession' and len(cases) == 21
print('PASS: primary wire report agrees with the requested candidate and exact case count')
PY
[[ "$?" -eq 0 ]] || exit 1
(cd "$repo" && /usr/bin/shasum -a 256 -c "$run/inputs.sha256") > "$run/inputs-after.log" || exit 1
/usr/bin/xcrun swift "$repo/$verifier" "$repo" > "$run/verified-after.json" || exit 1
cmp "$run/verified-before.json" "$run/verified-after.json" || exit 1
/usr/bin/git -C "$repo" rev-parse HEAD > "$run/commit.txt"
printf '%s\n' 'M5 measurements completed. Readiness remains PARTIAL; see results.json.'
