# DEA-485 server developer evidence

This is Forge's development verification, not Sentinel's independent QA or the
final integrated client/device acceptance. Approved product specification is
DEA-485 revision 1 (cases 1–13); issue record revision at admission was 3.

- Baseline: `246c690bd4cca4832b3d53c5757eb804e92f3531`.
- Branch: `agent/forge/1d940ac9891d`.
- Contract commit: `0427a46`.
- Tested implementation: `36e968409704fba28a211e60306a61ea31a5e014`.
- Subsequent evidence-only commit does not change the tested implementation.
- Authority and caller notes: `docs/contracts/dea485-profile-follow.md` and
  `server/contract/src/bb_auth_contract/space.py`.

## Actual verification

Locked install: `uv sync --project server --locked`, exit 0. Environment details
and lock hashes are in `environment.json`; no dependency version or lock changed.
All service processes and databases belong to isolated temporary test fixtures;
only synthetic accounts were registered. All launched Python service children
were stopped before test completion. No production database, model or credential
was used.

From `server/` the clean candidate executed:

```bash
uv run --project . --locked pytest -q --junitxml=<fresh-external-file> tests
uv run --project . --locked ruff check src tests contract/src/bb_auth_contract/admin.py contract/src/bb_auth_contract/space.py
```

Tests: **483 passed, 0 failed, 0 errors, 0 skipped**, exit 0, 109.35 seconds.
Lint: exit 0. Changed implementation/test/contract files also passed formatter
checks. The tests used the existing QA runner in `scripts/ci/qa_evidence.py`;
exact argv, initial clean state, unchanged final SHA, log and JUnit hashes are
in `run/run.json`. Raw output is `run/output.log`, raw cases `run/junit.xml`.
The existing TestClient dependency emits one deprecation warning; it was not
hidden, and dependencies were not upgraded to suppress it.

`report.json` maps ten service rules to real test cases; `check.json` is the
existing checker's successful result. Counts were independently read from the
JUnit testcase nodes. Re-run the checker from the repository root:

```bash
uv run --no-project python scripts/ci/qa_evidence.py check \
  docs/evidence/dea485-server/report.json \
  --candidate 36e968409704fba28a211e60306a61ea31a5e014 \
  --require profile-order-directory --require month-offset \
  --require timeline-pagination --require scope-fences \
  --require following-selection --require follow-idempotence \
  --require follow-rollback --require migration-upgrade \
  --require live-restart --require auth-errors
```

During development, running lint from the repository root caused first-party
import classification errors; the actual repository/CI command runs in
`server/` and passes. An additional optional scan of *all* contract modules finds
the pre-existing UP046 in `chat_v2.py:367`; that file's bytes were checked equal
to the fixed baseline. The CI lint scope and changed Space authority pass.

## Entry coverage and migration

| Entry | Actual evidence |
| --- | --- |
| `list_profile_posts` | Real HTTP handler, mixed original/repost times; deleted source blanking; month anchor continues into earlier months; same-time stable ID pagination; publication high-water mark; viewer/target/month/offset/action cursor rejection |
| `list_profile_months` | Same published/nondeleted author scope; sparse month directory; drafts/likes/comments excluded; explicit offsets −840, −330, 0, +345, +840 across month/year boundaries |
| `list_posts` all/following | Existing shared keyset/projection; publisher filtering includes pre-follow history and reposts, preserves empty feed; existing author/unread filters; mode and follow-revision cursor fences |
| `get_follow` / `set_follow` | Real handlers; authoritative post projection; self/missing/invalid rejection; concurrent duplicate follow and unfollow; private invalidation; failure before revision/event; complete rollback, reconciliation and retry |
| Restart and auth | Real `python -m bb_server` TCP process, persisted follow/unfollow and profile facts through two cold restarts, no duplicate event on retry, revoked session rejection |
| V4→V5 | Existing migration entry, injected SQL failure rolls back both new tables/version and retains users/posts/chat; retry and repeated startup preserve facts; FK/self constraints |
| Existing business paths | Full server suite includes chat/Profile/Space, media protection, existing migration/recovery and storage lock tests; new routes share the existing transaction/auth boundary |

Schema 5 adds only relationship and viewer-revision tables. Write order is
relationship → revision → recipient invalidation → commit → response. No-op
desired states create no extra relationship or event. The same existing response
validation/transaction boundary handles follow, so failed validation or commit
uses the already tested common rollback implementation. No side effects outside
SQLite are added. Rollback is backup restore with owner approval, not downgrade.

No new CI job or common script change is necessary: existing server pytest
discovery and lint cover these files. Structural reuse and behavior are reviewed
separately; generated schemas are not a line-count reduction objective.

## Remaining owners and limits

Orion owns integration onto the sole integration candidate; Muse owns all
client state, the explicit-offset rendering, asynchronous result fences,
session/navigation/scroll handling and responsive module UI. The integration
must reuse the shared authority rather than copy a protocol. New follow actions
do not expand MCP tools. Sentinel owns independent end-to-end QA after integration.

Android device probe: `adb devices` returned no connected device. Runtime is
Linux; Android/Windows real-device UI and foldable interactions are **NOT RUN**
here. Flutter SDK availability does not certify those paths. UI screenshots and
client tests are outside this server delivery. No model is needed for this scope.
No main merge, deployment, release, production migration or issue Done occurred.
