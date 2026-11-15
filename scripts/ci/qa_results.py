"""Runner formats -> one immutable result model. Never rewrite runner artifacts."""
from dataclasses import dataclass
import json
import os
import re
import xml.etree.ElementTree as ET


def require(condition, message):
    if not condition:
        raise ValueError(message)


@dataclass(frozen=True)
class Case:
    classname: str
    name: str
    status: str = 'passed'
    failure_kind: str = ''
    detail: str = ''
    raw_type: str = ''

    @property
    def identity(self):
        return self.classname, self.name


def counts(cases):
    require(cases, 'no collected testcases')
    result = dict(tests=len(cases), failures=sum(c.status == 'failed' for c in cases),
                  errors=sum(c.status == 'error' for c in cases),
                  skipped=sum(c.status == 'skipped' for c in cases))
    require(not result['errors'], 'environment/runner error is not an assertion counterexample')
    for case in cases:
        require(case.status != 'failed' or case.failure_kind == 'assertion',
                f'failure is not an assertion failure: {case.identity} ({case.failure_kind}, raw={case.raw_type!r})')
    require(result['tests'] > result['skipped'], 'no executed testcases')
    return result


def failure_kind(kind, text):
    if kind in ('AssertionError', 'AssertionError [ERR_ASSERTION]'):
        return 'assertion'
    if kind == 'testCodeFailure':
        # Node wraps ALL test exceptions. Only its immediate cause is evidence;
        # an assertion string in a TypeError message is not an assertion.
        cause = re.search(r'^  cause: ([^\n]+)', text, re.M)
        if cause and cause[1].startswith('AssertionError [ERR_ASSERTION]:'):
            return 'assertion'
        return 'runtime' if cause else 'unknown'
    return 'unknown'


def parse_junit(xml):
    require('<!DOCTYPE' not in xml.upper() and '<!ENTITY' not in xml.upper(), 'DTD/entities forbidden')
    # DTD/entity declarations are rejected above before stdlib XML parsing.
    root = ET.fromstring(xml)
    require(root.tag in ('testsuites', 'testsuite'), 'unsupported JUnit root')
    require(all(node.tag in {'testsuites', 'testsuite', 'testcase', 'failure', 'error',
                            'skipped', 'properties', 'property', 'system-out', 'system-err'}
                for node in root.iter()), 'unknown JUnit element')
    require(not list(root.iter('error')), 'environment/runner error is not an assertion counterexample')
    nodes = list(root.iter('testcase'))
    require(nodes, 'no collected testcases')
    for suite in root.iter('testsuite'):
        direct = suite.findall('testcase')
        if not suite.findall('testsuite'):
            for key, tag in (('tests', None), ('failures', 'failure'), ('errors', 'error'), ('skipped', 'skipped')):
                actual = len(direct) if tag is None else sum(c.find(tag) is not None for c in direct)
                require(int(suite.get(key, str(actual))) == actual, f'JUnit {key} disagrees with cases')
    cases = []
    for node in nodes:
        outcomes = [c for c in node if c.tag in ('failure', 'skipped', 'error')]
        require(len(outcomes) <= 1, 'ambiguous testcase outcome')
        failure = node.find('failure')
        status, kind, detail, raw = 'passed', '', '', ''
        if failure is not None:
            raw = failure.get('type', '')
            text = ''.join(failure.itertext())
            detail = text + '\n' + failure.get('message', '')
            status, kind = 'failed', failure_kind(raw, text)
            if not raw and root.get('name') == 'pytest tests':
                # pytest omits type. Inspect its terminal traceback exception,
                # not arbitrary source lines or the assertion-like message.
                terminal = re.search(r'(?:^|\n)\S[^\n]*:\d+: (\w+(?:\.\w+)*)\s*\Z', text)
                if terminal:
                    kind = 'assertion' if terminal[1] == 'AssertionError' else 'runtime'
        elif node.find('skipped') is not None:
            status = 'skipped'
        require(bool(node.get('name')), 'missing testcase name')
        cases.append(Case(node.get('classname', ''), node.get('name', ''), status, kind, detail, raw))
    return cases


def parse_flutter(text, cwd):
    events = [json.loads(line) for line in text.splitlines() if line.strip()]
    require(events and all(isinstance(e, dict) for e in events), 'invalid Flutter events')
    require(events[0].get('type') == 'start' and events[0].get('protocolVersion') == '0.1.1',
            'unsupported Flutter protocol')
    require(events[-1].get('type') == 'done' and type(events[-1].get('success')) is bool,
            'truncated Flutter stream: missing done')
    suites, tests, finished, errors = {}, {}, {}, {}
    suite_counts = []
    for index, event in enumerate(events):
        kind = event.get('type')
        require(kind in {'start', 'suite', 'allSuites', 'group', 'testStart', 'testDone', 'error', 'print', 'done'},
                'unknown Flutter event')
        if kind in ('start', 'done'):
            require(index == (0 if kind == 'start' else len(events) - 1), 'duplicate Flutter boundary')
        elif kind == 'suite':
            suite = event['suite']
            require(suite['id'] not in suites and isinstance(suite['path'], str), 'invalid Flutter suite')
            suites[suite['id']] = os.path.relpath(suite['path'], cwd)
        elif kind == 'allSuites':
            suite_counts.append(event['count'])
        elif kind == 'testStart':
            test = event['test']
            require(test['id'] not in tests and test['suiteID'] in suites and isinstance(test['name'], str),
                    'invalid Flutter testStart')
            tests[test['id']] = test
        elif kind in ('error', 'testDone'):
            ident = event['testID']
            require(ident in tests and ident not in finished, 'orphan/duplicate Flutter outcome')
            if kind == 'error':
                require(type(event.get('isFailure')) is bool and isinstance(event.get('error'), str),
                        'unknown Flutter failure')
                errors.setdefault(ident, []).append(event)
            else:
                require(event.get('result') in ('success', 'failure', 'error') and
                        type(event.get('skipped')) is bool and type(event.get('hidden')) is bool,
                        'unknown Flutter result')
                finished[ident] = event
    require(suite_counts == [len(suites)] and tests.keys() == finished.keys(), 'incomplete Flutter run')
    cases = []
    for ident, test in tests.items():
        outcome, failures = finished[ident], errors.get(ident, [])
        expected = 'error' if any(not e['isFailure'] for e in failures) else ('failure' if failures else 'success')
        require(outcome['result'] == expected, 'Flutter result disagrees with errors')
        require(not outcome['skipped'] or not failures, 'Flutter skipped failure')
        if outcome['hidden']:
            require(not failures and not outcome['skipped'], 'hidden Flutter failure')
            continue  # runner loading/housekeeping successes are not product tests
        status = 'skipped' if outcome['skipped'] else {'success': 'passed', 'failure': 'failed', 'error': 'error'}[expected]
        cases.append(Case(suites[test['suiteID']], test['name'], status,
                          {'success': '', 'failure': 'assertion', 'error': 'runtime'}[expected],
                          '\n'.join(e['error'] for e in failures), expected))
    require(events[-1]['success'] == all(e['result'] == 'success' for e in finished.values()),
            'Flutter done disagrees with results')
    return cases


FORMATS = {'junit': ('junit.xml', lambda text, cwd: parse_junit(text)),
           'flutter-json': ('flutter.jsonl', parse_flutter)}


def result_format(name):
    require(name in FORMATS, 'unsupported evidence format')
    return FORMATS[name]
