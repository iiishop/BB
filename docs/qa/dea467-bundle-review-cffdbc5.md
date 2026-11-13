DEA-467 bundle review — Orion, 2026-11-12

Reviewed PR #12 product commit `cffdbc52760b3ca37361bdef7a47888638d42c06`; client tree `dea50f14f0d3c8470ed87573370887f6580d424a`. This is an implementation milestone, not final acceptance.

Evidence review: all 23 bundle-manifest file hashes match both the installable archive and repository sources. All 63 product-source hashes match the reviewed tree. The archive records unchanged hashes for eight external host files. Product results contain ten recovery cases and one installed-product PASS; lifecycle evidence contains six native service scenarios. These are reviewed Forge executions, with a deterministic provider, not independently repeated end-to-end executions by Orion.

GitHub was queried directly for this commit and run `43262598125`: completed/success, with successful scope/version, Flutter three-layer QA, server and plugin jobs. This is CI for cffdbc5, not future fixes or independent Sentinel QA. The native Settings service evidence does not establish that the actual rendered settings entry is usable.

## Required remaining changes and ownership

Muse: fix the raw Dart `/v2/chat/send_attachment` parser so optional `cover` omission and explicit null follow the shared schema. The existing mandatory-presence check in `_attachment` rejects omission. Preserve type checking for a present non-null cover and existing v1 compatibility. Add shared-schema-driven omitted/null/valid/invalid tests, then run the actual client request seam and relevant Flutter checks. The MCP canonical-null workaround may remain but cannot substitute for a conforming client parser.

Forge: add bounded automatic history initialization for a newly selected/rebuilt native session, using existing BB query APIs. Current `Bridge.poll` reads only after consumed_through; `content` includes only that increment. An already-consumed conversation followed by a fresh native session therefore loses its earlier conversational context unless the model independently asks. Tool availability alone does not fulfill the original automatic-context requirement.

The minimal completion conditions are:

1. Given an established consumer with earlier committed messages, when its first new input is delivered to a fresh native session, nearby available history is included automatically with source identities and original ordered content. The implementation chooses and documents finite message/media/content budgets; omitted ranges or unavailable media are explicit with exact query continuation information. Do not fabricate summaries or replies.
2. Given the same existing/restored session, subsequent inputs remain incremental. A reconnect must not inject the same bootstrap history repeatedly. Use durable per-session/per-peer initialization evidence and public session persistence; do not create a second message database.
3. Context-only historical messages do not become new message jobs, new explicit sends, or a reason to advance an unpresented consumption gap. Prove initialization plus one new input preserves consumer isolation and the established successful-turn boundary.
4. Existing unsettled/uncertain work remains fenced: resuming its recorded session is acceptable for the demonstrated A/B/C recovery path. Do not treat selecting an unrelated session as recovery or discard uncertainty. If the original native session is unavailable, report the precise supported/unsupported state and recovery limitation; do not claim that case passes. A clean session change after settled work must be distinct from this case.

These are implementation and regression criteria for an original requirement, not another open-ended probe phase. Previously passed A/B/C/product scenarios are not reopened as unspecified blockers; run relevant regressions where the product paths change.

## Remaining execution evidence

Muse also owns validation through the target DSH's real rendered Settings entry in an isolated profile: installation visibility, editing connection/session/enabled configuration, readback after restart, disable/re-enable and removal behavior. Use the actual supported interface; do not assume a browser exists or replace it with a newly invented page. Capture sanitized UI evidence. Any bundle schema/lifecycle defect goes to Forge rather than editing the host.

Forge owns real-provider/model and vision integration through the installed bundle and native request path, alongside history initialization. Use two distinguishable synthetic images interleaved with text, record order separately from visual understanding, identify the actual model/provider/version and transport, and preserve explicit-send-only behavior. Use only authorized runtime credentials/configuration without exposing or copying credentials into artifacts; do not modify a personal profile. If no authorized usable provider exists, supply the concrete missing environment requirement and NOT RUN result while completing independent work; do not label deterministic results real.

Orion merges client and bundle changes into one PR SHA, collects actual CI for that SHA, then transitions to automated_qa for Sentinel's independent applicable checks including strict Flutter integration. Final handoff is Owner Review; no main merge, release or personal deployment. Windows/Android remain explicitly unverified, not inferred from Linux.
