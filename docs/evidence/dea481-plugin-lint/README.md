# DEA-481 plugin CI lint correction

Approved revision 1; Forge run `01a1e1b0-8692-7331-91e2-560918e01102` on the
sole `agent/forge/dea-481-integration` branch. Baseline delivery:
`4c5d4be8fccffc87736cb5866418b1301bffe883`; corrected test source:
`0114e2c1d298570df98fad1a47c308be55f08d54`. Later delivery commits add evidence
and artifact mapping only.

[CI job 133010142823](https://github.com/iiishop/BB/actions/runs/43778469169/job/133010142823)
ran PR merge `b9bf0fe` for the baseline head: 114 pytest passes followed by
three I001 errors in the full plugin lint entry. The previous narrower lint
evidence does not cover or supersede that failure.

From exactly `dsh-plugin/`, `uv run --locked ruff check src tests` reproduced
those three errors with Ruff **0.17.4**, exit **1** (`before.log`, `before.exit`).
The same command after import organization exits **0** (`after.log`).
`uv run --locked pytest -q --junitxml=../docs/evidence/dea481-plugin-lint/pytest.xml`
then passed **114 tests, 0 skipped, 0 failures/errors** in 3.07s. This is actual
local execution, not a claim that the new remote CI has completed.

- Root cause: `RUFF-PLUGIN-FIRSTPARTY` — the three test import blocks mix the
  local `bb_dsh_plugin` package with third-party imports instead of the grouping
  required by Ruff when invoked from the plugin project. Evidence: linked CI
  failure and identical local before log.
- Writes/invalidations: only imports in `test_profile_stdio.py`,
  `test_space_tools.py`, `test_stdio.py`; no business writes or invalidations.
- Common fix: existing Ruff import sorter on those three files; no rule,
  dependency, CI, skip or assertion change. `import-equivalence.json` verifies
  identical import sets and all non-import AST nodes, including test bodies.
- Contract gap: none. Owner: Forge. Full `src tests` lint and all existing plugin
  pytest tests cover the changed import/loading paths. No new test framework/job.

`results.json` contains commands, exit codes, JUnit counts, source tree IDs and
artifact SHA-256 verification. All runtime sources, locks and builders are
identical to the previous delivery. Existing Linux/Android UI packages retain
`b3f391a` build provenance; standalone Dart/DSH packages retain `542cfad`. Their
bytes were rechecked, not rebuilt. `artifact-map.json` gives original download
links and checksums. The new source archive contains the corrected tests.

Prior combined 688-pass / 12-skip client results, 14 Linux integration passes,
avatar before/after rendering, server and native-host results remain scoped to
their recorded runtime source and environment. This lint correction does not
convert any skip or untested boundary into a pass.

[Windows test-package run 43778469175](https://github.com/iiishop/BB/actions/runs/43778469175)
was reported running by Orion at handoff. It was not re-triggered, polled or
waited on in this run. No Windows package/result is claimed here.

QA retains NOT RUN boundaries for Windows build/runtime/package, Android runtime,
real foldable hardware, real-model semantics/adversarial content, rendered native
settings and actual visitor-sheet clicking. Locked network WebSocket delivery
remains unavailable; HTTP replay evidence is separate. The approved T01–T17 map
remains in `docs/design/dea481-integration-acceptance.md`.

After posting the fixed SHA and evidence/artifact mapping, Forge is explicitly
authorized by the triggering handoff to transition the parent to `automated_qa`.
Only that workflow triggers Sentinel; no extra QA mention. This is not whole
product PASS, user acceptance, a main merge, deployment, formal release or Done.
