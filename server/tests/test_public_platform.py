import base64
import json
import os
import subprocess
from pathlib import Path
from types import SimpleNamespace
from uuid import uuid4

import pytest

from bb_server import public_platform
from bb_server.helpers import arch
from bb_server.public_cloud import PublicFailure
from bb_server.public_platform import PlatformAdapter, SecretFiles


def payload(action="connect"):
    token = base64.b64encode(
        json.dumps(
            {"t": str(uuid4()), "s": base64.b64encode(b"x" * 32).decode()}
        ).encode()
    ).decode()
    value = {"action": action, "task_id": str(uuid4()), "instance_id": str(uuid4())}
    if action == "connect":
        value["token"] = token
    return value


@pytest.mark.parametrize(
    "change",
    [
        {"action": "shell"},
        {"command": "touch /other"},
        {"task_id": "../../etc/passwd"},
        {"instance_id": "--help"},
        {"token": "invalid"},
    ],
)
def test_arch_helper_rejects_arbitrary_operations_and_paths(change):
    with pytest.raises((ValueError, KeyError, TypeError)):
        arch.request({**payload(), **change})


def test_fixed_unit_has_no_token_or_user_command_in_argv():
    value = payload()
    assert arch.request(value) == value
    unit = arch.unit(value["instance_id"]).decode()
    assert value["token"] not in unit
    assert "--token-file ${CREDENTIALS_DIRECTORY}/token" in unit
    assert "DynamicUser=yes" in unit and "NoNewPrivileges=yes" in unit
    assert "LoadCredential=token:/var/lib/bb-public/" in unit


def test_helper_exclusive_files_refuse_symlinks_and_content_changes(
    tmp_path, monkeypatch
):
    target = tmp_path / "target"
    arch.write_once(target, b"first")
    # This unprivileged test cannot create root-owned files. First assert the real
    # ownership rejection, then simulate ONLY root ownership for the reuse branch.
    with pytest.raises(ValueError):
        arch.write_once(target, b"first")
    original = Path.stat

    def root_owned(path, *args, **kwargs):
        result = original(path, *args, **kwargs)
        if path == target:
            values = list(result)
            values[4] = 0
            return os.stat_result(values)
        return result

    monkeypatch.setattr(Path, "stat", root_owned)
    arch.write_once(target, b"first")
    with pytest.raises(ValueError):
        arch.write_once(target, b"other")
    link = tmp_path / "link"
    link.symlink_to(target)
    with pytest.raises(ValueError):
        arch.write_once(link, b"first")
    assert target.read_bytes() == b"first"


def test_secret_files_are_private_and_task_names_cannot_escape(tmp_path):
    files = SecretFiles(tmp_path / "private")
    task = uuid4()
    secret = files.secret(task, create=True)
    assert files.secret(task) == secret
    assert len(base64.b64decode(secret)) == 32
    assert files.path(task, "secret").stat().st_mode & 0o777 == 0o600
    assert files.directory.stat().st_mode & 0o777 == 0o700
    with pytest.raises(ValueError):
        files.path("../../outside", "secret")
    value = payload()
    path = files.request(value)
    assert value["token"] in path.read_text()
    with pytest.raises(PublicFailure):
        files.request({**value, "token": "changed"})


def test_missing_binary_and_unreadable_service_are_different(tmp_path, monkeypatch):
    binary = tmp_path / "cloudflared"
    commands = []

    def runner(args, **kwargs):
        commands.append(args)
        if "--version" in args:
            return SimpleNamespace(returncode=0, stdout="synthetic")
        return SimpleNamespace(returncode=1, stdout="")

    adapter = PlatformAdapter(tmp_path / "private", kind="arch", runner=runner)
    monkeypatch.setattr(adapter, "binary", lambda: binary)
    missing = adapter.inspect(uuid4())
    assert missing[0].issue_code == "cloudflared_missing"
    assert commands == []
    binary.touch()
    unreadable = adapter.inspect(uuid4())
    assert unreadable[0].classification == "passed"
    assert unreadable[1].classification == "unknown"
    assert unreadable[1].issue_code == "service_unreadable"
    assert all("cert.pem" not in str(command) for command in commands)


def test_unsupported_platform_never_invokes_helper(tmp_path):
    def forbidden(*args, **kwargs):
        raise AssertionError("must not execute")

    adapter = PlatformAdapter(tmp_path, kind="unsupported", runner=forbidden)
    assert adapter.inspect(uuid4())[0].classification == "not_applicable"
    with pytest.raises(PublicFailure) as error:
        adapter.apply("install", uuid4(), uuid4())
    assert error.value.code == "platform_unsupported"


def test_untrusted_helper_does_not_elevate_and_keeps_private_request(tmp_path):
    calls = []
    adapter = PlatformAdapter(
        tmp_path / "private", kind="arch", runner=lambda *a, **kw: calls.append(a)
    )
    value = payload()
    with pytest.raises(PublicFailure) as error:
        adapter.apply("connect", value["task_id"], value["instance_id"], value["token"])
    assert error.value.code in (
        "local_helper_required",
        "local_helper_untrusted",
        "local_desktop_required",
    )
    assert calls == []
    assert (
        adapter.files.path(value["task_id"], "request").stat().st_mode & 0o777 == 0o600
    )


def test_helper_subprocess_arguments_never_include_runtime_token(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(
        arch.subprocess,
        "run",
        lambda args, **kwargs: (
            calls.append((args, kwargs)) or SimpleNamespace(returncode=0)
        ),
    )
    arch.run(
        [
            "/usr/bin/systemctl",
            "is-active",
            "--quiet",
            "bb-cloudflared-" + str(uuid4()) + ".service",
        ]
    )
    assert calls[0][1]["stdout"] == subprocess.DEVNULL
    assert calls[0][1]["stderr"] == subprocess.DEVNULL
    assert calls[0][1]["env"] == {"PATH": "/usr/bin:/bin", "LANG": "C"}


def test_arch_rejects_unprivileged_direct_invocation_without_side_effects(
    monkeypatch, tmp_path
):
    monkeypatch.setattr(arch.os, "geteuid", lambda: 1000)
    monkeypatch.setattr(arch, "ROOT", tmp_path / "never-created")
    with pytest.raises(ValueError):
        arch.apply(payload("install"))
    assert not (tmp_path / "never-created").exists()


def test_arch_private_directory_rejects_world_writable_existing_path(tmp_path):
    tmp_path.chmod(0o777)
    with pytest.raises(ValueError):
        arch.private_directory(tmp_path)


@pytest.mark.parametrize(
    "value", [None, [], "install", {"action": "install", "task_id": 1}]
)
def test_arch_rejects_non_object_or_non_string_identifiers(value):
    with pytest.raises((ValueError, TypeError)):
        arch.request(value)


def test_windows_private_acl_accepts_entra_sid_without_echoing_identity(
    tmp_path, monkeypatch
):
    files = SecretFiles(tmp_path / "private")
    calls = []

    def runner(args, **kwargs):
        calls.append(args)
        return SimpleNamespace(stdout='"synthetic,user","S-1-12-1-1-2-3-4"\n')

    monkeypatch.setattr(public_platform, "os", SimpleNamespace(name="nt"))
    monkeypatch.setattr(public_platform.subprocess, "run", runner)
    files.prepare()
    assert len(calls) == 3
    assert "*S-1-12-1-1-2-3-4:(OI)(CI)F" in calls[1]
    assert "Get-Acl" in calls[2][-1]


@pytest.mark.parametrize("failed_call", [1, 2, 3])
def test_windows_acl_failure_is_sanitized_and_writes_no_secret(
    tmp_path, monkeypatch, failed_call
):
    files = SecretFiles(tmp_path / "private")
    calls = []

    def runner(args, **kwargs):
        calls.append(args)
        if len(calls) == failed_call:
            raise subprocess.CalledProcessError(1, args, stderr="private identity")
        return SimpleNamespace(stdout='"synthetic","S-1-5-21-1-2-3-4"\n')

    monkeypatch.setattr(public_platform, "os", SimpleNamespace(name="nt"))
    monkeypatch.setattr(public_platform.subprocess, "run", runner)
    with pytest.raises(PublicFailure) as error:
        files.prepare()
    assert error.value.code == "private_acl_unavailable"
    assert "private identity" not in str(error.value)
    assert list(files.directory.iterdir()) == []
