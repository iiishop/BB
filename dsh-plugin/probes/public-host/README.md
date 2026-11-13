DEA-467 stock public-host capability probe
=========================================

Run from the repository root in a Multica task (the crash runner needs its
daemon PID safety check):

```bash
node dsh-plugin/probes/public-host/run.mjs "$DSH_PACKAGE_ROOT" ./probe-evidence
```

`DSH_PACKAGE_ROOT` is the installed `@deepseek-ai/dsh` package directory,
containing `package.json` and `node_modules`. Requires Node compatible with the
target installation and `pnpm` on PATH. This probe is pinned to DSH
0.2.1-rc.5, Cordis 4.0.5 and the stock AgentLoop SHA-256 recorded in `run.mjs`.
The runner rejects the patched AgentLoop before loading it. It creates a fresh
directory per invocation; no personal profile, credentials or global package
is edited. Do not point an evidence directory at a personal profile.

The installed host is read directly; core packages are neither mocked nor
patched. Worker environments contain only PATH, language and an owned DSH home.
Only the crash supervisor also receives the Multica executable/daemon port;
its native host children do not. The provider is a deterministic test double,
with no model or business API network traffic. `pnpm` may perform package-manager
metadata access when installing the local fixture. No credentials are passed.

The runner executes and collects, in order:

1. `lifecycle.mjs`: installed public PluginManager installs the local bundle;
   actual app-boot/Loader loads it; Settings edits its volatile Config, rejects
   a stale revision, and reads it after teardown/reboot. Disable/re-enable and
   bundle deselect/remove/reboot leave zero tools. Every mounted fixture effect
   has a corresponding disposal. This is an application-owned profile, not the
   full CLI/web composition. With no HMR, results correctly say
   `restart-required`; removal of a running bundle says `stop-profile`.
2. `storage.mjs write` and `read` in separate processes: real StorageDomain and
   JSON backend persist/reopen a synthetic stable binding. A separate negative
   domain demonstrates this release's invalid-write/open validation discrepancy.
3. `boundaries.mjs`: actual AgentLoop with deterministic provider checks busy
   FIFO, pending duplicate rejection, durable turn boundaries, and provider error.
4. The existing `probes/native/run.mjs`, freshly run against the stock host:
   9 workers and 4 exact-PID SIGKILL checkpoints; all recovered session facts
   and pre-resume crash prefixes are saved. No historical test output is reused.
5. Every hashed installation file is rechecked for unintended modification.

Exit **0 means the capability/negative assertions reproduced**. Read
`summary.json`: the delivery gate remains **BLOCKED**, not product acceptance.
Any failed assertion exits nonzero and retains `commands.json`. No run-owned
worker is intentionally left running. The output also includes `sources.json`
(versions, package/type/doc hashes, source-line signatures and probe hashes),
`lifecycle.json`, storage reports, request/turn traces and raw synthetic session
files. Keep evidence outside Git; attach it to the task for review.

The fixture deliberately omits locales/icon: it is a disposable test package,
the explicit exception in the installed development documentation. Its synthetic
state tool is not any BB business tool. No registration/login behavior is
changed or represented as validated. Settings rendering, HMR, real bridge
connections/subprocess lifecycle, wait/event matching, real provider/vision,
Flutter and BB integration remain NOT RUN. No patches are installed as a control.

See `docs/contracts/dea467-public-host-gate.md` for capability limits and
`docs/contracts/dea467-state-proposal.md` for the unapproved compatibility plan.
