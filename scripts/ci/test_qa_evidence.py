"""Real subprocess positives/target-assertion negatives; no model calls."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from qa_evidence import capture, check, digest

# Tiny stdlib runner fixture: failures come from executed assertions, not canned XML.
RUNNER = '''import sys, xml.etree.ElementTree as ET
root = ET.Element('testsuite')
case = ET.SubElement(root, 'testcase', classname='probe', name='authority')
code = 0
try:
    assert sys.argv[2] == 'pass', 'authority must remain NEW'
except AssertionError as exc:
    ET.SubElement(case, 'failure', type='AssertionError').text = str(exc)
    code = 1
ET.ElementTree(root).write(sys.argv[1])
sys.exit(code)
'''


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.email', 'qa@example.invalid')
        self.git('config', 'user.name', 'QA fixture')
        (self.repo / 'runner.py').write_text(RUNNER)
        self.git('add', '.')
        self.git('commit', '-qm', 'before')
        self.before = self.git('rev-parse', 'HEAD')
        self.assertEqual(self.run_probe('before', 'fail'), 1)
        (self.repo / 'change').write_text('candidate fixture')
        self.git('add', '.')
        self.git('commit', '-qm', 'after')
        self.sha = self.git('rev-parse', 'HEAD')
        self.assertEqual(self.run_probe('after', 'pass'), 0)
        self.report = {'candidate_sha': self.sha, 'rules': [{
            'id': 'authority', 'rule': 'old result cannot replace new',
            'entry': 'store loadCurrentTask', 'status': 'tested',
            'run': 'after/run.json', 'testcase': {'classname': 'probe', 'name': 'authority'},
            'before': {'run': 'before/run.json', 'sha': self.before,
                       'assertion': 'authority must remain NEW'}}]}

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.repo, text=True).strip()

    def run_probe(self, name, mode):
        xml = self.root / f'{name}.xml'
        return capture(self.repo, self.root / name, xml,
                       [sys.executable, 'runner.py', str(xml), mode])

    def gate(self, report=None, required=None, regressions=()):
        path = self.root / 'report.json'
        path.write_text(json.dumps(report or self.report))
        return check(path, self.sha, required or ['authority'], regressions)

    def rewrite_artifact(self, folder, xml):
        path = self.root / folder
        (path / 'junit.xml').write_text(xml)
        receipt = json.loads((path / 'run.json').read_text())
        receipt['artifacts']['junit.xml'] = digest(path / 'junit.xml')
        (path / 'run.json').write_text(json.dumps(receipt))

    def test_real_positive_and_target_assertion_negative(self):
        self.assertEqual(self.gate()[0]['tests'], 1)
        failed = copy.deepcopy(self.report)
        failed['rules'][0]['run'] = 'before/run.json'
        with self.assertRaisesRegex(ValueError, 'candidate mismatch'):
            self.gate(failed)
        self.assertEqual(self.run_probe('red_candidate', 'fail'), 1)
        failed['rules'][0]['run'] = 'red_candidate/run.json'
        with self.assertRaisesRegex(ValueError, 'candidate tests failed'):
            self.gate(failed)

    def test_missing_required_and_untested(self):
        with self.assertRaisesRegex(ValueError, 'required rule missing'):
            self.gate(required=['authority', 'browser'])
        self.report['rules'][0]['status'] = 'not_run'
        with self.assertRaisesRegex(ValueError, 'untested'):
            self.gate()

    def test_hash_tampering(self):
        (self.root / 'after/output.log').write_text('made up')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            self.gate()

    def test_empty_skipped_error_and_forged_totals(self):
        for xml, reason in [
            ('<testsuite tests="100"/>', 'no collected'),
            ('<testsuite><testcase name="x"><skipped/></testcase></testsuite>', 'no executed'),
            ('<testsuite><testcase name="x"><error/></testcase></testsuite>', 'environment/runner'),
            ('<testsuite tests="100"><testcase name="x"/></testsuite>', 'disagrees'),
        ]:
            with self.subTest(reason=reason):
                self.rewrite_artifact('after', xml)
                with self.assertRaisesRegex(ValueError, reason):
                    self.gate()

    def test_before_wrong_failure_is_not_counterexample(self):
        for kind, text, reason in [('Error', 'module not found', 'not an assertion'),
                                    ('AssertionError', 'unrelated failure', 'different assertion')]:
            self.rewrite_artifact('before', f'<testsuite><testcase classname="probe" name="authority"><failure type="{kind}">{text}</failure></testcase></testsuite>')
            with self.assertRaisesRegex(ValueError, reason):
                self.gate()

    def test_missing_target_and_duplicate_rules(self):
        self.report['rules'][0]['testcase']['name'] = 'invented'
        with self.assertRaisesRegex(ValueError, 'target testcase missing'):
            self.gate()
        self.report['rules'].append(copy.deepcopy(self.report['rules'][0]))
        with self.assertRaisesRegex(ValueError, 'duplicate rule'):
            self.gate()

    def test_stale_junit_and_dirty_source(self):
        with self.assertRaisesRegex(ValueError, 'JUnit already exists'):
            capture(self.repo, self.root / 'stale', self.root / 'after.xml', ['unused'])
        (self.repo / 'change').write_text('dirty')
        self.assertEqual(self.run_probe('dirty', 'pass'), 0)
        self.report['rules'][0]['run'] = 'dirty/run.json'
        with self.assertRaisesRegex(ValueError, 'dirty source'):
            self.gate()

    def test_regression_requires_before_but_acceptance_does_not(self):
        self.assertEqual(self.gate(regressions=['authority'])[0]['tests'], 1)
        del self.report['rules'][0]['before']
        self.assertEqual(self.gate()[0]['tests'], 1)
        with self.assertRaisesRegex(ValueError, 'required regression missing before'):
            self.gate(regressions=['authority'])
        with self.assertRaisesRegex(ValueError, 'required rule missing'):
            self.gate(regressions=['omitted'])

    def test_unrelated_skip_is_reported_but_required_skip_blocks(self):
        self.rewrite_artifact('after', '<testsuite><testcase classname="probe" name="authority"/><testcase name="platform"><skipped/></testcase></testsuite>')
        result = self.gate()[0]
        self.assertEqual((result['tests'], result['skipped']), (2, 1))
        self.rewrite_artifact('after', '<testsuite><testcase classname="probe" name="authority"><skipped/></testcase><testcase name="other"/></testsuite>')
        with self.assertRaisesRegex(ValueError, 'required testcase skipped'):
            self.gate()

    def test_source_mutation_during_real_command(self):
        xml = self.root / 'mutation.xml'
        code = "from pathlib import Path; import subprocess, sys; Path('change').write_text('mutated'); sys.exit(subprocess.call([sys.executable, 'runner.py', sys.argv[1], 'pass']))"
        self.assertEqual(capture(self.repo, self.root / 'mutation', xml,
                                 [sys.executable, '-c', code, str(xml)]), 0)
        self.report['rules'][0]['run'] = 'mutation/run.json'
        with self.assertRaisesRegex(ValueError, 'source changed during run'):
            self.gate()

    def test_head_change_during_real_command(self):
        xml = self.root / 'head-change.xml'
        code = "import subprocess, sys; subprocess.check_call(['git', 'commit', '--allow-empty', '-qm', 'moved']); sys.exit(subprocess.call([sys.executable, 'runner.py', sys.argv[1], 'pass']))"
        self.assertEqual(capture(self.repo, self.root / 'head-change', xml,
                                 [sys.executable, '-c', code, str(xml)]), 0)
        self.report['rules'][0]['run'] = 'head-change/run.json'
        with self.assertRaisesRegex(ValueError, 'source changed during run'):
            self.gate()

    def test_extra_evidence_hash_and_dtd(self):
        self.report['rules'][0]['evidence'] = [{'path': 'after/output.log', 'sha256': 'bad'}]
        with self.assertRaisesRegex(ValueError, 'evidence hash mismatch'):
            self.gate()
        self.rewrite_artifact('after', '<!DOCTYPE testsuite><testsuite/>')
        with self.assertRaisesRegex(ValueError, 'DTD/entities forbidden'):
            self.gate()

    def test_runner_environment_failure_without_junit(self):
        out = self.root / 'broken'
        self.assertNotEqual(capture(self.repo, out, self.root / 'absent.xml',
                                   [sys.executable, 'missing.py']), 0)
        self.report['rules'][0]['run'] = 'broken/run.json'
        with self.assertRaises((KeyError, FileNotFoundError)):
            self.gate()


if __name__ == '__main__':
    unittest.main()
