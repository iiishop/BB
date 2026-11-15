# DEA-481 acceptance ownership and evidence

Source: approved issue product revision 1, verbatim in
`dea481-approved-space.md`; issue metadata was revision 3 at capture.
Forge owns shared contract, server state and final integration. Client/local
adapter/existing plugin owners are allocated by Orion after the contract commit.
Sentinel independently verifies the fixed complete integration candidate. Table
entries are intended checks, not PASS claims; actual results live in evidence.

| Case | Approved source | Forge server coverage | Remaining integration owner/path |
| --- | --- | --- | --- |
| T01 | §2, §9 T01 | private drafts, ten images, stable order, immutable publish | Client UI grid/viewer; local adapter/plugin real image read |
| T02 | §2.1, §7.3 | CAS, lost reply replay, unfinished attachment rejection | Client preserves local conflicting input |
| T03 | §7.3 | keyset ties/new insert/interaction order | Client scroll and refresh |
| T04 | §4.1 | arbitrary reply depth, 5/3 preview, root/descendant pagination | Client two indent levels |
| T05 | §5.3 | exact notification recipient; indexed context | Client notification focus |
| T06 | §4.2 | direct-only reference, independent counts | Client local back history |
| T07 | §6.1–3 | tombstones, protected images, no snippets, shared blob survival | Online/offline cache invalidation; MCP/local reads |
| T08 | §6.2 | parent deletion keeps children and identity; ACL | Client placeholders |
| T09 | §5.1–2 | sparse read bits, visit idempotency | Client lifecycle visit ID, explicit agent acknowledgement |
| T10 | §5.2 | author-only details; no visit notification | Local/MCP permission propagation |
| T11 | §5.3 | like membership/version acknowledgement race | Client notification rendering |
| T12 | §7.3–4 | transaction ordering/rollback/events/restart | Cross-process adapter and repeated invalidation handling |
| T13 | §3.3 | server bounded queries support navigation | Client Windows runtime and keyboard |
| T14 | §3.4 | no implicit read/visit side effects | Client fold/resize state and device evidence |
| T15 | §8 | shared complete capability DTOs | Existing plugin/real DSH installation, tools, images |
| T16 | §8.3–4 | authentication and durable server facts | Existing plugin host lifecycle, untrusted content/model |
| T17 | §3, §7.4 | replay events and capability discovery | Client cache/account/server isolation and old server |

Server tests cannot certify complete T01–T17 acceptance. In particular no schema,
TestClient or deterministic model evidence substitutes for standalone Dart,
rendered UI, actual installed DSH, visual model comprehension or target devices.
