"""Portable validation of prior-run selection; does not execute a macOS app."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('select_prior_run', ROOT / 'tools/macos/select-prior-run.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.base = ROOT / 'out/prior-run-tests'
        self.base.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=self.base)
        self.repo = Path(self.temp.name).resolve()
        self.assertTrue(self.repo.is_relative_to(self.base.resolve()))
        self.run = self.repo / 'out/macos/check-test'
        self.probe = self.run / 'DerivedData/Build/Products/Debug/DTEKCoreProbe'
        self.probe.parent.mkdir(parents=True)
        self.probe.write_bytes(b'owned synthetic probe')
        (self.run / 'inputs.sha256').write_text('fixture', encoding='utf-8')
        digest = hashlib.sha256(self.probe.read_bytes()).hexdigest()
        (self.run / 'executable.sha256').write_text(digest + '  ' + str(self.probe) + '\n', encoding='utf-8')
        self.report = self.run / 'results.json'
        self.report.write_text(json.dumps({'result': 'PASS', 'checkout': str(self.repo), 'commit': 'head'}), encoding='utf-8')

    def tearDown(self):
        self.assertTrue(Path(self.temp.name).resolve().is_relative_to(self.base.resolve()))
        self.temp.cleanup()

    def select(self):
        with patch.object(module.sys, 'argv', ['selector', 'core', str(self.repo), str(self.report)]), \
             patch.object(module.subprocess, 'check_output', return_value='head\n'), \
             patch.object(module.subprocess, 'run') as shasum, contextlib.redirect_stdout(io.StringIO()) as output:
            module.main()
            self.assertTrue(shasum.called)
            return output.getvalue().strip()

    def test_exact_successful_run(self):
        self.assertEqual(self.select(), str(self.probe))

    def test_rejects_modified_executable(self):
        self.probe.write_bytes(b'changed')
        with self.assertRaises(SystemExit):
            self.select()

    def test_rejects_failed_or_different_commit(self):
        for result, commit in [('FAIL', 'head'), ('PASS', 'other')]:
            self.report.write_text(json.dumps({'result': result, 'checkout': str(self.repo), 'commit': commit}), encoding='utf-8')
            with self.assertRaises(SystemExit):
                self.select()

    def test_rejects_report_outside_owned_run(self):
        self.report = self.repo / 'results.json'
        self.report.write_text('{}', encoding='utf-8')
        with self.assertRaises(SystemExit):
            self.select()


if __name__ == '__main__':
    unittest.main()
