"""Run only on the Windows CI job; never installs packages or registers a service."""

import base64
import json
import os
import subprocess
from pathlib import Path
from uuid import uuid4

import pytest

HELPER = Path(__file__).parents[1] / "src/bb_server/helpers/windows.ps1"


def invoke(tmp_path, value):
    assert os.name == "nt", "This executable test requires Windows PowerShell"
    request = tmp_path / "request.json"
    request.write_text(json.dumps(value), encoding="utf-8")
    return subprocess.run(
        [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(HELPER),
            "-RequestFile",
            str(request),
            "-ValidateOnly",
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=15,
    )


def test_windows_helper_parses_and_validates_without_elevation_or_side_effect(tmp_path):
    value = {"action": "install", "task_id": str(uuid4()), "instance_id": str(uuid4())}
    result = invoke(tmp_path, value)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == value


def test_windows_runtime_token_never_echoed(tmp_path):
    token = base64.b64encode(
        json.dumps(
            {"t": str(uuid4()), "s": base64.b64encode(b"x" * 32).decode()}
        ).encode()
    ).decode()
    value = {
        "action": "connect",
        "task_id": str(uuid4()),
        "instance_id": str(uuid4()),
        "token": token,
    }
    result = invoke(tmp_path, value)
    assert result.returncode == 0, result.stderr
    assert token not in result.stdout + result.stderr
    assert "token" not in json.loads(result.stdout)


@pytest.mark.parametrize(
    "change",
    [
        {"action": "shell"},
        {"command": "whoami"},
        {"task_id": "../../other"},
        {"instance_id": "-Command exit 0"},
        {"action": "connect", "token": "invalid"},
    ],
)
def test_windows_refuses_untrusted_requests(tmp_path, change):
    value = {
        "action": "install",
        "task_id": str(uuid4()),
        "instance_id": str(uuid4()),
        **change,
    }
    result = invoke(tmp_path, value)
    assert result.returncode != 0
    assert not result.stdout.strip()
