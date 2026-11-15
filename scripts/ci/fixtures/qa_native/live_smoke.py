"""Optional real-runner end-to-end capture/check. Retains clean git probes and logs.
Usage: python live_smoke.py NEW_OUTPUT_DIRECTORY
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
TOOL = HERE.parents[1] / 'qa_evidence.py'


def main():
    out = Path(sys.argv[1]).resolve()
    out.mkdir(parents=True, exist_ok=False)
    flutter = os.environ.get('FLUTTER', shutil.which('flutter') or str(Path.home() / 'flutter/bin/flutter'))
    summaries = {}
    for runner in ('node', 'pytest', 'flutter'):
        root = out / runner
        repo = root / 'repo'
        repo.mkdir(parents=True)
        def git(*args):
            return subprocess.check_output(['git', *args], cwd=repo, text=True).strip()
        git('init', '-q')
        git('config', 'user.email', 'qa@example.invalid')
        git('config', 'user.name', 'QA native probe')
        filename = {'node': 'probe.cjs', 'pytest': 'test_probe.py', 'flutter': 'probe_test.dart'}[runner]
        if runner == 'flutter':
            (repo / 'pubspec.yaml').write_text('name: qa_native_probe\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n')
            (repo / '.gitignore').write_text('.dart_tool/\nbuild/\n')
            result = subprocess.run([flutter, 'pub', 'get'], cwd=repo, capture_output=True)
            (root / 'setup.log').write_bytes(result.stdout + result.stderr)
            result.check_returncode()
        else:
            (repo / '.gitignore').write_text('__pycache__/\n.pytest_cache/\n')
        shas = {}
        for phase, mode, expected in [('before', 'assertion', 1), ('after', 'pass', 0)]:
            shutil.copyfile(HERE / f'{runner}-{mode}' / filename, repo / filename)
            git('add', '.')
            git('commit', '-qm', phase)
            shas[phase] = git('rev-parse', 'HEAD')
            xml = root / f'{phase}.xml'
            commands = {
                'node': ['node', '--test', '--test-reporter=junit', f'--test-reporter-destination={xml}', filename],
                'pytest': ['pytest', '-q', '-p', 'no:cacheprovider', f'--junitxml={xml}', filename],
                'flutter': [flutter, 'test', '--reporter=json', filename],
            }
            flags = ['--flutter-json'] if runner == 'flutter' else ['--junit', str(xml)]
            result = subprocess.run([sys.executable, str(TOOL), 'run', '--cwd', str(repo), '--out', str(root / phase), *flags, '--', *commands[runner]], capture_output=True)
            (root / f'{phase}-capture.log').write_bytes(result.stdout + result.stderr)
            assert result.returncode == expected, (runner, phase, result.returncode, result.stderr)
        identity = {'node': ('test', 'authority'), 'pytest': ('test_probe', 'test_authority'), 'flutter': (filename, 'authority')}[runner]
        report = {'candidate_sha': shas['after'], 'rules': [{
            'id': 'authority', 'rule': 'fixture assertion', 'entry': filename, 'status': 'tested',
            'run': 'after/run.json', 'testcase': dict(zip(('classname', 'name'), identity)),
            'before': {'run': 'before/run.json', 'sha': shas['before'], 'assertion': 'authority must remain NEW'}}]}
        report_path = root / 'report.json'
        report_path.write_text(json.dumps(report, indent=2))
        result = subprocess.run([sys.executable, str(TOOL), 'check', str(report_path), '--candidate', shas['after'], '--require', 'authority', '--require-regression', 'authority'], capture_output=True)
        (root / 'check.json').write_bytes(result.stdout)
        (root / 'check.stderr').write_bytes(result.stderr)
        result.check_returncode()
        summaries[runner] = json.loads(result.stdout)
    (out / 'summary.json').write_text(json.dumps(summaries, indent=2) + '\n')
    print(json.dumps(summaries, indent=2))


if __name__ == '__main__':
    main()
