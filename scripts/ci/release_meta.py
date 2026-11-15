"""Fail-closed release metadata. Run from the repository root (stdlib only)."""
import os
from pathlib import Path
import re


def main():
    text = Path('client/pubspec.yaml').read_text(encoding='utf-8')
    match = re.search(r'^version: (\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)\+(\d+)\s*$', text, re.M)
    if not match:
        raise ValueError('pubspec must contain a semantic version and build number')
    version = match[1]
    sha = os.environ['GITHUB_SHA']
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('GITHUB_SHA must be a full commit SHA')
    publish = os.environ['EVENT'] == 'push' and os.environ['REF_TYPE'] == 'tag'
    if publish and os.environ['REF_NAME'] != f'v{version}':
        raise ValueError('tag must match pubspec version')
    print(f'version={version}')
    print('has_client=true')
    print(f'publish={str(publish).lower()}')
    # Dots work in deb/rpm/Arch versions; hyphens do not work in rpm Version.
    print(f'package_version={version}' + ('' if publish else f'.test.{sha[:12]}'))
    print(f'short_sha={sha[:12]}')


if __name__ == '__main__':
    main()
