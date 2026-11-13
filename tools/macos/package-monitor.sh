#!/bin/bash
# Build verification artifact only. No upload, Release, provider or Login Item IO.
set -euo pipefail
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 && "$#" -eq 0 ]] || exit 64
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
reports=("$repo"/out/macos/monitor-ui-check-*/results.json)
[[ "${#reports[@]}" -eq 1 && -f "${reports[0]}" ]] || exit 64
build_root=$(dirname "${reports[0]}")
source_app="$build_root/PersonalData/Build/Products/Release/DTEKMonitor.app"
python3 - "${reports[0]}" "$repo" "$source_app" <<'PY'
import json,subprocess,sys
from pathlib import Path
report=json.loads(Path(sys.argv[1]).read_bytes())
assert report['result']=='PASS' and report['ui_checks']=='8' and report['fake_login_checks']=='14' and report['architecture']=='arm64'
assert report['commit']==subprocess.check_output(['/usr/bin/git','-C',sys.argv[2],'rev-parse','HEAD'],text=True).strip()
app=Path(sys.argv[3]); assert app.is_dir() and app.resolve()==app
PY
[[ "$?" -eq 0 ]] || exit 1
run=$(mktemp -d "$repo/out/macos/package-check-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
mkdir "$run/stage" "$run/extracted"
audit="$run/audit.py"
cat > "$audit" <<'PY'
import hashlib,json,plistlib,re,subprocess,sys
from pathlib import Path
bundle=Path(sys.argv[1]).resolve(strict=True)
info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='local.dtekmonitor.Monitor' and info['CFBundleExecutable']=='DTEKMonitor'
assert info['CFBundleShortVersionString']=='0.1.0' and info['CFBundleVersion']=='1'
assert info['LSMinimumSystemVersion']=='13.0' and info['LSUIElement'] is True
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(bundle)],check=True,capture_output=True)
signature=subprocess.run(['/usr/bin/codesign','-dv','--verbose=4',str(bundle)],check=True,capture_output=True,text=True).stderr
assert 'Signature=adhoc' in signature
files=[]; binaries=[]
def inside(path): return path==bundle or bundle in path.parents
def library_allowed(value,path):
    if value.startswith(('/System/Library/','/usr/lib/')): return True
    if value.startswith('@executable_path/'):
        target=bundle/'Contents/MacOS'/value.removeprefix('@executable_path/')
        return inside(target.resolve())
    if value.startswith('@loader_path/'):
        return inside((path.parent/value.removeprefix('@loader_path/')).resolve())
    if value.startswith('@rpath/libswift'): return True
    if value.startswith('@rpath/'):
        target=bundle/'Contents/Frameworks'/value.removeprefix('@rpath/')
        return target.exists() and inside(target.resolve())
    return False
for path in sorted(bundle.rglob('*')):
    relative=path.relative_to(bundle).as_posix()
    assert not any(part in {'.git','profile','out','tests','Fixtures'} or part.endswith('.xctest') for part in path.relative_to(bundle).parts),relative
    assert path.name not in {'settings.json','receipt.json','.DS_Store'} and path.suffix not in {'.log','.pem','.key','.der'},relative
    if path.is_symlink():
        assert inside(path.resolve(strict=True)),relative
        files.append(dict(path=relative,link=str(path.readlink())))
        continue
    if not path.is_file(): continue
    data=path.read_bytes()
    files.append(dict(path=relative,bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
    kind=subprocess.check_output(['/usr/bin/file','-b',str(path)],text=True)
    if 'Mach-O' not in kind: continue
    assert subprocess.check_output(['/usr/bin/lipo','-archs',str(path)],text=True).strip()=='arm64',relative
    libraries=subprocess.check_output(['/usr/bin/otool','-L',str(path)],text=True)
    for line in libraries.splitlines()[1:]:
        value=line.strip().split(' (compatibility version',1)[0]
        assert library_allowed(value,path),(relative,value)
    commands=subprocess.check_output(['/usr/bin/otool','-l',str(path)],text=True)
    minimums=re.findall(r'^\s+minos ([0-9.]+)',commands,re.MULTILINE)
    assert minimums,relative
    for minimum in minimums:
        parts=tuple(int(part) for part in minimum.split('.'))
        assert (parts+(0,0,0))[:3]<=(13,0,0),(relative,minimum)
    rpaths=re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset',commands)
    assert all(library_allowed(value,path) for value in rpaths),(relative,rpaths)
    binaries.append(dict(path=relative,architecture='arm64',minimum_os=minimums,linked_libraries=libraries,rpaths=rpaths))
assert binaries and any(item['path']=='Contents/MacOS/DTEKMonitor' for item in binaries)
report=dict(result='PASS',bundle_id=info['CFBundleIdentifier'],version=info['CFBundleShortVersionString'],build=info['CFBundleVersion'],
    minimum_os_declared='13.0; runtime acceptance on macOS 13 remains open',signature='ad-hoc',notarized=False,
    binaries=binaries,files=files,scope='Static audit only; personal app was not launched; Gatekeeper/sign-in/live acceptance open')
Path(sys.argv[2]).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
PY
python3 -B "$audit" "$source_app" "$run/source-audit.json" || exit 1
/usr/bin/ditto "$source_app" "$run/stage/DTEKMonitor.app" || exit 1
python3 -B "$audit" "$run/stage/DTEKMonitor.app" "$run/stage-audit.json" || exit 1
archive="$run/DTEKMonitor-0.1.0-macos-arm64.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$run/stage/DTEKMonitor.app" "$archive" || exit 1
/usr/bin/ditto -x -k "$archive" "$run/extracted" || exit 1
python3 -B "$audit" "$run/extracted/DTEKMonitor.app" "$run/extracted-audit.json" || exit 1
python3 - "$run" "$repo" <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
run,repo=map(Path,sys.argv[1:])
reports=[json.loads((run/name).read_bytes()) for name in ('source-audit.json','stage-audit.json','extracted-audit.json')]
assert all(report['result']=='PASS' for report in reports) and reports[0]['files']==reports[1]['files']==reports[2]['files']
archive=run/'DTEKMonitor-0.1.0-macos-arm64.zip'
report=dict(result='PASS',commit=subprocess.check_output(['/usr/bin/git','-C',str(repo),'rev-parse','HEAD'],text=True).strip(),
    artifact=archive.name,bytes=archive.stat().st_size,sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
    architecture='arm64',bundle_id='local.dtekmonitor.Monitor',signature='ad-hoc',notarized=False,uploaded=False,
    round_trip_file_hashes_match=True,macho_count=len(reports[0]['binaries']),
    limits='No personal app execution, provider requests, Login Item registration, physical display, macOS 13 runtime or Gatekeeper acceptance')
(run/'results.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
(run/'SHA256SUMS.txt').write_text(report['sha256']+'  '+archive.name+'\n',encoding='ascii')
print(json.dumps(report))
PY
[[ "$?" -eq 0 ]] || exit 1
printf 'Package results: %s\n' "$run/results.json"
