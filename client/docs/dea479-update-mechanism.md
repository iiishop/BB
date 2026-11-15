# DEA-479 update mechanism and integration contract

Scope: issue revision 3 (same product body as scope v1), baseline
`e5ee59d3c9dcdb8dd64987c1ad5e6c76943b8d2d`. Forge owns this mechanism;
Muse owns Flutter UI and Android adapter. No server, DSH, deployment, tag or
release changes. This document is an implementation handoff, not device PASS.

## Flutter / Android wiring

`updates/update_contract.dart` is the shared protocol. Construct one
`ReleaseUpdateController(installer: ..., cacheDirectory: ...)` in the process
root, outside authentication/server-address stacks. Call `checkOnce()` without
awaiting it on startup. Subscribe to `snapshot` via the controller's
`ChangeNotifier`; settings calls `check()`. Download and installation are
separate explicit user actions (`download()`, then `install()`).

Windows adapter: `WindowsUpdateInstaller()`. Android implements `UpdateInstaller`
in `android_update_installer.dart`. `platformInfo()` returns the actual installed
version/build and precise ABI; no synthetic version. `install(VerifiedUpdate)`
revalidates the file and calls the system installer, returning
`permissionRequired` or `installerOpened`. Permission retry is explicit, after
returning from settings. The shared controller rehashes before every retry.

Use `InstallSafetyGate.instance` for all UI draft/media owners. Set a stable
owner's blocker while unsaved text, pending attachments, or retryable content
exists. Clear only on durable save, confirmed send, or explicit user discard.
Do not clear solely because a widget is disposed. Disable edits/navigation
that could create new drafts while `installing` is true; the gate provides
`addListener/removeListener` without importing Flutter into the standalone
service. `blockers` explains why installation is refused. UI must include profile
edits and media preparation as well as composer text. The service gate wraps
body/attachment/composed sends and avatar loading/upload/profile saves across
all awaits. Existing ledger recovery/idempotency is unchanged.

`snapshot.release.body` is the original text. Render safely without active HTML,
scripts or automatic link opening. Empty body fallback is UI-only. Failed
checks are visible in settings without repeated startup notifications. Unsupported
hosts should not construct an updater at the root.

## Selection and trust

Fetch up to 20 pages of 100 releases; an incomplete larger history fails closed.
Ignore draft, prerelease and invalid-version tags. Select the highest SemVer
greater than the installed version, regardless of listing order. Build metadata
does not change precedence. Test artifacts retain the real pubspec version:
they do not cause an equal-version update. Historical 0.2.0 will not offer
0.0.1; it needs a later formal release greater than 0.2.0. Do not reset versions
or change Android signing keys to work around this.

Asset names match the existing Release convention exactly, including ABI;
missing/duplicate assets refuse installation. Only the Release `SHA256SUMS`
asset is accepted; `SHA256SUMS.txt` in a test artifact is not a Release alias.
The selected asset IDs are frozen. Downloads use GitHub's repository-scoped
`/releases/assets/{id}` endpoint, rather than a mutable tag download URL.
HTTPS redirects only reach the explicit GitHub release CDN hosts. Byte lengths
must match metadata; SHA-256 must match the unique entry in SHA256SUMS. The
controller also rehashes the finished file at the install boundary. A checksum
is integrity evidence, not an independent signature or protection against a
compromised repository/release account.

The implementation follows the [GitHub release asset API](https://docs.github.com/en/rest/releases/assets).
No request includes credentials. Network errors/timeouts/rate limits can be
retried manually; there is no automatic download. Cancellation waits for I/O
and owned staging cleanup before admitting a retry. One action owns the state.

## Windows state and irreversible write order

The CMake-built `bb_updater.exe` uses Windows .NET Framework; it is copied outside
the installed payload before execution. It uses argument arrays and native
process APIs, not command strings, PATH tools or PowerShell on the user's machine.
`bb-build.json` is generated from Flutter build metadata, never inferred from a
filename. Packaging creates `bb-payload.sha256` identifying every owned file.

1. Acquire an exclusive sibling lock. Recover an unfinished previous transaction
   before starting a new one; completed transactions are archived as `.saved-*`.
2. Verify ZIP SHA-256 and current payload inventory. Reject an installation with
   no inventory or modified owned files, keeping it intact for manual upgrade.
3. Extract into sibling transaction `new`. Reject traversal, ADS, reserved names,
   duplicate case-insensitive names, symlinks/reparse points, unmanifested files,
   truncated entries and oversized archives. Verify every new payload file.
4. Write durable `prepared`, open the old process handle and signal `READY`.
   Only then may the gated Dart host exit. Wait on that exact process, with a
   90-second deadline. Never overwrite its running EXE.
5. After exit, copy unknown user files and empty directories to the staged tree.
   Conflicts refuse installation; no user file is deleted. Write `replacing`.
6. Rename installed directory to transaction `old`; rename `new` to the original
   application path, so shortcuts and relative FFmpeg/DLL/data paths remain valid.
7. Start the new app and wait up to 30 seconds for its native first-frame event.
   Commit only after that event. Failure stops the new process and restores `old`.

The old complete directory is retained, including user files. It is not deleted
automatically. Disk/permission/locked-file/preparation failures leave the old
directory intact or restore it. Account/config/ledger files are never rewritten
by the updater. A Windows permission failure that also prevents rollback is
reported with a retained backup and recovery helper; it is not called success.

Directory renames are individually atomic, not one atomic swap. Power loss in
between can leave the original path absent. The sibling
`.APPLICATION-NAME.bb-update/Recover BB.exe` and `root.txt` survive outside both
payloads: double-click the helper to restore the old directory after a cold
start. `state` and `update.log` record the transaction. The same recovery runs
before the next update attempt. Keep this directory until recovery completes.
No destructive cleanup of retained old/failed payloads is automatic.

## Verification and outstanding integration

Default Flutter tests include `test/release_update_test.dart`: actual loopback
HTTP with production URL validation, semantic ordering, original body, rate
limit/offline, exact assets, corrupt/short/redirected downloads, cancellation,
retry, tampering and the installation gate. Socket routing is the only transport
substitution; it does not claim real GitHub service or device validation.

The existing Windows package and Release jobs run `test_windows_updater.py`
using the actual built helper and isolated old/new installs. The GUI executable
is a fixture which acknowledges the real Windows named event. Cases cover
success, Chinese/spaced paths, no PATH FFmpeg, three exception boundaries,
crash→cold recovery→retry, hash/path/link rejection, locked payload and user-file
collisions. This proves native helper behavior, not Flutter GUI device behavior.
Linux reports these native tests as NOT RUN. Native logs remain in CI; no new
CI job or dependency installation is added for this suite.

After Muse's fixed SHA is integrated, run the existing full Flutter runner and
the Windows artifact on an actual Windows desktop; exercise explicit installation
with drafts/in-flight media present and absent. Android build, intent/permission
tests and user device install remain separately attributed to that adapter.
Final candidate and artifacts are handed to Orion for automated_qa; this branch
alone is not a completed integrated feature.
