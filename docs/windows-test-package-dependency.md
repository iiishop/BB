# Windows FFmpeg dependency

Both Windows jobs (`.github/workflows/windows-test-package.yml` for PRs and the
`windows` job in `release.yml` for a tagged release) consume the same pinned
prebuilt dependency. Neither compiles FFmpeg per run any more; a source build
cost 528s of a 860s job and repeated it on every PR and every release.

## Two sources, one content check

| Trigger | Source | Cost |
| --- | --- | --- |
| `pull_request` | pinned prebuilt asset (`ffmpeg-deps-8.1.3`) | seconds |
| `workflow_dispatch` with `source_build: true` | compile from pinned sources | ~9 minutes |
| tag release (`release.yml`) | pinned prebuilt asset | seconds |

A source build used to run on **every** PR run. The `actions/cache` layer that
was supposed to avoid it never hit: the key embedded the exact GitHub ref (so a
new branch was always cold) and a hash of the upstream MSYS2 package databases
(so even the same branch expired within hours), and `main` never ran that
workflow, so no baseline ever existed. That mechanism is removed.

`workflow_dispatch` with `source_build: true` remains the way to re-derive the
dependency from source (see "Regenerating it"). `release.yml` has no such
toggle: if the asset is wrong at release time, publishing stops at `verify`.

Both paths end in the same `ffmpeg_cache.py verify`, which always runs:

1. the actual `ffmpeg.exe` is hashed (never the manifest's self-reported value);
2. `validate_ffmpeg` checks the manifest pins, the license markers, the PE
   header and the size floor against the final bundle layout;
3. `BUILD-FFMPEG.sh` inside the dependency must match
   `scripts/ci/build_ffmpeg_windows.sh` in the repository, with line endings
   folded to LF so a Windows build tree and a Linux checkout compare equal.

Step 3 is the invalidation rule: edit the build script and the prebuilt asset
stops being acceptable, forcing a source rebuild.

## The prebuilt asset

Published as Release `ffmpeg-deps-8.1.3`, asset `ffmpeg-8.1.3-windows-x64.zip`.
`ffmpeg_pins.py` holds three values: the archive SHA-256, the directory tree
digest, and the tag/asset names.

- `fetch` downloads, checks the archive hash, then extracts over
  `client/windows/ffmpeg`.
- `verify` with `FFMPEG_SOURCE=asset` recomputes the tree digest and refuses a
  mismatch, then runs the shared content checks above.
- The tree digest covers filenames and every shipped byte: EXE, licenses,
  manifest, notice, build script.

`BUILD-MANIFEST.txt` keeps `build_script_git_commit` pointing at the commit that
actually built the dependency. That is provenance for the dependency, not for
the current app; verification prints both values.

**Regenerating it** (only needed when the pins or the build script change):

```bash
# 1. run the workflow by hand with the slow path
gh workflow run windows-test-package.yml --ref main -f source_build=true
# 2. take the ffmpeg/ folder out of the resulting bb-windows-test-package artifact
# 3. zip its contents (no folder prefix), publish as the next ffmpeg-deps-* tag
# 4. update FFMPEG_DEPS_TAG / _ASSET / _ARCHIVE_SHA256 / _TREE_DIGEST
```

A stale asset fails closed: `verify` refuses a tree digest that moved, and
refuses an asset whose build script no longer matches the repository.

## Trust boundary

The asset is a build output of this repository's own CI, pinned by hash, and it
is now the input to published releases as well. What replaces the old "compile
it again at release time" ritual is a stronger, checkable statement:

- the archive hash and the extracted tree digest are constants in
  `ffmpeg_pins.py`;
- the `BUILD-FFMPEG.sh` shipped inside the asset must be byte-identical (line
  endings folded) to `scripts/ci/build_ffmpeg_windows.sh`, so changing the build
  recipe invalidates the asset instead of silently shipping an older build;
- `verify` hashes the actual `ffmpeg.exe` and runs the same manifest/license/PE
  validation the packager uses.

Rebuilding from source every time proved nothing extra — it produced a different
binary each run (MSYS2 packages roll) and was accepted on trust anyway. The pins
are what actually constrain the artifact.

It is still not a signature from an independent builder. Anyone who can publish
a Release in this repository can replace the asset, but the hash pins live in
the repository, so a replacement has to land in a reviewable diff.

## Paths and checks

PR filters cover shared `client/lib`, Windows native files, assets,
pubspec/lock, Flutter metadata, the Windows test entrypoints plus shared
fixtures/support, and the FFmpeg/package helper graph and smoke fixtures. QA
evidence parsing, unrelated CI helpers, other platforms and docs do not trigger
a Windows package. When adding assets outside `client/assets`, a path
dependency, or a new imported helper, update these filters and their regression
cases alongside that change.

Only the dependency acquisition step differs between sources. Flutter release
build, the Windows test suites, no-system-FFmpeg fixture smoke, ZIP/size/
checksum inspection and the Chinese/space-path extracted recheck always run.

Local regression: `python -m unittest discover -s scripts/ci -p 'test_*.py' -v`.
YAML/action expressions: `actionlint -shellcheck= .github/workflows/windows-test-package.yml .github/workflows/release.yml`.

End-to-end check of the asset without CI:

```bash
FFMPEG_SOURCE=asset python scripts/ci/ffmpeg_cache.py fetch
FFMPEG_SOURCE=asset python scripts/ci/ffmpeg_cache.py verify
```

That works on Linux: the fetch and the content validation are platform-neutral.
