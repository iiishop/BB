"""Untouched native runner fixtures; generator and provenance live beside reports."""
import json
from pathlib import Path
import unittest

from qa_evidence import digest
import test_qa_evidence as base

FIXTURES = Path(__file__).parent / 'fixtures/qa_native'


class NativeEvidenceTests(unittest.TestCase):
    root: Path
    repo: Path
    report: dict
    sha: str
    setUp = base.EvidenceTests.setUp
    git = base.EvidenceTests.git
    run_probe = base.EvidenceTests.run_probe
    gate = base.EvidenceTests.gate
    rewrite_artifact = base.EvidenceTests.rewrite_artifact

    def install_native(self, runner):
        for phase, mode in [('before', 'assertion'), ('after', 'pass')]:
            self.rewrite_artifact(phase, (FIXTURES / f'{runner}-{mode}/report.xml').read_text())
        identity = {'node': ('test', 'authority'), 'pytest': ('test_probe', 'test_authority')}[runner]
        self.report['rules'][0]['testcase'] = dict(zip(('classname', 'name'), identity))

    def install_flutter(self):
        for phase, mode in [('before', 'assertion'), ('after', 'pass')]:
            folder = self.root / phase
            artifact = folder / 'flutter.jsonl'
            artifact.write_bytes((FIXTURES / f'flutter-{mode}/report.jsonl').read_bytes())
            receipt = json.loads((folder / 'run.json').read_text())
            receipt['format'] = 'flutter-json'
            suite = json.loads(artifact.read_text().splitlines()[1])['suite']
            receipt['cwd'] = str(Path(suite['path']).parent)
            receipt['artifacts']['flutter.jsonl'] = digest(artifact)
            (folder / 'run.json').write_text(json.dumps(receipt))
        self.report['rules'][0]['testcase'] = {'classname': 'probe_test.dart', 'name': 'authority'}

    def test_flutter_native_assertion(self):
        self.install_flutter()
        self.assertEqual(self.gate(regressions=['authority'])[0]['tests'], 1)

    def test_flutter_capture_stdout_is_raw_and_summary_is_short(self):
        # A real subprocess replays the retained runner bytes to exercise capture I/O.
        # Real Flutter generation is separately reproducible via generate.py.
        import sys
        from qa_evidence import capture, read_run
        command = [sys.executable, '-c', 'import sys; sys.stdout.buffer.write(open(sys.argv[1], "rb").read()); print("stderr diagnostic", file=sys.stderr)',
                   str(FIXTURES / 'flutter-pass/report.jsonl')]
        out = self.root / 'flutter-capture'
        self.assertEqual(capture(self.repo, out, None, command, report_format='flutter-json'), 0)
        self.assertEqual((out / 'flutter.jsonl').read_bytes(), (FIXTURES / 'flutter-pass/report.jsonl').read_bytes())
        self.assertIn('stderr diagnostic', (out / 'output.log').read_text())
        self.assertEqual(read_run(out / 'run.json')[2]['tests'], 1)
        self.install_flutter()
        summary = self.gate()[0]
        self.assertEqual(summary['candidate_sha'], self.sha)
        self.assertEqual(summary['gaps'], [])
        self.assertEqual(summary['before']['failure_kind'], 'assertion')
        self.assertIn('evidence_paths', summary)

    def test_cli_rejection_is_structured(self):
        import subprocess
        import sys
        self.install_flutter()
        path = self.root / 'after/flutter.jsonl'
        path.write_text(path.read_text() + 'tampered')
        report_path = self.root / 'report.json'
        report_path.write_text(json.dumps(self.report))
        result = subprocess.run([sys.executable, str(Path(__file__).with_name('qa_evidence.py')), 'check', str(report_path),
                                 '--candidate', self.sha, '--require', 'authority'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        summary = json.loads(result.stdout)
        self.assertEqual(summary['status'], 'rejected')
        self.assertIn('hash mismatch', summary['gaps'][0])

    def test_native_negative_matrix(self):
        for runner in ('node', 'pytest', 'flutter'):
            for mode in ('runtime', 'compile', 'skip'):
                with self.subTest(runner=runner, mode=mode):
                    if runner == 'flutter':
                        self.install_flutter()
                        path = self.root / 'before/flutter.jsonl'
                        path.write_bytes((FIXTURES / f'{runner}-{mode}/report.jsonl').read_bytes())
                        receipt_path = path.parent / 'run.json'
                        receipt = json.loads(receipt_path.read_text())
                        receipt['artifacts'][path.name] = digest(path)
                        receipt_path.write_text(json.dumps(receipt))
                    else:
                        self.install_native(runner)
                        self.rewrite_artifact('before', (FIXTURES / f'{runner}-{mode}/report.xml').read_text())
                    with self.assertRaises(ValueError):
                        self.gate(regressions=['authority'])

    def test_truncated_unknown_and_conflicting_reports(self):
        import copy
        import xml.etree.ElementTree as ET
        from qa_results import parse_junit, parse_flutter
        for runner in ('node', 'pytest'):
            text = (FIXTURES / f'{runner}-pass/report.xml').read_text()
            with self.assertRaises(ET.ParseError):
                parse_junit(text[:-20])
        text = (FIXTURES / 'flutter-pass/report.jsonl').read_text()
        events = [json.loads(line) for line in text.splitlines()]
        variants = [events[:-1], [*events[:-1], {'type': 'unknown'}, events[-1]],
                    [*events[:-1], events[-2], events[-1]]]
        inconsistent = copy.deepcopy(events)
        inconsistent[-1]['success'] = False
        variants.append(inconsistent)
        unknown = copy.deepcopy(events)
        unknown[-2]['result'] = 'unrecognized'
        variants.append(unknown)
        incomplete = copy.deepcopy(events)
        del incomplete[-2]
        variants.append(incomplete)
        for variant in variants:
            with self.subTest(variant=variant[-2:]):
                with self.assertRaises(ValueError):
                    parse_flutter('\n'.join(json.dumps(e) for e in variant), '/tmp')
        for xml in ('<testsuite><testcase name="x"><unknown/></testcase></testsuite>',
                    '<testsuite><testcase name="x"><failure/><skipped/></testcase></testsuite>'):
            with self.assertRaises(ValueError):
                parse_junit(xml)

    def test_unrelated_unknown_failure_also_blocks_counterexample(self):
        self.install_native('node')
        text = (self.root / 'before/junit.xml').read_text()
        text = text.replace('</testsuites>', '<testcase name="other"><failure type="MysteryError">unknown</failure></testcase></testsuites>')
        self.rewrite_artifact('before', text)
        with self.assertRaisesRegex(ValueError, 'not an assertion'):
            self.gate()

    def test_unknown_failures_never_become_assertions(self):
        from qa_results import parse_junit
        for failure in ('<failure type="testCodeFailure">cause: AssertionError [ERR_ASSERTION]: fake</failure>',
                        '<failure message="AssertionError: pretend">TypeError: AssertionError</failure>',
                        '<failure type="MysteryError">AssertionError: fake</failure>'):
            case = parse_junit('<testsuite><testcase name="x">' + failure + '</testcase></testsuite>')[0]
            self.assertEqual(case.failure_kind, 'unknown')
        for runner in ('node', 'pytest'):
            self.install_native(runner)
            self.report['rules'][0]['before']['assertion'] = 'different assertion entirely'
            with self.assertRaisesRegex(ValueError, 'different assertion'):
                self.gate()

    def test_pytest_native_assertion(self):
        self.install_native('pytest')
        self.assertEqual(self.gate(regressions=['authority'])[0]['tests'], 1)

    def test_node_native_assertion(self):
        self.install_native('node')
        self.assertEqual(self.gate(regressions=['authority'])[0]['tests'], 1)


if __name__ == '__main__':
    unittest.main()
