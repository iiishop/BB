DEA-466 R3 integration QA handoff

Scope: client `ccfe103d7281d213ef38e2cad60a39a2cdea14e8`, including the previous history/media fixes, combined with Forge runtime/contracts `393e38e628c210a0dda37b941afce073ceab9949`. The final integration SHA and verified bundle are supplied in Orion's issue comment. No main merge or release is authorized.

The only Orion code changes after integration are in the QA harness: explicit reviewed client SHA instead of the obsolete hardcoded client, clean client tree enforcement, and a shared owned-process signal guard that tolerates an already departed daemon. No business assertions are removed. Product client/server/plugin behavior is unchanged by these harness edits.

Set QA_COMMIT to the full SHA from the handoff, not an unchecked local HEAD. Run from the repository root. DSH_SOURCE must be the unmodified pinned DSH 0.2.1-rc.5 package; installation verifies the full tree and creates a project-private copy. No personal deployment configuration or credentials are needed for the deterministic tests.

```sh
git diff --exit-code
git rev-parse HEAD
uv run --project server --locked pytest server/tests -q --tb=short
uv run --project dsh-plugin --locked pytest dsh-plugin/tests -q --tb=short
QA_REQUIRE_INTEGRATION=1 QA_REQUIRE_WIDGET_TESTS=1 bash scripts/run_flutter_tests.sh client
uv run --no-project python dsh-plugin/runtime-patch/test-live-runner-guards.py
uv run --no-project python dsh-plugin/runtime-patch/install.py --source "$DSH_SOURCE" --destination dsh-plugin/.runtime/dsh-r3-qa
uv run --no-project python dsh-plugin/runtime-patch/install.py --verify --destination dsh-plugin/.runtime/dsh-r3-qa
uv run --project server --locked python dsh-plugin/runtime-patch/test-live-r3.py --client client --expected-client-sha "$QA_COMMIT" --runtime dsh-plugin/.runtime/dsh-r3-qa --dart "$DART_EXECUTABLE" --crypto "$CRYPTO_PACKAGE"
```

CRYPTO_PACKAGE is the installed crypto 3.0.8 package directory. DART_EXECUTABLE is the actual Dart SDK binary. Use a fresh installation destination; do not overwrite another runtime. The native fault matrix commands remain in `docs/contracts/chat-step3.md`. All processes must be collected before returning; only the runner-owned process groups may be terminated.

Acceptance, with independent evidence:

1. Changed attempt identity/digest/members rejects atomically, preserving ACK gaps; identical concurrent/restarted retries are idempotent, account switching cannot write to another account.
2. events/wait accepts and enforces limit, backlog returns immediately, new consumer recovers its own pre-registration messages despite another consumer's source progress. Repeat registration, concurrent arrival, restart and partial backfill do not lose or duplicate events.
3. Keep all 16 live checks including original operation commit + SIGKILL + continuation + two replays with only one platform output. Capture runner/client SHA, wire results and exit code; no manual test edits.
4. Independently exercise busy/wait/turn-end arrival and download success/failure, including after the originating turn ended, with the actual client and native runtime. Verify session ownership and no duplicate turn. Separate deterministic provider evidence from actual model/vision evidence.
5. Strict Flutter regression includes all-user list/privacy/duplicate names/grapheme truncation/presence, 1000-message backfill concurrent send, ordered images, click-only streaming, file input/clipboard/save and Profile/login regressions. Actual desktop video playback/decoding still needs verification; HTTP 206 alone is insufficient.

Android build/real-device operation, Windows, physical folding and real model/vision were not established by the developer evidence. Record PASS/FAIL/NOT RUN/BLOCKED precisely; no emulator/device claims from Linux screenshots. Windows is not a blocking requirement. Keep logs free of credentials, including the live runner's private directory. Owner actions after QA: three-account privacy checks, mixed text/images/attachments, playback/save, async download wakeup after a turn, reconnect and Profile. This handoff requests independent QA, not Owner Review approval or Done.
