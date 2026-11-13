## Shared ledger commit audit

Implementation owner: Forge. Baseline: `0f72c3584bd38289530fd0d65d7063dc4b14a674`.
This inventory was written before changing the ledger implementation. It covers
the shared JSON document, not authentication's separate SessionStore.

All public entries serialize via `_locked`. Readers can fill absent schema
defaults through `_account`, but do not publish new business facts. The write
entries below mutate `_data` before awaiting file flush; callers receive results
after the await. With no common rollback, later reads/idempotent retries could
observe a failed mutation. Existing selective snapshots do not cover the document.

| Write entry | State / commit boundary | Baseline rollback | Planned verification |
| --- | --- | --- | --- |
| setServerEventCursor | account source cursor, one flush | none | repeated real I/O failure, retry, cold read |
| setConsumerEventCursor | consumer feed cursor, one conditional flush | none | same; another consumer unchanged |
| subscribe | subscription and feed, one flush; same-binding early return | none | same; no false idempotent success |
| saveOperation | durable operation plan/result, one flush | none | same; old operation retained |
| saveDownload | download task, one flush | none | same; task retained |
| saveDownloadOperation | operation→task mapping, one flush | none | same; mapping not published on failure |
| enrollConsumer | owner pending flush, then consumer/alias/owner ready flush | none | original reproduction; both phase failures; pending cold recovery |
| bindConsumerOwner | consumer/alias revision CAS, one flush | whole snapshot locally | existing ACK/bind failure tests + shared matrix |
| bindConsumer | creation or alias/generation update, one flush | whole snapshot locally | creation and update fail/retry/cold read |
| setConsumedThrough | consumer/peer watermark, one conditional flush | none | repeated failure; no false high watermark |
| commitAck | identity/gap validation then watermark, one flush | whole snapshot locally | existing real I/O and identity boundary regressions |
| prepareReceipt | optional consumer + receipt, one flush | none | failure/retry, no published createdReceiptIds before commit |
| discardUnconfirmedReceipts | delete eligible receipts, one conditional flush | none | failure/retry/cold read |
| confirmPresentationAttempt | validation then receipt+attempt, one flush | partial receipt/confirmation snapshot | shared matrix and validation failure rollback |
| confirmReceipts | receipt flags, one conditional flush | none | failure/retry/cold read |
| recordConfirmation | attempt record, one flush | none | failure/retry/cold read |
| finishDownload | terminal task + pending delivery, one flush | partial download/pending snapshot | shared matrix and existing download regressions |
| deliverPendingEvents | pending→feed entries/dedup/cursors, one flush | partial pending/events snapshot | failure/retry/cold read; exactly one event |
| appendLocalEvent | entry + dedup id + cursor, one flush | none | failure/retry/cold read; dedup not stranded |

Shared repair: route all 19 writers through `_mutate` under the existing lock.
Take a whole-document checkpoint before mutation and advance it only after each
successful `_flush`. On errors restore the latest checkpoint before releasing
the lock. This preserves enrollment's durable pending reservation if ready
fails, and preserves all prior successful commits. Reads do not acquire an
additional document snapshot. Remove selective rollback branches once they use
the same mechanism. Publish the external `createdReceiptIds` marker only after
receipt persistence. `_ensureConsumerLocked`, `_account`, and direct map edits
are covered by their enclosing writer; they are not separate disk writers.

Loading is a separate entry: publish the loaded flag/document only after a
successful read/validation; an I/O failure must be retryable rather than leave
the instance marked loaded. File replacement remains within the shared flush;
tests use real temporary files and a replacement barrier to reach pending/ready
boundaries. No new business database, HTTP contract, dependency or host changes.

### Implemented coverage

All 19 entries now use `_mutate` and the same successful-flush checkpoint. The
writer returns (or throws) only after restoring that committed view; partial
snapshot branches in ACK/bind/confirmation/download/events were removed.
`prepareReceipt` adds to the caller's created-id set after persistence. Load
errors leave the instance retryable. Failed temporary files are cleaned up;
on POSIX a rename failure never deletes the previous document.

`client/test/chat_ledger_commit_test.dart` directly exercises every table row
with two real filesystem failures, checking the in-memory public view, retained
disk bytes and no leaked temporary file; restoration, successful retry and a
fresh ledger read must agree. There are 20 matrix cases (bind creation/update
separately), plus four stage/validation/load cases: **24 passed**. None of the
19 entries relies only on an untested assertion that another entry shares code.
The entry-specific argument/identity rules also retain existing tests. Helpers
`_account` and `_ensureConsumerLocked` are covered through the enclosing entries,
including failed confirmation validation that must not mint a consumer.

The original attachment, unchanged and selected with
`--plain-name 'failed enrollment retry must persist before reporting ready'`,
failed on `0f72c35` (exit 1, ready id with null cold binding), and passes after the
repair. The matrix plus existing ledger, ACK/bind, atomic confirmation, consumer
isolation, identity, local v2, query rebind, download terminal event and consumer
backfill tests passed **77 cases / exit 0**. Exact candidate SHA, commands and CI
are delivered in the issue evidence rather than embedding a self-referential SHA.

Pending/ready test barriers operate after the temporary document is flushed,
before rename. The ready-stage failure retains a real on-disk pending owner;
another account cannot adopt it, and a fresh ledger can finish it. A queued
reader cannot see the failed ready binding. File reload is not claimed as an
OS process kill or power-loss test. No new standalone process/power-loss or
multi-process writer guarantee is introduced here. Windows fallback/device,
directory fsync/power-loss and permission/ENOSPC-specific fault variants were
not run; the real-fault matrix uses an occupied ledger path on Linux. Windows's
pre-existing replacement fallback is not rewritten in this behavior repair.

The attachment's logout/restore assertions are preserved untouched and excluded
using the Owner-specified enrollment plain-name selector. Owner review reproduced
them on `2f5a0bb`; this change neither fixes them nor claims the whole auth
lifecycle race-free. Non-blocking structural follow-ups remain separate: shared
send execution, application-service ownership of receipt cleanup, and auth/store
ownership simplification. None is a prerequisite or implemented by this repair.
