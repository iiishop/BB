#!/usr/bin/env bash
set -euo pipefail

app=${1:?usage: smoke-macos-auth.sh unpacked-app evidence-directory}
evidence=${2:?missing evidence directory}
work="$(mktemp -d "${RUNNER_TEMP:?}/bb-auth-smoke.XXXXXX")"
mkdir -p "$evidence"
test -d "$app"

uv sync --project server --locked --no-dev
uv run --project server --locked --no-dev python -c '
from pathlib import Path
from sys import argv

import uvicorn
from bb_server.app import create_app

work = Path(argv[1])
app = create_app(str(work / "bb.db"), str(work / "avatars"), media_directory=str(work / "media"))
uvicorn.run(app, host="127.0.0.1", port=0, access_log=True)
' "$work" > "$evidence/auth-server.log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" || true' EXIT

server_url=""
for _ in {1..60}; do
  server_url="$(sed -En 's/.*Uvicorn running on (http:\/\/127\.0\.0\.1:[0-9]+) .*/\1/p' "$evidence/auth-server.log")"
  [[ -n "$server_url" ]] && break
  kill -0 "$server_pid" 2>/dev/null || break
  sleep 1
done
if [[ -z "$server_url" ]]; then
  cat "$evidence/auth-server.log"
  exit 1
fi

ruby scripts/ci/macos_auth_test_project.rb "$work" "$app" "$server_url" "$evidence/auth-server.log"
if ! xcodebuild test -project "$work/AuthSmoke.xcodeproj" -scheme AuthSmoke \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath "$work/DerivedData" -resultBundlePath "$work/AuthSmoke.xcresult" \
  2>&1 | tee "$evidence/auth-ui.log"; then
  xcrun xcresulttool export attachments --only-failures \
    --path "$work/AuthSmoke.xcresult" --output-path "$evidence/auth-ui-failures" || true
  exit 1
fi
grep -E '"POST /auth/register HTTP/[0-9.]+" 201( |$)' "$evidence/auth-server.log"
grep -E '"POST /auth/login HTTP/[0-9.]+" 200( |$)' "$evidence/auth-server.log"
