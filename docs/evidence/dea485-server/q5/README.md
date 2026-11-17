# DEA-485 Q5: fixed MCP exposure boundary

Scope: Orion's Q5 rework instruction under approved specification revision 1.
This is Forge's developer evidence, not Sentinel's independent integrated QA.

- Fixed baseline: `b6becc4f143b2489ddc04f12a8ec0af1e20f8a86`.
- Isolated checkout: this run's `BB/`; branch `agent/forge/9ed7da68b232`.
- Tested fix: `a8d3070ec210787ff6e17942781420d85507f974`.
- Later commit adds only files in this Q5 evidence directory.
- Only `dsh-plugin/` and this directory changed relative to the fixed baseline.
- Sentinel's attached ZIP was downloaded via the authenticated CLI and verified
  against published SHA-256 `c8b32f7b3a59ccad2e11b93ca4625862088fdb82f5de355ca696f341106bcf8c`.

## Cause and correction

`space_tools.py` derived both its model registry and tool schemas by enumerating
every shared HTTP request except `read_events`. Extending the HTTP contract
therefore accidentally exposed four unapproved MCP tools. The unchanged discovery
count assertion reproduced the defect on the clean fixed baseline.

`EXPOSED_SPACE_ACTIONS` now names the original 24 approved actions explicitly.
`SPACE_TOOLS` fetches each model from the shared `space.REQUESTS` authority;
`TOOL_SCHEMAS` derives from `SPACE_TOOLS`, preserving the existing image-path
adapter. No field protocol is duplicated. Model identity and exact legacy names
are asserted in addition to the original **24** count assertion.

The MCP discovery/dispatch and protected HTTP transport use that same registry.
Direct `invoke_space` and `GuardedTransport.call` attempts for unexposed Space
actions return the existing 404 `unknown_tool` error before parsing/file I/O or
HTTP dispatch. No new business writes, receipt or identity mechanism is added.
No contract gap was found; shared contract and client code were not modified.

## Actual checks and counts

`uv sync --project dsh-plugin --locked` exited 0. Lockfiles, dependency manifests
and external DSH installation were unchanged. Versions/hashes are recorded in
`environment.json`. Commands below run from `dsh-plugin/`:

| Phase | Command | Actual result |
| --- | --- | --- |
| Before, clean fixed baseline | `uv run --project . --locked pytest tests/test_space_tools.py -q --junitxml=<fresh-before-file>` | 9 collected: 8 passed, 1 failed, 0 errors, 0 skipped; exit 1. Original discovery assertion: `assert 28 == 24`. |
| Targeted development check | `uv run --project . --locked pytest tests/test_space_tools.py tests/test_stdio.py -q` | 16 passed, exit 0. |
| After, clean fix SHA | `uv run --project . --locked pytest tests -q --junitxml=<fresh-after-file>` | 122 passed, 0 failures/errors/skips; exit 0, 6.29 seconds. |
| Lint | `uv run --project . --locked ruff check src tests` | Exit 0. |

`before/` and `after/` preserve raw JUnit/logs and existing QA runner receipts.
Both receipts record clean Git state, fixed SHA, unchanged ending source, exact
argv, actual exit code and artifact hashes. The full plugin suite includes the
existing native JS bundle regression entry; it does not introduce a CI job.
Counts were read from testcase nodes, not inferred from a developer summary.

`report.json` maps eight rules to those results; the discovery rule includes the
before assertion. `check.json` is the successful existing checker output. Replay:

```bash
uv run --no-project python scripts/ci/qa_evidence.py check \
  docs/evidence/dea485-server/q5/report.json \
  --candidate a8d3070ec210787ff6e17942781420d85507f974 \
  --require q5-discovery --require-regression q5-discovery \
  --require q5-future-request --require q5-stdio \
  --require q5-deny-get_follow --require q5-deny-set_follow \
  --require q5-deny-list_profile_posts --require q5-deny-list_profile_months \
  --require q5-deny-read_events
```

## Entry coverage and remaining boundaries

- Discovery: actual `tools/list` handler retains all original 24 names and
  shared request schemas; internal replay and the four new HTTP actions excluded.
- Invocation: parameterized regressions cover `get_follow`, `set_follow`,
  `list_profile_posts`, `list_profile_months`, `read_events` across `invoke_space`,
  the real MCP `tools/call` handler, and direct `GuardedTransport.call`. Test
  dispatch/HTTP sentinels assert that no request escapes these rejection paths.
- Future extensions: a fresh Python process inserts a synthetic HTTP request in
  memory before importing the actual plugin registry. Discovery still has 24
  tools and a direct invocation is refused. No installed dependency is patched.
- Real stdio entry: the existing MCP subprocess test now checks the 24 Space
  tools and invokes all five excluded actions, then verifies registration/login
  and existing binding denial. Its loopback HTTP listener is a test double;
  tests use synthetic identity/capability values only.
- Existing media behavior: the full suite retains native image bytes, image-path
  materialization, structural validation, scoped identity, and error tests.
  Bundle wrappers consume MCP discovery; their existing JS tests also pass.

No personal profile, real account, model credential or production service was
accessed. Actual DSH installation/settings lifecycle, real model understanding,
real Dart/backend integration, Android/Windows/physical-foldable interaction and
client Q1–Q4/Q6 are **NOT RUN** in this Q5 scope. Their earlier NOT RUN conditions
remain; stdio/process tests do not replace them. Server evidence from the earlier
delivery was not rerun or relabeled as a Q5 result.

Orion remains the sole integrator and must combine Q5 with Muse's client repairs
before the next `automated_qa` handoff. This branch does not modify the integration
branch, request separate QA, merge main, deploy, publish or set the issue Done.
