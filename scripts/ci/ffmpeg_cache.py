#!/usr/bin/env python3
"""Exact-input, ref-isolated, content-addressed FFmpeg dependency cache.

The cache key's last component authenticates the restored tree against Actions
metadata, independently of the tree's manifest. The security boundary remains
GitHub's cache ref ACL: a writer of THIS ref can replace code/cache; another PR
cannot. Never promote PR caches to main/release or execute cached build scripts.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.parse
import urllib.request

from package_windows import sha256_file, validate_ffmpeg, read_manifest

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / 'client/windows/ffmpeg'
INPUTS = (
    'scripts/ci/ffmpeg_pins.py', 'scripts/ci/fetch_ffmpeg_sources.py',
    'scripts/ci/build_ffmpeg_windows.sh', 'scripts/ci/package_windows.py',
    'scripts/ci/ffmpeg_cache.py', '.github/workflows/windows-test-package.yml',
)
# Fingerprint rolling toolchain repositories BEFORE restore, without installing
# MSYS2. Any repository update invalidates the cache conservatively (including
# transitive compiler/runtime packages). Recheck after a cold build to avoid
# publishing under an input snapshot that changed during installation/build.
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


def verify_tree(root, expected):
    if tree_digest(root) != expected:
        raise RuntimeError('FFmpeg cache content digest mismatch (including manifest/licenses)')


def select_key(entries, prefix, ref):
    return next((item['key'] for item in entries
                 if item['ref'] == ref and
                 re.fullmatch(re.escape(prefix) + r'[0-9a-f]{64}', item['key'])), None)


def toolchain_digest():
    digest = hashlib.sha256()
    for url in TOOLCHAIN_DATABASES:
        with urllib.request.urlopen(url, timeout=120) as response:
            digest.update(response.read())
    return digest.hexdigest()


def output(**values):
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as handle:
        for name, value in values.items():
            print(f'{name}={value}', file=handle)
            print(f'{name}={value}')


def plan():
    toolchain = toolchain_digest()
    inputs = {name: sha256_file(ROOT / name) for name in INPUTS}
    inputs.update(toolchain=toolchain, target='windows-x86_64-MINGW64',
                  image=os.environ['ImageVersion'], ref=os.environ['GITHUB_REF'])
    prefix = 'bb-ffmpeg-v1-' + hashlib.sha256(
        json.dumps(inputs, sort_keys=True).encode()).hexdigest() + '-'
    query = urllib.parse.urlencode({'ref': os.environ['GITHUB_REF'], 'key': prefix,
                                   'per_page': 100})
    url = (f"https://api.github.com/repos/{os.environ['GITHUB_REPOSITORY']}"
           f'/actions/caches?{query}')
    request = urllib.request.Request(url, headers={
        'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
    })
    with urllib.request.urlopen(request, timeout=60) as response:
        entries = json.load(response)['actions_caches']
    key = select_key(entries, prefix, os.environ['GITHUB_REF'])
    output(prefix=prefix, key=key or prefix + 'miss', toolchain=toolchain)


def verify():
    hit = os.environ.get('CACHE_HIT') == 'true'
    if hit:
        key = os.environ['CACHE_KEY']
        prefix = os.environ['CACHE_PREFIX']
        if not re.fullmatch(re.escape(prefix) + r'[0-9a-f]{64}', key):
            raise RuntimeError('not an exact-input cache key')
        verify_tree(DEST, key[len(prefix):])
    # Hash the actual executable, NOT the self-reported manifest value. On hit
    # its entire tree has already been bound to the external Actions cache key.
    digest = sha256_file(DEST / 'ffmpeg.exe')
    validate_ffmpeg(DEST.parent, expected_ffmpeg_sha256=digest)
    if sha256_file(DEST / 'BUILD-FFMPEG.sh') != sha256_file(ROOT / INPUTS[2]):
        raise RuntimeError('cached build script differs from current build input')
    if not hit and toolchain_digest() != os.environ['TOOLCHAIN_DIGEST']:
        raise RuntimeError('MSYS2 repositories changed during build; rerun with fresh inputs')
    output(sha=digest, save_key=os.environ['CACHE_PREFIX'] + tree_digest(DEST))
    # Preserve original provenance; never relabel an old dependency as this app.
    print('Dependency built at BB commit:', read_manifest(DEST.parent)['build_script_git_commit'])
    print('Current application commit:', os.environ['GITHUB_SHA'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('plan', 'verify'))
    args = parser.parse_args()
    {'plan': plan, 'verify': verify}[args.operation]()
