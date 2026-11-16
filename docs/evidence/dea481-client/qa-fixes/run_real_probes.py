import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

work = Path('/home/iiishop/multica_workspaces/deardeer-60c9c9e52ffd/dea-481-3b7c69547e25/workdir')
root = work / 'BB'
out = work / 'qa-probes'
out.mkdir(exist_ok=True)
state = work / 'real-probe-state'
state.mkdir(exist_ok=True)
for name in ('db.sqlite',):
    (state / name).unlink(missing_ok=True)

with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
base = f'http://127.0.0.1:{port}'

server_env = dict(
    os.environ,
    BB_DATABASE_PATH=str(state / 'test.db'),
    BB_MEDIA_DIRECTORY=str(state / 'media'),
    BB_AVATAR_DIRECTORY=str(state / 'avatars'),
    BB_HOST='127.0.0.1',
    BB_PORT=str(port),
    UV_CACHE_DIR=str(work / '.uv-cache'),
    TMPDIR=str(work / '.tmp'),
)

log = (out / 'server.log').open('w')
server = subprocess.Popen(
    ['/usr/bin/uv', 'run', '--project', 'server', '--locked', 'python', '-m', 'bb_server'],
    cwd=root,
    env=server_env,
    stdout=log,
    stderr=subprocess.STDOUT,
    start_new_session=True,
)
try:
    for _ in range(300):
        if server.poll() is not None:
            raise RuntimeError('server exited early; see server.log')
        try:
            urllib.request.urlopen(base + '/auth/session', timeout=1)
        except urllib.error.HTTPError as error:
            if error.code == 401:
                break
        except OSError:
            pass
        time.sleep(0.1)
    else:
        raise RuntimeError('server readiness timeout')

    flutter = work / 'flutter-sdk' / 'bin' / 'flutter'
    client_env = dict(
        os.environ,
        BB_SPACE_API_BASE=base,
        PUB_CACHE=str(work / '.pub-cache'),
        TMPDIR=str(work / '.tmp'),
        PATH=f"{work / 'flutter-sdk' / 'bin'}:{os.environ.get('PATH', '')}",
    )
    command = [
        str(flutter), 'test', '--no-pub',
        '.qa-artifacts/probes/space_defect_probe_test.dart',
        '.qa-artifacts/probes/adjacent_draft_probe_test.dart',
        '--reporter=expanded',
    ]
    run_log = (out / 'real-probes.log').open('w')
    result = subprocess.run(command, cwd=root / 'client', env=client_env,
                            stdout=run_log, stderr=subprocess.STDOUT)
    run_log.close()
    (out / 'real-probes.exit').write_text(str(result.returncode) + '\n')
    print('probes-exit:', result.returncode)
    sys.exit(result.returncode)
finally:
    try:
        os.killpg(server.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        server.wait(timeout=15)
    except subprocess.TimeoutExpired:
        os.killpg(server.pid, signal.SIGKILL)
        server.wait(timeout=10)
    log.close()
