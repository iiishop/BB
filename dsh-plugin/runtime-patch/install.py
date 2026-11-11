"""Copy a pinned runtime before patching it. Never edit or link shared dependencies."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent / '.runtime'
LOCK = json.loads((HERE / 'lock.json').read_text())
HELPER = 'node_modules/@deepseek-ai/dsh-agent-loop/lib/bb-recovery.mjs'
MARKER = '.bb-build.json'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree(root, normalize=False):
    digest = hashlib.sha256()
    count = 0
    for directory, dirs, files in os.walk(root):
        if any((Path(directory) / name).is_symlink() for name in dirs):
            raise ValueError('Directory symlinks are not supported')
    for path in sorted(p for p in root.rglob('*') if p.is_file()):
        rel = path.relative_to(root).as_posix()
        if normalize and rel in (HELPER, MARKER):
            continue
        value = LOCK['original_sha256'] if normalize and rel == LOCK['target'] else sha(path)
        digest.update((rel + '\0' + value + '\n').encode())
        count += 1
    return digest.hexdigest(), count


def destination(value):
    path = Path(value).absolute()
    # Only a new direct child of this project's runtime directory is writable.
    if ROOT.is_symlink() or path.is_symlink() or path.parent.resolve() != ROOT.resolve():
        raise ValueError('Destination must be a non-symlink direct child of dsh-plugin/.runtime')
    return path


def verify(path):
    require(path.is_dir() and not path.is_symlink(), 'Missing runtime or linked root')
    require((path / MARKER).is_file(), 'Incomplete build')
    require(sha(path / LOCK['target']) == LOCK['patched_sha256'], 'Patched source mismatch')
    require(sha(path / HELPER) == LOCK['helper_sha256'], 'Recovery helper mismatch')
    require(tree(path, True) == (LOCK['tree_sha256'], LOCK['files']), 'Dependency tree mismatch')
    require(not any(p.is_symlink() for p in path.rglob('*')), 'Runtime must contain no dependency links')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source')
    parser.add_argument('--destination', required=True)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    require(platform.system().lower() == LOCK['platform'] and platform.machine() == LOCK['machine'], 'Platform mismatch')
    require(sha(HERE / 'agent-loop.patch') == LOCK['patch_sha256'], 'Patch mismatch')
    require(sha(HERE / 'recovery.mjs') == LOCK['helper_sha256'], 'Helper source mismatch')
    target = destination(args.destination)
    if args.verify:
        verify(target)
        print(json.dumps({'verified': True, 'runtime': str(target)}))
        return
    if not args.source:
        parser.error('--source is required for installation')
    source = Path(args.source).resolve(strict=True)
    require(not target.exists(), 'Refuse to overwrite an existing runtime')
    require(not source.is_relative_to(ROOT.resolve()), 'Use the pinned original source, not another patched copy')
    require(json.loads((source / 'package.json').read_text())['version'] == LOCK['dsh_version'], 'DSH version mismatch')
    require(tree(source) == (LOCK['tree_sha256'], LOCK['files']), 'Source version/tree hash mismatch')
    ROOT.mkdir(exist_ok=True)
    # copy2 creates distinct files; symlinks=False dereferences input file links.
    shutil.copytree(source, target, symlinks=False)
    require(tree(target) == (LOCK['tree_sha256'], LOCK['files']), 'Copied tree mismatch')
    for path in target.rglob('*'):
        require(not path.is_symlink(), 'Copied dependency link detected')
        if path.is_file():
            require(not os.path.samefile(path, source / path.relative_to(target)), 'Shared inode detected')
    subprocess.run(['patch', '--batch', '--fuzz=0', '-p1', '-i', str(HERE / 'agent-loop.patch')], cwd=target, check=True)
    shutil.copyfile(HERE / 'recovery.mjs', target / HELPER)
    (target / MARKER).write_text(json.dumps({'patch': 'bb-recovery-1', 'lock': LOCK}, indent=2) + '\n')
    verify(target)
    print(json.dumps({'installed': True, 'patch': 'bb-recovery-1', 'runtime': str(target)}))


if __name__ == '__main__':
    main()
