"""Regenerate untouched runner artifacts; requires Node, pytest and Flutter.
Run explicitly, never during stdlib-only CI. Sources and raw stdout/stderr retained.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def main():
    flutter = os.environ.get('FLUTTER', shutil.which('flutter') or str(Path.home() / 'flutter/bin/flutter'))
    versions = {}
    for name, command in [('node', ['node', '--version']), ('pytest', ['pytest', '--version']),
                          ('flutter', [flutter, '--version'])]:
        versions[name] = subprocess.check_output(command, text=True).strip()
    records = []
    with tempfile.TemporaryDirectory(prefix='qa-native-') as tmp:
        work = Path(tmp)
        (work / 'pubspec.yaml').write_text('name: qa_native_probe\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n')
        setup = subprocess.run([flutter, 'pub', 'get'], cwd=work, capture_output=True)
        (ROOT / 'flutter-setup.log').write_bytes(setup.stdout + setup.stderr)
        setup.check_returncode()
        for runner in ('node', 'pytest', 'flutter'):
            for mode in ('pass', 'assertion', 'runtime', 'skip', 'compile'):
                dest = ROOT / f'{runner}-{mode}'
                dest.mkdir(exist_ok=True)
                if runner == 'node':
                    body = {'pass': 'assert.equal(1, 1)', 'assertion': "assert.equal(1, 2, 'authority must remain NEW')", 'runtime': "throw new TypeError('authority must remain NEW')", 'skip': '', 'compile': 'const = broken'}[mode]
                    source = "const {test} = require('node:test'); const assert = require('node:assert/strict');\n" + (body if mode == 'compile' else f"test('authority', {{skip: {str(mode == 'skip').lower()}}}, () => {{ {body}; }});\n")
                    filename = 'probe.cjs'
                    command = ['node', '--test', '--test-reporter=junit', filename]
                elif runner == 'pytest':
                    body = {'pass': 'assert 1 == 1', 'assertion': 'assert 1 == 2, "authority must remain NEW"', 'runtime': 'raise TypeError("authority must remain NEW")', 'skip': 'pytest.skip("platform")', 'compile': 'assert = broken'}[mode]
                    source = f'import pytest\ndef test_authority():\n    {body}\n'
                    filename = 'test_probe.py'
                    command = ['pytest', '-q', '-p', 'no:cacheprovider', '--junitxml=result.xml', filename]
                else:
                    body = {'pass': 'expect(1, 1);', 'assertion': "expect(1, 2, reason: 'authority must remain NEW');", 'runtime': "throw StateError('authority must remain NEW');", 'skip': '', 'compile': 'this is not valid Dart;'}[mode]
                    source = "import 'package:flutter_test/flutter_test.dart';\nvoid main() { test('authority', () { " + body + " }, skip: " + str(mode == 'skip').lower() + "); }\n"
                    filename = 'probe_test.dart'
                    command = [flutter, 'test', '--reporter=json', filename]
                (work / filename).write_text(source)
                (dest / filename).write_text(source)
                result = subprocess.run(command, cwd=work, capture_output=True)
                (dest / 'stdout.log').write_bytes(result.stdout)
                (dest / 'stderr.log').write_bytes(result.stderr)
                if runner == 'pytest':
                    shutil.copyfile(work / 'result.xml', dest / 'report.xml')
                else:
                    (dest / ('report.jsonl' if runner == 'flutter' else 'report.xml')).write_bytes(result.stdout)
                records.append(dict(runner=runner, mode=mode, command=command, exit_code=result.returncode))
    (ROOT / 'provenance.json').write_text(json.dumps(dict(versions=versions, runs=records), indent=2) + '\n')
    print(json.dumps(records, indent=2))


if __name__ == '__main__':
    main()
