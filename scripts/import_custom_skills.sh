#!/usr/bin/env bash
# Explicit, one skill at a time: uploads Skill content to your Multica workspace.
# Inspect archives before running. Requires multica CLI authenticated for your workspace.
set -Eeuo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_dir="$script_dir/../skills/importable"
command -v multica >/dev/null || { echo 'multica CLI not found' >&2; exit 2; }
echo "Importing project-only skills from: $skill_dir"
for zip in "$skill_dir"/*.skill; do
  echo "Import: $zip"
  multica skill import --file "$zip"
done
echo 'Import finished. IMPORTANT: Bind each skill to its agent in Multica; import alone does not activate it.'
