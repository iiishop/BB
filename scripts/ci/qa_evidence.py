"""Small local QA evidence gate; only stdlib. See docs/QA-EVIDENCE.md."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(cwd, *args):
    return subprocess.check_output(['git', *args], cwd=cwd, text=True).strip()


def capture(cwd, out, junit, command):
    """Record the actual process exit, not an author's claimed result."""
    cwd, out, junit = cwd.resolve(), out.resolve(), junit.resolve()
    require(command, 'missing command')
    require(not out.exists(), 'output directory already exists')
    require(not junit.exists(), 'JUnit already exists: refuse stale evidence')
    sha = git(cwd, 'rev-parse', 'HEAD')
    dirty = git(cwd, 'status', '--porcelain', '--untracked-files=normal')
    out.mkdir(parents=True)
    with (out / 'output.log').open('wb') as log:
        result = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT)
    artifacts = {'output.log': digest(out / 'output.log')}
    if junit.is_file():
        data = junit.read_bytes()
        (out / 'junit.xml').write_bytes(data)
        artifacts['junit.xml'] = digest(out / 'junit.xml')
    after_sha = git(cwd, 'rev-parse', 'HEAD')
    tracked_after = git(cwd, 'status', '--porcelain', '--untracked-files=no')
    unchanged = after_sha == sha and not tracked_after
    receipt = dict(candidate_sha=sha, dirty=dirty, source_unchanged=unchanged,
                   after_sha=after_sha, tracked_after=tracked_after, cwd=str(cwd), command=command,
                   exit_code=result.returncode, artifacts=artifacts)
    (out / 'run.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return result.returncode


def read_run(path):
    run = json.loads(path.read_text())
    require(re.fullmatch(r'[0-9a-f]{40}', run['candidate_sha']), 'invalid run SHA')
    require(not run['dirty'], 'run started with dirty source')
    require(run['source_unchanged'] is True and run['after_sha'] == run['candidate_sha']
            and not run['tracked_after'], 'source changed during run')
    require(isinstance(run['command'], list) and run['command'] and
            all(isinstance(arg, str) for arg in run['command']), 'missing actual entry command')
    require(type(run['exit_code']) is int, 'invalid exit code')
    for name in ('output.log', 'junit.xml'):
        require(digest(path.parent / name) == run['artifacts'][name], f'hash mismatch: {name}')
    xml = (path.parent / 'junit.xml').read_text(encoding='utf-8')
    # No DTD/entity declarations in runner JUnit; keep the parser stdlib-only.
    require('<!DOCTYPE' not in xml.upper() and '<!ENTITY' not in xml.upper(), 'DTD/entities forbidden')
    root = ET.fromstring(xml)
    require(not list(root.iter('error')), 'environment/runner error is not an assertion counterexample')
    require(root.tag in ('testsuites', 'testsuite'), 'unsupported JUnit root')
    cases = list(root.iter('testcase'))
    require(cases, 'no collected testcases')
    # Count testcase nodes, never trust JSON totals or only testsuite attributes.
    counts = dict(tests=len(cases), failures=sum(c.find('failure') is not None for c in cases),
                  errors=sum(c.find('error') is not None for c in cases),
                  skipped=sum(c.find('skipped') is not None for c in cases))
    for suite in root.iter('testsuite'):
        direct = suite.findall('testcase')
        if not suite.findall('testsuite'):
            for key, tag in (('tests', None), ('failures', 'failure'), ('errors', 'error'), ('skipped', 'skipped')):
                actual = len(direct) if tag is None else sum(c.find(tag) is not None for c in direct)
                require(int(suite.get(key, str(actual))) == actual, f'JUnit {key} disagrees with cases')
    require(not counts['errors'], 'environment/runner error is not an assertion counterexample')
    require(counts['tests'] > counts['skipped'], 'no executed testcases')
    return run, cases, counts


def check(report_path, candidate, required, regressions=()):
    report = json.loads(report_path.read_text())
    require(re.fullmatch(r'[0-9a-f]{40}', candidate), 'candidate must be full SHA')
    require(report['candidate_sha'] == candidate, 'candidate SHA mismatch')
    rules = report['rules']
    ids = [r['id'] for r in rules]
    require(len(ids) == len(set(ids)), 'duplicate rule')
    require(required and (set(required) | set(regressions)) <= set(ids), 'required rule missing')
    summary = []
    for rule in rules:
        require(rule['rule'].strip() and rule['entry'].strip(), 'rule and actual product entry required')
        require(rule['status'] == 'tested', f"untested rule: {rule['id']}")
        run, cases, counts = read_run(report_path.parent / rule['run'])
        require(run['candidate_sha'] == candidate, 'run candidate mismatch')
        require(run['exit_code'] == 0 and counts['failures'] == 0, 'candidate tests failed')
        identity = (rule['testcase']['classname'], rule['testcase']['name'])
        matches = [c for c in cases if (c.get('classname', ''), c.get('name')) == identity]
        require(len(matches) == 1, 'target testcase missing or ambiguous')
        require(matches[0].find('skipped') is None, 'required testcase skipped')
        require(rule['id'] not in regressions or 'before' in rule, 'required regression missing before')
        if 'before' in rule:
            before = rule['before']
            old, old_cases, old_counts = read_run(report_path.parent / before['run'])
            require(old['candidate_sha'] == before['sha'] and before['sha'] != candidate, 'before SHA mismatch')
            require(old['exit_code'] > 0 and old_counts['failures'] > 0, 'before did not fail')
            targets = [c for c in old_cases if (c.get('classname', ''), c.get('name')) == identity]
            require(len(targets) == 1, 'before target missing or ambiguous')
            failure = targets[0].find('failure')
            require(failure is not None and failure.get('type') in ('AssertionError', 'AssertionError [ERR_ASSERTION]'),
                    'before target is not an assertion failure')
            assert failure is not None  # established above
            require(before['assertion'].strip() and before['assertion'] in ''.join(failure.itertext()) + failure.get('message', ''),
                    'before failed for a different assertion')
        for artifact in rule.get('evidence', []):
            require(digest(report_path.parent / artifact['path']) == artifact['sha256'], 'evidence hash mismatch')
        summary.append(dict(id=rule['id'], command=run['command'], **counts))
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    run = sub.add_parser('run')
    run.add_argument('--cwd', type=Path, required=True)
    run.add_argument('--out', type=Path, required=True)
    run.add_argument('--junit', type=Path, required=True)
    run.add_argument('command', nargs=argparse.REMAINDER)
    gate = sub.add_parser('check')
    gate.add_argument('report', type=Path)
    gate.add_argument('--candidate', required=True)
    gate.add_argument('--require', action='append', required=True, dest='required')
    gate.add_argument('--require-regression', action='append', default=[], dest='regressions')
    args = parser.parse_args()
    try:
        if args.action == 'run':
            command = args.command[1:] if args.command[:1] == ['--'] else args.command
            return capture(args.cwd, args.out, args.junit, command)
        print(json.dumps(check(args.report, args.candidate, args.required, args.regressions), indent=2))
        return 0
    except (ValueError, KeyError, TypeError, OSError, ET.ParseError, subprocess.SubprocessError) as exc:
        print(f'QA evidence rejected: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
