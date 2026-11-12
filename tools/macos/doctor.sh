#!/bin/bash
# Read-only Mac/toolchain discovery; only the owned out/ report is written.
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    echo 'macOS is required; no files were written.' >&2
    exit 64
fi
if [[ "$(uname -m)" != arm64 ]]; then
    echo 'Use a native Apple Silicon terminal; Intel/Rosetta is outside this target.' >&2
    exit 64
fi
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
for directory in "$repo/out" "$repo/out/macos"; do
    if [[ -L "$directory" || ( -e "$directory" && ! -d "$directory" ) ]]; then
        echo "Unsafe output directory: $directory" >&2
        exit 64
    fi
    mkdir -p "$directory"
done
run=$(mktemp -d "$repo/out/macos/doctor-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
report="$run/environment.txt"
result=0
version=$(/usr/bin/sw_vers -productVersion)
selected=$(/usr/bin/xcode-select -p 2>/dev/null || true)
{
    printf 'checked_at_utc=%s\ncheckout=%s\narchitecture=arm64\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$repo"
    /usr/bin/sw_vers
    printf 'developer_directory=%s\n' "${selected:-NOT_CONFIGURED}"
    major=${version%%.*}
    if [[ "$major" -lt 13 ]]; then
        echo 'baseline=NEEDS_DECISION (proposed minimum is macOS 13)'
        result=2
    fi
    # Never invoke git/clang/Xcode installer shims when no toolchain exists.
    if [[ -n "$selected" && -x "$selected/usr/bin/xcodebuild" ]]; then
        if ! "$selected/usr/bin/xcodebuild" -version; then result=2; fi
        if ! /usr/bin/xcrun --sdk macosx --show-sdk-version; then result=2; fi
        if ! /usr/bin/xcrun --sdk macosx clang++ --version; then result=2; fi
        if ! /usr/bin/xcrun --sdk macosx swift --version; then result=2; fi
        if commit=$(/usr/bin/git -C "$repo" rev-parse HEAD 2>/dev/null); then
            printf 'commit=%s\n' "$commit"
        else
            echo 'commit=UNKNOWN (restore the local Git checkpoint first)'
            result=2
        fi
        if ! /usr/bin/git -C "$repo" diff --quiet HEAD --; then
            echo 'working_tree=MODIFIED'
        else
            echo 'working_tree=TRACKED_FILES_CLEAN'
        fi
    else
        echo 'toolchain=FULL_XCODE_REQUIRED (Command Line Tools alone are not this workflow)'
        echo 'Install a compatible Xcode, open it once, then select its Developer directory.'
        echo 'Compatibility: https://developer.apple.com/xcode/system-requirements'
        result=2
    fi
    if [[ "$result" -eq 0 ]]; then echo 'RESULT=READY'; else echo 'RESULT=NEEDS_SETUP'; fi
    echo 'No tools were installed; no login items, settings or certificates were changed.'
} > "$report" 2>&1
cat "$report"
printf 'Report: %s\n' "$report"
exit "$result"
