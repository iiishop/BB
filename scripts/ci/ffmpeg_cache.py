#!/usr/bin/env python3
"""Resolve and verify the Windows FFmpeg dependency.

Two sources, one content check:

* ``asset``  — download the pinned prebuilt dependency published as a Release
  asset. Pull-request jobs use this path; it replaces a ~528s source build that
  dominated the job runtime.
* ``source`` — build from the pinned FFmpeg/zlib sources inside this job. Manual
  runs use this. The release workflow builds independently and never consumes
  the asset, so a published binary is never an input to a published release.

Both paths end in ``verify``: the actual executable is hashed, the manifest is
checked against the pins, the licenses are read, and the BUILD-FFMPEG.sh inside
the dependency must be byte-identical to the one in this repository. That last
check is what makes a stale asset fail loudly instead of quietly shipping an
old build — edit the build script and the prebuilt tree stops being acceptable.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import urllib.request
import zipfile

from ffmpeg_pins import (
    FFMPEG_DEPS_ARCHIVE_SHA256,
    FFMPEG_DEPS_ASSET,
    FFMPEG_DEPS_TAG,
    FFMPEG_DEPS_TREE_DIGEST,
)
from package_windows import read_manifest, sha256_file, validate_ffmpeg

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / 'client/windows/ffmpeg'
BUILD_SCRIPT = 'scripts/ci/build_ffmpeg_windows.sh'
# Fingerprint rolling toolchain repositories so a manual source build cannot
# publish under an input snapshot that changed while it was running.
TOOLCHAIN_DATABASES = (
    'https://repo.msys2.org/mingw/mingw64/mingw64.db',
    'https://repo.msys2.org/msys/x86_64/msys.db',
)


def tree_digest(root):
    entries = {}
    for path in sorted(Path(root).rglob('*')):
        if path.is_symlink():
            raise RuntimeError('symlinks are not allowed in the dependency cache')
        if path.is_file() and path.name != '.gitignore':
            entries[path.relative_to(root).as_posix()] = sha256_file(path)
    return hashlib.sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest()


def verify_tree(root, expected, reason='FFmpeg cache content digest mismatch '
                                       '(including manifest/licenses)'):
    if tree_digest(root) != expected:
        raise RuntimeError(reason)


def toolchain_digest():
    digest = hashlib.sha256()
    for url in TOOLCHAIN_DATABASES:
        with urllib.request.urlopen(url, timeout=120) as response:
            digest.update(response.read())
    return digest.hexdigest()


def normalized_digest(path):
    """Hash text content with line endings folded to LF.

    The dependency is built on Windows (CRLF working tree) while the repository
    checkout here may use LF, so a raw byte comparison would pass on the runner
    and fail on a Linux runner for the same script. Only line endings are
    folded — any real edit still changes the digest.
    """
    data = Path(path).read_bytes().replace(b'\r\n', b'\n')
    return hashlib.sha256(data).hexdigest()


def output(**values):
    handle = os.environ.get('GITHUB_OUTPUT')
    if handle is None:
        for name, value in values.items():
            print(f'{name}={value}')
        return
    with open(handle, 'a', encoding='utf-8') as sink:
        for name, value in values.items():
            print(f'{name}={value}', file=sink)
            print(f'{name}={value}')


def dependency_url():
    repo = os.environ.get('GITHUB_REPOSITORY', 'iiishop/BB')
    return (f'https://github.com/{repo}/releases/download/'
            f'{FFMPEG_DEPS_TAG}/{FFMPEG_DEPS_ASSET}')


def clear_dependency_dir():
    """Empty the dependency directory without touching its tracked .gitignore.

    A zip extracted over a stale tree would leave old entries behind and change
    the digest, so the directory is cleared first — but `.gitignore` is a
    tracked placeholder for the empty directory and must survive.
    """
    DEST.mkdir(parents=True, exist_ok=True)
    for entry in DEST.iterdir():
        if entry.name == '.gitignore':
            continue
        if entry.is_dir():
            shutil.rmtree(entry)
        else:
            entry.unlink()


def fetch():
    request = urllib.request.Request(dependency_url(), headers={
        'Accept': 'application/octet-stream',
        'User-Agent': 'bb-windows-package-ci',
    })
    token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if token:
        request.add_header('Authorization', 'Bearer ' + token)
    with urllib.request.urlopen(request, timeout=300) as response:
        data = response.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != FFMPEG_DEPS_ARCHIVE_SHA256:
        raise RuntimeError(
            f'prebuilt dependency archive sha256 mismatch: {digest} '
            f'!= {FFMPEG_DEPS_ARCHIVE_SHA256}')
    clear_dependency_dir()
    with zipfile.ZipFile(io.BytesIO(data)) as bundle:
        bundle.extractall(DEST)
    print(f'downloaded {FFMPEG_DEPS_TAG}/{FFMPEG_DEPS_ASSET}: {len(data)} bytes')


def snapshot():
    value = toolchain_digest()
    output(toolchain=value)


def verify():
    source = os.environ.get('FFMPEG_SOURCE', 'source')
    if source == 'asset':
        verify_tree(DEST, FFMPEG_DEPS_TREE_DIGEST,
                    'prebuilt dependency tree digest mismatch '
                    '(including manifest/licenses)')
    elif source == 'source':
        if toolchain_digest() != os.environ['TOOLCHAIN_DIGEST']:
            raise RuntimeError(
                'MSYS2 repositories changed during build; rerun with fresh inputs')
    else:
        raise RuntimeError(f'unknown FFMPEG_SOURCE: {source!r}')
    # Hash the actual executable, NOT the self-reported manifest value.
    digest = sha256_file(DEST / 'ffmpeg.exe')
    validate_ffmpeg(DEST.parent, expected_ffmpeg_sha256=digest)
    if normalized_digest(DEST / 'BUILD-FFMPEG.sh') != normalized_digest(ROOT / BUILD_SCRIPT):
        raise RuntimeError(
            f'dependency build script differs from {BUILD_SCRIPT}; '
            f'regenerate {FFMPEG_DEPS_TAG} or rebuild from source')
    output(sha=digest)
    print('Dependency source:', source)
    # Preserve original provenance; never relabel an old dependency as this app.
    print('Dependency built at BB commit:',
          read_manifest(DEST.parent)['build_script_git_commit'])
    print('Current application commit:', os.environ.get('GITHUB_SHA', '(local)'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('fetch', 'verify', 'snapshot'))
    args = parser.parse_args()
    {'fetch': fetch, 'verify': verify, 'snapshot': snapshot}[args.operation]()
