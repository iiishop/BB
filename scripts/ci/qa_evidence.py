"""Small local QA evidence gate; only stdlib. See docs/QA-EVIDENCE.md."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


from qa_results import counts, require, result_format


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(cwd, *args):
    return subprocess.check_output(['git', *args], cwd=cwd, text=True).strip()


def capture(cwd, out, junit, command, report_format='junit'):
    """Record the actual process exit, not an author's claimed result."""
    cwd, out = cwd.resolve(), out.resolve()
    artifact, _ = result_format(report_format)
    junit = junit.resolve() if junit is not None else None
    require((report_format == 'junit') == (junit is not None), 'JUnit path required only for junit format')
    require(command, 'missing command')
    require(not out.exists(), 'output directory already exists')
    require(junit is None or not junit.exists(), 'JUnit already exists: refuse stale evidence')
    sha = git(cwd, 'rev-parse', 'HEAD')
    dirty = git(cwd, 'status', '--porcelain', '--untracked-files=normal')
    out.mkdir(parents=True)
    with (out / 'output.log').open('wb') as log:
        if report_format == 'flutter-json':
            with (out / artifact).open('wb') as events:
                result = subprocess.run(command, cwd=cwd, stdout=events, stderr=log)
        else:
            result = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT)
    artifacts = {'output.log': digest(out / 'output.log')}
    if junit is not None and junit.is_file():
        data = junit.read_bytes()
        (out / 'junit.xml').write_bytes(data)
    if (out / artifact).is_file():
        artifacts[artifact] = digest(out / artifact)
    after_sha = git(cwd, 'rev-parse', 'HEAD')
    tracked_after = git(cwd, 'status', '--porcelain', '--untracked-files=no')
    unchanged = after_sha == sha and not tracked_after
    receipt = dict(candidate_sha=sha, dirty=dirty, source_unchanged=unchanged,
                   after_sha=after_sha, tracked_after=tracked_after, cwd=str(cwd), command=command,
                   exit_code=result.returncode, artifacts=artifacts, format=report_format)
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
    artifact, parse = result_format(run.get('format', 'junit'))
    for name in ('output.log', artifact):
        require(digest(path.parent / name) == run['artifacts'][name], f'hash mismatch: {name}')
    cases = parse((path.parent / artifact).read_text(encoding='utf-8'), run['cwd'])
    return run, cases, counts(cases)


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
        matches = [c for c in cases if c.identity == identity]
        require(len(matches) == 1, 'target testcase missing or ambiguous')
        require(matches[0].status != 'skipped', 'required testcase skipped')
        require(rule['id'] not in regressions or 'before' in rule, 'required regression missing before')
        if 'before' in rule:
            before = rule['before']
            old, old_cases, old_counts = read_run(report_path.parent / before['run'])
            require(old['candidate_sha'] == before['sha'] and before['sha'] != candidate, 'before SHA mismatch')
            require(old['exit_code'] > 0 and old_counts['failures'] > 0, 'before did not fail')
            targets = [c for c in old_cases if c.identity == identity]
            require(len(targets) == 1, 'before target missing or ambiguous')
            failure = targets[0]
            require(failure.status == 'failed' and failure.failure_kind == 'assertion',
                    'before target is not an assertion failure')
            require(before['assertion'].strip() and before['assertion'] in failure.detail,
                    'before failed for a different assertion')
        for artifact in rule.get('evidence', []):
            require(digest(report_path.parent / artifact['path']) == artifact['sha256'], 'evidence hash mismatch')
        item = dict(id=rule['id'], candidate_sha=candidate, command=run['command'],
                    exit_code=run['exit_code'], testcase=rule['testcase'], **counts,
                    executed=counts['tests'] - counts['skipped'],
                    failure_kind=None, gaps=['unrelated skipped tests'] if counts['skipped'] else [],
                    evidence_paths=[str(report_path.parent / rule['run']),
                                    *[str((report_path.parent / rule['run']).parent / name) for name in run['artifacts']]])
        if 'before' in rule:
            item['before'] = dict(sha=old['candidate_sha'], failure_kind=failure.failure_kind,
                                  raw_type=failure.raw_type, run=before['run'])
        summary.append(item)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    run = sub.add_parser('run')
    run.add_argument('--cwd', type=Path, required=True)
    run.add_argument('--out', type=Path, required=True)
    source = run.add_mutually_exclusive_group(required=True)
    source.add_argument('--junit', type=Path)
    source.add_argument('--flutter-json', action='store_true', help='capture native JSON reporter stdout')
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
            return capture(args.cwd, args.out, args.junit, command,
                           report_format='flutter-json' if args.flutter_json else 'junit')
        print(json.dumps(check(args.report, args.candidate, args.required, args.regressions), indent=2))
        return 0
    except (ValueError, KeyError, TypeError, OSError, ET.ParseError, subprocess.SubprocessError) as exc:
        print(f'QA evidence rejected: {exc}', file=sys.stderr)
        if args.action == 'check':
            print(json.dumps(dict(status='rejected', candidate_sha=args.candidate,
                                  gaps=[str(exc)], evidence_paths=[str(args.report)])))
        return 2


if __name__ == '__main__':
    sys.exit(main())
