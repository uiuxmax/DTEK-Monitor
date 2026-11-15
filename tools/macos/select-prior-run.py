"""Validate a specific prior macOS harness result before consuming its output."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ('core', 'monitor'):
        raise SystemExit(64)
    kind, repo_arg, report_arg = sys.argv[1:]
    repo = Path(repo_arg).resolve(strict=True)
    report = Path(report_arg).resolve(strict=True)
    runs = (repo / 'out/macos').resolve(strict=True)
    prefix = 'check-' if kind == 'core' else 'monitor-ui-check-'
    if report.name != 'results.json' or report.parent.parent != runs or not report.parent.name.startswith(prefix):
        raise SystemExit('Prior result is outside the expected owned run directory')
    data = json.loads(report.read_bytes())
    head = subprocess.check_output(['/usr/bin/git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    if data.get('result') != 'PASS' or data.get('commit') != head or Path(data.get('checkout', '')).resolve() != repo:
        raise SystemExit('Prior result does not match this checkout and commit')
    run = report.parent
    subprocess.run(['/usr/bin/shasum', '-a', '256', '-c', str(run / 'inputs.sha256')], cwd=repo, check=True,
                   stdout=subprocess.DEVNULL)
    if kind == 'core':
        product = run / 'DerivedData/Build/Products/Debug/DTEKCoreProbe'
        recorded = (run / 'executable.sha256').read_text(encoding='utf-8').split('  ', 1)
        if len(recorded) != 2 or Path(recorded[1].strip()).resolve() != product.resolve(strict=True):
            raise SystemExit('Probe hash does not identify this run')
        if hashlib.sha256(product.read_bytes()).hexdigest() != recorded[0]:
            raise SystemExit('Probe changed after its test run')
    else:
        product = run / 'PersonalData/Build/Products/Release/DTEKMonitor.app'
        if not product.is_dir() or product.resolve() != product:
            raise SystemExit('Personal bundle is missing or redirected')
        expected = {product / 'Contents/MacOS/DTEKMonitor'} | {
            product / 'Contents/Resources' / name for name in
            ('power-on-v1.png', 'power-off-v1.png', 'notification-v1.png')}
        entries = (run / 'personal-files.sha256').read_text(encoding='utf-8').splitlines()
        seen = set()
        for entry in entries:
            parts = entry.split('  ', 1)
            if len(parts) != 2:
                raise SystemExit('Invalid personal bundle hash entry')
            path = Path(parts[1])
            if path not in expected or path.resolve(strict=True) != path or path in seen:
                raise SystemExit('Unexpected personal bundle hash path')
            if hashlib.sha256(path.read_bytes()).hexdigest() != parts[0]:
                raise SystemExit('Personal bundle changed after its test run')
            seen.add(path)
        if seen != expected:
            raise SystemExit('Personal bundle hash list is incomplete')
    print(product)


if __name__ == '__main__':
    main()
