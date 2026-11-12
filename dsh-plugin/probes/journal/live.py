"""Real isolated Dart/FastAPI client seam: positive operation recovery and negative contracts.

uv run --project server --locked python dsh-plugin/probes/journal/live.py --help
No client production source edits. Private fake credentials/DB are never delivery artifacts.
"""

import argparse
import hashlib
import json
import os
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path

import httpx

parser = argparse.ArgumentParser()
parser.add_argument("--runtime", required=True)
parser.add_argument("--dart", required=True)
parser.add_argument("--crypto", required=True)
parser.add_argument("--output", required=True)
parser.add_argument(
    "--v2",
    action="store_true",
    help="Run positive guarded-contract assertions; no v1 fallback",
)
parser.add_argument(
    "--faults",
    action="store_true",
    help="Real v2 with BB public-DI fault barriers (no client source edits)",
)
parser.add_argument(
    "--remaining",
    action="store_true",
    help="Independent native/ownership/download/migration gates",
)
parser.add_argument(
    "--product", action="store_true", help="Product bundle recovery gates"
)
parser.add_argument(
    "--context", action="store_true", help="Real native session history initialization"
)
parser.add_argument(
    "--settings",
    action="store_true",
    help="Rendered native settings with real BB client",
)
args = parser.parse_args()
if not any(
    (args.v2, args.faults, args.remaining, args.product, args.context, args.settings)
):
    args.v2 = True
repo = Path(__file__).resolve().parents[3]
parent = Path(args.output).resolve()
parent.mkdir(parents=True, exist_ok=True)
root = Path(tempfile.mkdtemp(prefix="dea467-client-", dir=parent))
private = root / "private"
private.mkdir(mode=0o700)
owned = []
results = []
safe_env = {key: os.environ[key] for key in ["PATH", "LANG"] if key in os.environ}
external_files = [
    "dsh-agent-loop/lib/index.js",
    "dsh-agent/lib/types/runtime-types.d.ts",
    "dsh-llm/lib/index.js",
    "dsh-tools/lib/index.js",
    "dsh-session/lib/index.js",
    "dsh-session-persistence-jsonl/lib/index.js",
    "dsh-storage-domain/lib/index.js",
    "dsh-storage-json/lib/index.js",
]


def host_hashes():
    base = Path(args.runtime) / "node_modules/@deepseek-ai"
    return {
        name: hashlib.sha256((base / name).read_bytes()).hexdigest()
        for name in external_files
    }


fixed_host = host_hashes()
assert (
    fixed_host[external_files[0]]
    == "cf57e3ecd487ac5c2553455aaa5cef2c6fb41e6bd61be5aa455675d1d7193033"
)


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def launch(command, name, env=None, pipe=False):
    log = None if pipe else open(private / f"{name}.log", "w", encoding="utf-8")  # noqa: SIM115 - owned until child teardown in finally
    child = subprocess.Popen(
        command,
        cwd=repo,
        env=env or safe_env,
        stdout=subprocess.PIPE if pipe else log,
        stderr=subprocess.PIPE if pipe else log,
        text=True,
    )
    owned.append((child, log))
    return child


def stop(child, crash=False):
    assert any(item is child for item, _ in owned)
    if child.poll() is not None:
        return
    daemon = json.loads(
        subprocess.check_output(
            [os.environ["MULTICA_CLI_PATH"], "daemon", "status", "--output", "json"]
        )
    )
    assert child.pid != daemon["pid"]
    child.send_signal(signal.SIGKILL if crash else signal.SIGTERM)
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        assert child.pid != daemon["pid"]
        child.kill()
        child.wait(timeout=5)


def ready(origin, child):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        assert child.poll() is None, "local service exited; inspect private startup log"
        try:
            httpx.get(origin + "/", timeout=0.2, trust_env=False)
            return
        except httpx.TransportError:
            time.sleep(0.05)
    raise AssertionError("local service readiness deadline")


def post(origin, path, body, headers=None):
    return httpx.post(
        origin + path, json=body, headers=headers, timeout=10, trust_env=False
    )


def record(name, **facts):
    value = {"name": name, **facts}
    results.append(value)
    print(json.dumps(value), flush=True)
    (root / "results.json").write_text(json.dumps(results, indent=2) + "\n")


def record_sources():
    paths = list((repo / "client/lib/services").glob("*.dart"))
    paths += list(Path(__file__).parent.glob("*.py"))
    paths += list(Path(__file__).parent.glob("*.mjs"))
    paths += list(Path(__file__).parent.glob("*.dart"))
    paths += list((repo / "dsh-plugin/bundle").rglob("*.*"))
    paths += list((repo / "dsh-plugin/src").rglob("*.py"))
    paths += [repo / "dsh-plugin/build_bundle.py", repo / "dsh-plugin/uv.lock"]
    paths += list((repo / "dsh-plugin/probes/product").glob("*.mjs"))
    paths += [repo / "server/uv.lock", repo / "server/contract/chat-v2-openapi.json"]
    (root / "sources.json").write_text(
        json.dumps(
            {
                "git_commit": subprocess.check_output(
                    ["git", "rev-parse", "HEAD"], cwd=repo, text=True
                ).strip(),
                "external_files": fixed_host,
                "files": {
                    str(path.relative_to(repo)): hashlib.sha256(
                        path.read_bytes()
                    ).hexdigest()
                    for path in paths
                },
                "client_tree": subprocess.check_output(
                    ["git", "rev-parse", "HEAD:client"], cwd=repo, text=True
                ).strip(),
            },
            indent=2,
        )
        + "\n"
    )


record_sources()
try:
    api_port, client_port = port(), port()
    api, client = f"http://127.0.0.1:{api_port}", f"http://127.0.0.1:{client_port}"
    server = launch(
        [str(repo / "server/.venv/bin/python"), "-m", "bb_server"],
        "server",
        dict(
            safe_env,
            BB_DATABASE_PATH=str(private / "server.db"),
            BB_AVATAR_DIRECTORY=str(private / "avatars"),
            BB_MEDIA_DIRECTORY=str(private / "media"),
            BB_HOST="127.0.0.1",
            BB_PORT=str(api_port),
        ),
    )
    ready(api, server)
    accounts = []
    for name in ("ProbeAlice", "ProbeBob", "ProbeCarol"):
        response = post(api, "/auth/register", {"username": name, "password": "Abc123"})
        assert response.status_code == 201
        accounts.append(response.json()["account"])
    account, peer, switched = accounts
    config = private / "package_config.json"
    config.write_text(
        json.dumps(
            {
                "configVersion": 2,
                "packages": [
                    {
                        "name": "bb_client",
                        "rootUri": (repo / "client").as_uri() + "/",
                        "packageUri": "lib/",
                        "languageVersion": "3.13",
                    },
                    {
                        "name": "crypto",
                        "rootUri": Path(args.crypto).resolve().as_uri() + "/",
                        "packageUri": "lib/",
                        "languageVersion": "3.4",
                    },
                ],
            }
        )
    )
    control_port = port()
    dart_entry = (
        Path(__file__).with_name("client_fault_host.dart")
        if args.faults or args.remaining
        else repo / "client/bin/bb_client_api.dart"
    )
    dart_command = [
        args.dart,
        "--packages=" + str(config),
        str(dart_entry),
        "--port",
        str(client_port),
        "--server-url",
        api,
        "--session-file",
        str(private / "dart/session.json"),
    ]
    if args.faults or args.remaining:
        dart_command += ["--control-port", str(control_port)]
    dart = launch(dart_command, "client-first")
    ready(client, dart)
    assert (
        post(
            client, "/auth/login", {"account": account, "password": "Abc123"}
        ).status_code
        == 200
    )
    if (
        args.v2
        or args.faults
        or args.remaining
        or args.product
        or args.context
        or args.settings
    ):
        if args.settings:
            from live_settings import run
        elif args.context:
            from live_context import run
        elif args.product:
            from live_product import run
        elif args.remaining:
            from live_remaining import run
        elif args.faults:
            from live_faults import run
        else:
            from live_v2 import run

        def restart_client(*, crash=False):
            global dart
            stop(dart, crash=crash)
            dart = launch(dart_command, "client-v2-restarted")
            ready(client, dart)

        try:
            extra = (
                {
                    "api": api,
                    "control": f"http://127.0.0.1:{control_port}",
                    "dart_executable": args.dart,
                    "packages": str(config),
                }
                if args.faults
                or args.remaining
                or args.product
                or args.context
                or args.settings
                else {}
            )
            run(
                origin=client,
                account=account,
                peer=peer,
                switched=switched,
                runtime=args.runtime,
                root=root,
                private=private,
                launch=launch,
                stop=stop,
                restart=restart_client,
                record=record,
                **extra,
            )
        except Exception as error:
            record("v2-gate", status="FAIL", reason=str(error))
            raise
        raise SystemExit(0)

finally:
    for child, log in reversed(owned):
        stop(child)
        if log:
            log.close()
    unchanged = host_hashes() == fixed_host
    (root / "host-integrity.json").write_text(
        json.dumps({"external_files_unchanged": unchanged, "count": len(fixed_host)})
        + "\n"
    )
    assert unchanged, "fixed external host source changed during probe"
    print(json.dumps({"evidence": str(root), "private_excluded": True}), flush=True)
