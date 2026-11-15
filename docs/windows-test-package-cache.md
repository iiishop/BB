# Windows test-package dependency cache

`windows-test-package.yml` remains PR/manual-only. Release still builds FFmpeg
from source independently: no PR cache is promoted to a release. Both entrypoints
use `package_windows.validate_ffmpeg` through the final bundle validator.

## Inputs and invalidation

The cache input digest binds source pins/checksums, fetch/build scripts (including
all configure flags), validator/cache code, the whole workflow (MSYS2 setup and
package list), Windows runner ImageVersion, x86_64/MINGW64 target and exact GitHub
ref. It also hashes the upstream MSYS2 mingw64 and msys package databases so a
rolling toolchain or transitive-package update conservatively invalidates it.
Cold builds recheck these databases before saving; an update during the build
fails closed and requires a rerun. Source suppliers are unchanged.

The full key is `bb-ffmpeg-v1-<input digest>-<dependency tree digest>`. Discovery
uses the cache API filtered to the **exact ref and exact input prefix**, then
requires a full 64-character content digest suffix. Restore receives this exact
key, never `restore-keys`. A missing/evicted entry rebuilds. A corrupt hit fails
closed, not silently rebuilt or republished. Delete that exact cache and rerun
if it is corrupt. Bumping the namespace also forces a rebuild.

## Trust and integrity

The tree digest binds filenames and every shipped byte (EXE, licenses, manifest,
notice, build script). It comes from GitHub cache metadata, not a hash claimed by
the restored manifest. Changing both EXE and its manifest cannot pass the old
key. After that check, compute the EXE SHA directly and run the same pinned
manifest/license/PE/size validation used by packaging. Check the bundled build
script against the current repository script. Pass the directly measured EXE
hash to final and extracted ZIP validation, unchanged.

This is integrity within GitHub's cache trust boundary, **not a signature from
an independent builder**. A writer with code/cache execution on the same ref can
create a different content-addressed entry and is already trusted to run code.
Exact-ref isolation means another PR cannot populate this PR's cache; PR merge
refs cannot seed main/release. Default/base-branch fallback is deliberately not
used. Forks still require normal GitHub workflow approval. No write-scoped token
or secrets are added (`actions: read` only for cache discovery).

The original `build_script_git_commit` and notice stay unchanged on a hit: they
identify the dependency build, **not** the current app. Verification prints both
dependency build commit and current app checkout SHA. Only the dependency folder
is cached, never the Flutter app/bundle/ZIP. Save occurs after final package smoke.

## Paths and checks

PR filters cover shared `client/lib`, Windows native files, assets, pubspec/lock,
Flutter metadata, the two Windows test entrypoints plus shared fixtures/support,
and the actual FFmpeg/package helper graph and smoke fixtures. QA evidence
parsing/tests, unrelated CI helpers, other platforms and docs do not trigger a
Windows package. `workflow_dispatch` is retained. When adding assets outside
`client/assets`, a path dependency, or a new imported helper, update these filters
and their regression cases alongside that change.

On hits only source download, MSYS2 setup and FFmpeg compile are skipped. Flutter
release build, the two Windows test suites, no-system-FFmpeg fixture smoke,
ZIP/size/checksum inspection and Chinese/space-path extracted recheck always run.

Local regression: `python -m unittest discover -s scripts/ci -p 'test_*.py' -v`.
YAML/action expressions: `actionlint -shellcheck= .github/workflows/windows-test-package.yml .github/workflows/release.yml`.

For cold/warm evidence rerun this PR's successful Windows run once: the PR merge
ref stays the same and it does not trigger unrelated workflows. A manual branch
run has a different ref from the PR and intentionally starts a separate cache.
