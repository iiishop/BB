"""Real CLI listeners, temporary data, no cloud/system changes or test doubles."""

import json
import os
import socket
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path

import httpx
from bb_auth_contract.admin import COOKIE, PREFIX


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@contextmanager
def running(entrypoint, env, url, log_path):
    executable = Path(sys.executable).with_name(
        entrypoint + (".exe" if os.name == "nt" else "")
    )
    with log_path.open("wb") as log:
        process = subprocess.Popen([str(executable)], env=env, stdout=log, stderr=log)
        try:
            with httpx.Client(base_url=url, trust_env=False, timeout=2) as api:
                deadline = time.monotonic() + 20
                while True:
                    assert process.poll() is None, log_path.read_text()
                    try:
                        api.get("/")
                        break
                    except httpx.ConnectError:
                        assert time.monotonic() < deadline, log_path.read_text()
                        time.sleep(0.05)
                yield api
        finally:
            # Platform guard applies only when running within Multica, never in CI.
            if process.poll() is None:
                if cli := os.environ.get("MULTICA_CLI_PATH"):
                    daemon = json.loads(
                        subprocess.check_output(
                            [cli, "daemon", "status", "--output", "json"]
                        )
                    )
                    assert process.pid != daemon["pid"]
                process.terminate()
            process.wait(timeout=10)


def test_real_cli_initialization_restart_and_tunnel_target(tmp_path):
    business_port, admin_port = free_port(), free_port()
    while business_port == admin_port:
        admin_port = free_port()
    env = {
        **os.environ,
        "BB_DATABASE_PATH": str(tmp_path / "business.db"),
        "BB_AVATAR_DIRECTORY": str(tmp_path / "avatars"),
        "BB_MEDIA_DIRECTORY": str(tmp_path / "media"),
        "BB_HOST": "127.0.0.1",
        "BB_PORT": str(business_port),
        "BB_ADMIN_DATABASE_PATH": str(tmp_path / "admin.db"),
        "BB_ADMIN_PORT": str(admin_port),
    }
    admin_url, business_url = (
        f"http://127.0.0.1:{admin_port}",
        f"http://127.0.0.1:{business_port}",
    )
    headers = {"origin": admin_url, "x-bb-admin": "1"}
    new_password = "Synthetic-Admin-Pass-123!"
    with running("bb-server", env, business_url, tmp_path / "business.log") as business:
        with running("bb-admin", env, admin_url, tmp_path / "admin.log") as admin:
            assert admin.get(PREFIX + "/session").status_code == 401
            # Simulate Tunnel requests on the ONLY eligible public target: business port.
            for path in (
                "/admin",
                PREFIX + "/session",
                PREFIX + "/login",
                PREFIX + "/public-config",
            ):
                assert (
                    business.get(
                        path, headers={"x-forwarded-for": "203.0.113.10"}
                    ).status_code
                    == 404
                )
            assert (
                business.post(
                    PREFIX + "/login", json={"username": "admin", "password": "admin"}
                ).status_code
                == 404
            )
            denied = admin.post(
                PREFIX + "/login",
                json={"username": "admin", "password": "admin"},
                headers={**headers, "x-forwarded-for": "203.0.113.10"},
            )
            assert denied.status_code == 403
            login = admin.post(
                PREFIX + "/login",
                json={"username": "admin", "password": "admin"},
                headers=headers,
            )
            assert login.status_code == 200
            assert login.json()["must_change_password"] is True
            old_cookie = admin.cookies.get(COOKIE)
            headers["x-csrf-token"] = login.json()["csrf_token"]
            assert admin.get(PREFIX + "/public-config").status_code == 403
            changed = admin.post(
                PREFIX + "/password",
                json={"old_password": "admin", "new_password": new_password},
                headers=headers,
            )
            assert changed.status_code == 204
            assert (
                admin.get(
                    PREFIX + "/session", headers={"cookie": f"{COOKIE}={old_cookie}"}
                ).status_code
                == 401
            )
        with running("bb-admin", env, admin_url, tmp_path / "restart.log") as restarted:
            assert (
                restarted.post(
                    PREFIX + "/login",
                    json={"username": "admin", "password": "admin"},
                    headers=headers,
                ).status_code
                == 401
            )
            login = restarted.post(
                PREFIX + "/login",
                json={"username": "admin", "password": new_password},
                headers=headers,
            )
            assert login.status_code == 200
            assert login.json()["must_change_password"] is False
            assert restarted.get(PREFIX + "/public-config").status_code == 200
            headers["x-csrf-token"] = login.json()["csrf_token"]
            token = restarted.cookies.get(COOKIE)
            assert (
                restarted.post(PREFIX + "/logout", json={}, headers=headers).status_code
                == 204
            )
            assert (
                restarted.get(
                    PREFIX + "/session", headers={"cookie": f"{COOKIE}={token}"}
                ).status_code
                == 401
            )
        # Existing public business flow remains real and independent.
        registered = business.post(
            "/auth/register", json={"username": "Synthetic User", "password": "Abc123"}
        )
        assert registered.status_code == 201
        logged_in = business.post(
            "/auth/login",
            json={"account": registered.json()["account"], "password": "Abc123"},
        )
        assert logged_in.status_code == 200
        assert (
            business.get(
                "/auth/session",
                headers={"authorization": f"Bearer {logged_in.json()['token']}"},
            ).status_code
            == 200
        )
    for path in tmp_path.iterdir():
        if path.is_file():
            assert new_password.encode() not in path.read_bytes()
