# DEA-481 combined T01–T17 evidence map

Approved source is revision 1 in `dea481-approved-space.md`; original
source/ownership mapping remains in `dea481-acceptance.md`. Code candidate:
`a65af8052fffff281bc78bac5718ec2e5a130b0c` (seventh client QA repairs).
Fourteen original counterexamples, one surviving-repost control and two retry
controls pass (17 total). The latest notification-projection failures and all
older failures remain preserved. See `docs/evidence/dea481-qa-round7/` for fixed
checks, coverage limits and package mapping. This maps portions of approved
cases, not complete acceptance.

Evidence roots: **S** = `docs/evidence/dea481/` (unchanged server, 459 tests);
**C** = `docs/evidence/dea481-client/` (Muse UI and screenshots, tested `d3856e3`);
**A** = `docs/evidence/dea481-agent/` (unchanged local/plugin regression);
**I** = `docs/evidence/dea481-integration/` (combined runs, tree equivalence,
real gateway, real TCP/native host, packages). **V** =
`docs/evidence/dea481-avatar-integration/` (new combined 688-pass / 12-skip run,
14 Linux integration passes, real authorized avatar upload/render regression,
refreshed UI packages). V supersedes I for changed UI; source equivalence in
V permits explicit reuse for unchanged boundaries. UI tests below are all in
`client/test/` and included in V's final run unless explicitly opt-in.

The full plugin lint entry failed in CI on the previous delivery. This is fixed
and locally verified with the same plugin working directory in
`docs/evidence/dea481-plugin-lint/` (Ruff 0.17.4, full `src tests` PASS;
114 pytest passes, zero skips). Only three test import blocks changed. Existing
runtime test results and packages are reused with explicit tree/byte checks;
new CI and the linked Windows package run are not claimed as completed.

The seventh QA repairs are integrated. **R** = `docs/evidence/dea481-qa-round7/`:
analyze PASS, 704 client passes / 12 skips, 14 Linux integration passes and
17 real checks PASS (the requested 15 plus two retained retry controls).
Notification invalidation now follows actual targetPostId/commentId and updates
snippet/accessibility/deletion together; surviving child/repost navigation passes.
Fresh UI packages use this runtime; old dbabb06 UI binaries are superseded.
R distinguishes real checks, unit cases, shared helpers and untested permutations.
Independent QA still owns whole T01–T17 evaluation.

| Case / approved source | Implementer / concrete evidence | Remaining verification or issue |
| --- | --- | --- |
| T01 §2, §9 | Forge S ten-image/order/publish; Muse `space_compose_test`, `space_feed_test`, `space_detail_test`; I native ten images and provider bytes, real gateway | Independent combined visual/user-path QA; real device/model limits remain |
| T02 §2.1, §7.3 | S CAS/lost-reply/publish guards; Muse local-intent reconciliation; R eight original real probes and two retry controls pass, including removal across confirmation failure/retry | Independent QA of remaining interleavings; no exhaustive state-machine claim |
| T03 §7.3 | S fixed equal-timestamp pagination counterexample; Muse `space_controller_test`, `space_feed_test` | QA multi-page scroll/refresh on target platforms |
| T04 §4.1 | S arbitrary depth and preview/pagination; Muse `space_detail_test`, C detail screenshots | Visual multi-level interaction QA |
| T05 §5.3 | S exact recipient/context; Muse `space_notifications_test`, `space_detail_test`; I gateway notifications | Independent notification navigation/focus |
| T06 §4.2 | S direct reference/counts; Muse controller/detail navigation tests; A shared contract path | Manual back-stack/reference UX |
| T07 §6.1–3 | S tombstones/protected media/shared blob; Muse controller/detail invalidation; I TCP delete invalidation and host deleted-image refusal; R stale refresh passes | R feed/detail rollback and stale refresh probes pass. Independent offline/cache/lifecycle and target-platform QA remains |
| T08 §6.2 | S delete-parent/retain-descendants ACL; Muse detail/controller placeholder/reply tests; R real loaded-preview/notification redaction and delayed reply-page probes | Independent rendered long-thread verification and remaining context/notification race combinations |
| T09 §5.1–2 | S sparse read/visit idempotency; Muse controller lifecycle tests; I installed host explicit read and visit dedup | Device foreground/background lifecycle |
| T10 §5.2 | S author-only visitor query/no visit notification; I real gateway 403 and TCP identity checks | UI people-page navigation QA |
| T11 §5.3 | S membership/ack race; Muse notifications tests; I real gateway like/ack; A local explicit acknowledgment | R real loaded/late notification null/false/true projection and surviving child/repost navigation pass; independent aggregate UX remains |
| T12 §7.3–4 | S SQL rollback/event/restart; A ledger failure/lost-reply/owner counterexample; I standalone restart/rebind/replay | HTTP replay tested; actual network WS unavailable |
| T13 §3.3 | Muse feed/detail/shell keyboard and navigation tests, C wide viewport evidence; I Linux release smoke | **Windows build/runtime/package NOT RUN**; Linux is not Windows |
| T14 §3.4 | Muse `space_shell_test`, `space_compose_test`, detail resize state; C narrow/wide/fold-sized screenshots | **Real folding/Android runtime NOT RUN**; APK build only |
| T15 §8 | Forge sole schema/local adapter; A 114 plugin/46 targeted tests; I stock DSH 24 tools, ordered images, actual bytes | **Real model interpretation NOT RUN** |
| T16 §8.3–4 | S auth/durable facts; A lost-reply/identity ledger; I real installed-host restart/settings persistence/disable/uninstall/no republish | **Real model/adversarial content and rendered native settings UI NOT RUN** |
| T17 §3, §7.4 | Muse controller/feed/shell/auth-generation/capability tests; R final suite and five avatar regressions; I real auth regression; A account/consumer isolation | Initials-only avatar gap fixed by `4038c1f`; V real upload/render fails on old release and passes on new. QA account/server-switch UI and old-server experience |

Forge owns service/state/contract corrections and sole integration. Muse owns
independent UI corrections. The shared SpaceAvatar path (feed/detail/comments/
people) now uses the existing authorized Profile entry; widget tests cover the
shared store and root-Navigator likes sheet, while real release evidence covers
feed upload/render. Visitors use the same sheet wrapper; that path has no separate
real-release click test. Muse's registered once-only wakeup consumes Forge's final reply, verifies the
new candidate and owns the automated_qa handoff to Sentinel after verification. No extra QA mention,
acceptance waiver, workflow transition, main merge or deployment is made here.
