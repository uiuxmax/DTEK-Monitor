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
finish() {
    code=$?; trap - EXIT
    python3 - "$run" "$repo" "$code" <<'PY'
import json,subprocess,sys
from pathlib import Path
run,repo=map(Path,sys.argv[1:3]); code=int(sys.argv[3]); runner=run/'runner-results.json'
data=json.loads(runner.read_bytes()) if runner.is_file() else {}
data.update(result='PASS' if code==0 else 'FAIL',checkout=str(repo),
    commit=subprocess.check_output(['/usr/bin/git','-C',str(repo),'rev-parse','HEAD'],text=True).strip(),
    wrapper_exit_code=code)
(run/'results.json').write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
PY
    printf 'Results: %s\n' "$run/results.json"
    exit "$code"
}
trap finish EXIT
python3 -B "$repo/tests/macos/test_select_prior_run.py" > "$run/selector-tests.log" 2>&1
/usr/bin/xcrun swift "$repo/$verifier" "$repo" > "$run/verified-before.json"
if [[ -n "${DTEKMONITOR_CORE_RESULTS:-}" ]]; then
    prior="$DTEKMONITOR_CORE_RESULTS"
else
    reports=("$repo"/out/macos/check-*/results.json)
    [[ "${#reports[@]}" -eq 1 && -f "${reports[0]}" ]] || exit 64
    prior="${reports[0]}"
fi
probe=$(python3 -B "$repo/tools/macos/select-prior-run.py" core "$repo" "$prior") || exit 1
[[ "$(/usr/bin/lipo -archs "$probe")" == arm64 ]]
/usr/bin/codesign --verify --strict "$probe"
sources=(app/macos/Network/HTTPSAttempt.swift app/macos/Network/NetworkHTTPSAttempt.swift
    app/macos/Network/RawHTTPResponse.swift app/macos/Network/SessionPolicy.swift
    app/macos/Session/NativeLookupWorker.swift app/macos/Session/MonitorSession.swift)
(cd "$repo" && /usr/bin/shasum -a 256 "${sources[@]}" app/macos/Session/MonitorBridge.h \
    tests/macos/session_wire_server.py tests/macos/test_select_prior_run.py tools/macos/check-session.sh tools/macos/select-prior-run.py) > "$run/inputs.sha256"
# Type-check the production worker/actor without running it or a provider request.
production=()
for source in "${sources[@]}"; do production+=("$repo/$source"); done
/usr/bin/xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macosx13.0 \
    -parse-as-library -emit-module -module-name MonitorSessionCandidate \
    -import-objc-header "$repo/app/macos/Session/MonitorBridge.h" \
    -emit-module-path "$run/MonitorSessionCandidate.swiftmodule" "${production[@]}" \
    > "$run/production-build.log" 2>&1
env DTEKMONITOR_TEST_ROOT="$run" DTEKMONITOR_TEST_PROFILE="$run/profile" \
    DTEKMONITOR_TEST_INSTANCE="$(basename "$run")" DTEKMONITOR_AUTOSTART_TEST_MODE=1 DTEKMONITOR_DISABLE_PROVIDER=1 \
    python3 -B "$repo/tests/macos/session_wire_server.py" "$probe" "$run/profile" > "$run/runner.log" 2>&1
grep -q '^RESULT 24/24 connected session checks passed$' "$run/session.log"
(cd "$repo" && /usr/bin/shasum -a 256 -c "$run/inputs.sha256") > "$run/inputs-after.log"
/usr/bin/xcrun swift "$repo/$verifier" "$repo" > "$run/verified-after.json"
cmp "$run/verified-before.json" "$run/verified-after.json"
