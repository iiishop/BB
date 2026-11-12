"""Actual stock web UI, isolated client and browser. No provider credentials used."""

import json
import os
import socket
import subprocess
import time
from pathlib import Path


def run(
    *,
    origin,
    account,
    peer,
    switched,
    api,
    runtime,
    root,
    private,
    launch,
    stop,
    record,
    **unused,
):
    repo = Path(__file__).resolve().parents[3]
    here = repo / "dsh-plugin/probes/product"
    playwright = os.environ.get("BB_PROBE_PLAYWRIGHT")
    chromium = os.environ.get("BB_PROBE_CHROMIUM")
    assert playwright and chromium, (
        "Set existing BB_PROBE_PLAYWRIGHT package.json and BB_PROBE_CHROMIUM executable"
    )
    bundle = root / "bundle"
    subprocess.run(
        ["python3", str(repo / "dsh-plugin/build_bundle.py"), str(bundle)],
        check=True,
        capture_output=True,
    )
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    env = {
        **{key: os.environ[key] for key in ("PATH", "LANG") if key in os.environ},
        "DSH_HOME": str(private / "dsh-home"),
        "BB_PROBE_RUNTIME": runtime,
    }
    status_case = os.environ.get("BB_SETTINGS_CASES") == "status"
    if status_case:
        env["BB_PROBE_STATUS"] = "1"
    cli = str(Path(runtime) / "lib/bin.js")
    subprocess.run(
        [
            "node",
            cli,
            "--profile",
            "bb-settings-test",
            "--from-default-profile",
            "web",
            "--help",
        ],
        env=env,
        check=True,
        capture_output=True,
    )
    overlay = private / "fixture-overlay.json"
    overlay.write_text(
        json.dumps(
            [
                {
                    "insert": [
                        {
                            "id": "bb-settings-test",
                            "name": str(here / "settings-fixture.mjs"),
                        }
                    ]
                }
            ]
        )
    )
    for phase in ["status"] if status_case else ["edit", "restart"]:
        host = launch(
            [
                "node",
                cli,
                "--profile",
                "bb-settings-test",
                "--patch",
                str(overlay),
                "--host",
                "127.0.0.1",
                "--port",
                str(port),
                "--no-open",
            ],
            "settings-host-" + phase,
            env=env,
        )
        log = private / ("settings-host-" + phase + ".log")
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            assert host.poll() is None, "stock web host failed; private log retained"
            if log.exists() and "dsh web:" in log.read_text():
                break
            time.sleep(0.1)
        else:
            raise AssertionError("web readiness deadline")
        config = private / ("settings-ui-" + phase + ".json")
        config.write_text(
            json.dumps(
                {
                    "origin": origin,
                    "api": api,
                    "account": account,
                    "peer": peer,
                    "switched": switched,
                    "state_root": str(
                        private / "dsh-home/profiles/bb-settings-test/.bb-bridge"
                    ),
                    "bundle": str(bundle),
                    "host_log": str(log),
                    "host_pid": host.pid,
                    "playwright": playwright,
                    "chromium": chromium,
                    "output": str(root / "settings-ui"),
                }
            )
        )
        child = launch(
            ["node", str(here / "settings-ui.mjs"), str(config), phase],
            "settings-ui-" + phase,
            pipe=True,
        )
        stdout, stderr = child.communicate(timeout=150)
        assert child.returncode == 0, stderr[-3500:]
        record("settings-ui-" + phase, **json.loads(stdout))
        stop(host)
