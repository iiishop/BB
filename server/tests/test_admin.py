import hashlib
import json
import os
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier, Event
from types import SimpleNamespace

import pytest
from argon2 import PasswordHasher
from bb_auth_contract import ContractError
from bb_auth_contract.admin import COOKIE, PREFIX, SESSION_SECONDS, DraftSave
from fastapi.testclient import TestClient
from pydantic import ValidationError

from bb_server.admin import create_admin_app
from bb_server.admin_storage import ATTEMPT_WINDOW, AdminStore
from bb_server.app import create_app
from bb_server.storage import connection

ORIGIN = "http://127.0.0.1:9001"
HEADERS = {"origin": ORIGIN, "x-bb-admin": "1"}
PASSWORD = "Synthetic-Password-123!"


def client_for(path, clock, **kwargs):
    return TestClient(
        create_admin_app(path, port=9001, clock=clock),
        base_url=ORIGIN,
        client=("127.0.0.1", 12000),
        **kwargs,
    )


@pytest.fixture
def api(tmp_path):
    path = tmp_path / "admin.db"
    now = [100000.0]
    with client_for(path, lambda: now[0]) as client:
        yield client, path, now


def login(client, password="admin"):
    result = client.post(
        PREFIX + "/login",
        json={"username": "admin", "password": password},
        headers=HEADERS,
    )
    assert result.status_code == 200, result.text
    return {**HEADERS, "x-csrf-token": result.json()["csrf_token"]}


def change(client, headers, old="admin", new=PASSWORD):
    return client.post(
        PREFIX + "/password",
        json={"old_password": old, "new_password": new},
        headers=headers,
    )


def test_initialize_hash_cookie_revoke_all_and_restart(api):
    client, path, now = api
    headers = login(client)
    first_token = client.cookies.get(COOKIE)
    result = client.get(PREFIX + "/session")
    assert result.json()["must_change_password"] is True
    with client_for(path, lambda: now[0]) as other:
        second_headers = login(other)
        second_token = other.cookies.get(COOKIE)
        assert change(client, headers).status_code == 204
        assert other.get(PREFIX + "/session").status_code == 401
        assert change(other, second_headers).status_code == 401
    assert (
        client.get(
            PREFIX + "/session", headers={"cookie": f"{COOKIE}={first_token}"}
        ).status_code
        == 401
    )
    with client_for(path, lambda: now[0]) as restarted:
        bad = restarted.post(
            PREFIX + "/login",
            json={"username": "admin", "password": "admin"},
            headers=HEADERS,
        )
        assert bad.status_code == 401
        logged_in = restarted.post(
            PREFIX + "/login",
            json={"username": "admin", "password": PASSWORD},
            headers=HEADERS,
        )
        assert logged_in.status_code == 200
        assert logged_in.json()["must_change_password"] is False
        cookie = logged_in.headers["set-cookie"]
        assert all(
            part in cookie
            for part in ("HttpOnly", "SameSite=strict", "Path=/admin", "Max-Age=28800")
        )
        assert "Domain=" not in cookie
        assert "token" not in logged_in.json()
        assert logged_in.headers["cache-control"] == "no-store"
    with connection(path) as db:
        row = db.execute("SELECT * FROM administrator").fetchone()
        assert row["password_hash"].startswith("$argon2id$")
        assert PasswordHasher().verify(row["password_hash"], PASSWORD)
        assert row["epoch"] == 2
        assert (
            db.execute(
                "SELECT count(*) FROM admin_sessions WHERE token_hash IN (?, ?)",
                (
                    hashlib.sha256(first_token.encode()).hexdigest(),
                    hashlib.sha256(second_token.encode()).hexdigest(),
                ),
            ).fetchone()[0]
            == 0
        )
    for value in (PASSWORD, first_token, second_token):
        assert value.encode() not in path.read_bytes()
    if os.name == "posix":
        assert path.stat().st_mode & 0o777 == 0o600


def test_each_management_route_rejects_bb_identity_and_initial_session(api, tmp_path):
    client, _, _ = api
    with TestClient(create_app(tmp_path / "business.db")) as business:
        user = business.post(
            "/auth/register", json={"username": "admin", "password": "Abc123"}
        ).json()
        token = business.post(
            "/auth/login", json={"account": user["account"], "password": "Abc123"}
        ).json()["token"]
    paths = create_admin_app("unused", port=9001).openapi()["paths"]
    for path, methods in paths.items():
        if path.endswith("/login"):
            continue
        path = path.replace("{task_id}", "00000000-0000-4000-8000-000000000000")
        for method in methods:
            for auth in (
                {},
                {"authorization": "Bearer " + token},
                {"cookie": f"{COOKIE}={token}"},
            ):
                assert (
                    client.request(
                        method, path, json={}, headers={**HEADERS, **auth}
                    ).status_code
                    == 401
                )
    assert (
        client.post(
            PREFIX + "/login",
            json={"username": user["account"], "password": "Abc123"},
            headers=HEADERS,
        ).status_code
        == 401
    )
    headers = login(client)
    for path, methods in paths.items():
        if not any(
            operation["x-implementation-stage"] == "B" for operation in methods.values()
        ):
            continue
        for method in methods:
            response = client.request(method, path, json={}, headers=headers)
            assert response.status_code == 403
            assert response.json()["error"]["code"] == "password_change_required"


@pytest.mark.parametrize(
    "extra",
    [
        {"host": "attacker.test:9001"},
        {"host": "127.0.0.1:8000"},
        {"origin": "https://attacker.test"},
        {"origin": "null"},
        {"origin": "http://127.0.0.1:9002"},
        {"sec-fetch-site": "cross-site"},
        {"sec-fetch-site": "same-site"},
        {"forwarded": "for=127.0.0.1"},
        {"x-forwarded-for": "127.0.0.1"},
        {"x-forwarded-host": "127.0.0.1:9001"},
        {"cf-connecting-ip": "127.0.0.1"},
    ],
)
def test_reject_remote_proxy_and_rebinding_headers(api, extra):
    client, path, _ = api
    result = client.post(
        PREFIX + "/login",
        json={"username": "admin", "password": "admin"},
        headers={**HEADERS, **extra},
    )
    assert result.status_code == 403
    assert "set-cookie" not in result.headers
    assert "access-control-allow-origin" not in result.headers
    with connection(path) as db:
        assert db.execute("SELECT attempts FROM admin_attempts").fetchone()[0] == 0


def test_remote_socket_cannot_use_default_even_with_local_host(api):
    _, path, now = api
    with TestClient(
        create_admin_app(path, port=9001, clock=lambda: now[0]),
        base_url=ORIGIN,
        client=("203.0.113.5", 1234),
    ) as remote:
        assert (
            remote.post(
                PREFIX + "/login",
                json={"username": "admin", "password": "admin"},
                headers=HEADERS,
            ).status_code
            == 403
        )


def test_csrf_origin_json_and_validation_are_checked_without_echo(api):
    client, _, _ = api
    payload = {"username": "admin", "password": "admin"}
    assert client.post(PREFIX + "/login", json=payload).status_code == 403
    assert (
        client.post(
            PREFIX + "/login", json=payload, headers={"origin": ORIGIN}
        ).status_code
        == 403
    )
    assert (
        client.post(PREFIX + "/login", data=payload, headers=HEADERS).status_code == 415
    )
    assert (
        client.options(
            PREFIX + "/login",
            headers={
                "origin": "https://attacker.test",
                "access-control-request-method": "POST",
            },
        ).status_code
        == 403
    )
    malformed = client.post(
        PREFIX + "/login",
        content='{"password":"SENSITIVE',
        headers={**HEADERS, "content-type": "application/json"},
    )
    assert malformed.status_code == 422
    assert "SENSITIVE" not in malformed.text
    too_large = client.post(
        PREFIX + "/login",
        content=b"x" * 16385,
        headers={**HEADERS, "content-type": "application/json"},
    )
    assert too_large.status_code == 413
    headers = login(client)
    assert change(client, HEADERS).status_code == 403
    assert change(client, {**headers, "x-csrf-token": "bad"}).status_code == 403
    assert change(client, headers, old="incorrect").status_code == 403
    short = change(client, headers, new="SENSITIVE")
    assert short.status_code == 422
    assert "SENSITIVE" not in short.text
    assert change(client, headers).status_code == 204
    headers = login(client, PASSWORD)
    assert change(client, headers, old=PASSWORD, new=PASSWORD).status_code == 422


def test_attempt_budget_is_persistent_and_shared_by_login_and_password(api):
    client, path, now = api
    headers = login(client)
    for _ in range(4):
        assert change(client, headers, old="incorrect").status_code == 403
    limited = client.post(
        PREFIX + "/login",
        json={"username": "admin", "password": "admin"},
        headers=HEADERS,
    )
    assert limited.status_code == 429
    assert limited.headers["retry-after"] == "60"
    with client_for(path, lambda: now[0]) as restarted:
        assert (
            restarted.post(
                PREFIX + "/login",
                json={"username": "admin", "password": "admin"},
                headers=HEADERS,
            ).status_code
            == 429
        )
    now[0] += ATTEMPT_WINDOW
    login(client)


def test_parallel_wrong_password_attempts_are_bounded(api):
    _, path, now = api
    store = AdminStore(path, lambda: now[0])

    def attempt(_):
        try:
            store.login("admin", "incorrect")
        except ContractError as error:
            return error.status

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(attempt, range(8)))
    assert sorted(results) == [401] * 5 + [429] * 3


def test_expiry_logout_and_missing_cookie(api):
    client, _, now = api
    headers = login(client)
    token = client.cookies.get(COOKIE)
    assert client.post(PREFIX + "/logout", json={}, headers=headers).status_code == 204
    assert (
        client.get(
            PREFIX + "/session", headers={"cookie": f"{COOKIE}={token}"}
        ).status_code
        == 401
    )
    login(client)
    now[0] += SESSION_SECONDS
    assert client.get(PREFIX + "/session").status_code == 401


def test_login_cannot_commit_stale_password_after_rotation(api, monkeypatch):
    client, path, now = api
    headers = login(client)
    store = AdminStore(path, lambda: now[0])
    verified, release = Event(), Event()
    original_verify = store.hasher.verify

    def paused_verify(*args):
        value = original_verify(*args)
        verified.set()
        assert release.wait(10)
        return value

    monkeypatch.setattr(store, "hasher", SimpleNamespace(verify=paused_verify))
    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(store.login, "admin", "admin")
        try:
            assert verified.wait(10)
            assert change(client, headers).status_code == 204
        finally:
            release.set()
        with pytest.raises(ContractError) as error:
            future.result()
        assert error.value.status == 401
    with connection(path) as db:
        assert db.execute("SELECT count(*) FROM admin_sessions").fetchone()[0] == 0


def test_two_password_changes_have_exactly_one_commit(api, monkeypatch):
    client, path, now = api
    headers = login(client)
    token = client.cookies.get(COOKIE)
    barrier = Barrier(2)
    stores = [AdminStore(path, lambda: now[0]) for _ in range(2)]
    for store in stores:
        original = store.hasher.hash

        def paused_hash(value, original=original):
            result = original(value)
            barrier.wait(timeout=10)
            return result

        monkeypatch.setattr(
            store,
            "hasher",
            SimpleNamespace(hash=paused_hash, verify=store.hasher.verify),
        )

    def rotate(index):
        try:
            stores[index].change_password(
                token, headers["x-csrf-token"], "admin", PASSWORD + str(index)
            )
            return 204
        except ContractError as error:
            return error.status

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(rotate, range(2)))
    assert sorted(results) == [204, 401]
    with connection(path) as db:
        assert db.execute("SELECT epoch FROM administrator").fetchone()[0] == 2
        assert db.execute("SELECT count(*) FROM admin_sessions").fetchone()[0] == 0


def test_failed_rotation_rolls_back_hash_and_revocation_then_recovers(api):
    client, path, now = api
    headers = login(client)
    with connection(path, write=True) as db:
        old = dict(db.execute("SELECT * FROM administrator").fetchone())
        db.execute(
            "CREATE TRIGGER fail_revoke BEFORE DELETE ON admin_sessions BEGIN SELECT RAISE(ABORT, 'synthetic'); END"
        )
    assert change(client, headers).status_code == 503
    with connection(path, write=True) as db:
        assert dict(db.execute("SELECT * FROM administrator").fetchone()) == old
        assert db.execute("SELECT count(*) FROM admin_sessions").fetchone()[0] == 1
        db.execute("DROP TRIGGER fail_revoke")
    assert client.get(PREFIX + "/session").status_code == 200
    assert change(client, headers).status_code == 204
    with client_for(path, lambda: now[0]) as restarted:
        login(restarted, PASSWORD)


def test_failed_session_insert_never_returns_cookie(api):
    client, path, _ = api
    with connection(path, write=True) as db:
        db.execute(
            "CREATE TRIGGER fail_login BEFORE INSERT ON admin_sessions BEGIN SELECT RAISE(ABORT, 'synthetic'); END"
        )
    response = client.post(
        PREFIX + "/login",
        json={"username": "admin", "password": "admin"},
        headers=HEADERS,
    )
    assert response.status_code == 503
    assert "set-cookie" not in response.headers
    assert "csrf_token" not in response.text


def test_busy_store_returns_sanitized_retryable_error(api):
    client, path, _ = api
    with sqlite3.connect(path) as lock:
        lock.execute("BEGIN IMMEDIATE")
        result = client.post(
            PREFIX + "/login",
            json={"username": "admin", "password": "admin"},
            headers=HEADERS,
        )
        assert result.status_code == 503
        assert result.json()["error"]["code"] == "storage_busy"
        assert result.headers["retry-after"] == "1"
        assert "set-cookie" not in result.headers


def test_management_migration_rejects_business_and_newer_database(tmp_path):
    business = tmp_path / "business.db"
    with TestClient(create_app(business)):
        pass
    business.chmod(0o600)
    before = business.read_bytes()
    with pytest.raises(RuntimeError, match="supported management"):
        AdminStore(business, lambda: 0).migrate()
    assert business.read_bytes() == before
    admin = tmp_path / "admin.db"
    store = AdminStore(admin, lambda: 0)
    store.migrate()
    with connection(admin, write=True) as db:
        db.execute("PRAGMA user_version=2")
    with pytest.raises(RuntimeError, match="supported management"):
        store.migrate()


def test_management_migration_is_atomic(tmp_path, monkeypatch):
    path = tmp_path / "admin.db"
    with monkeypatch.context() as patch:
        patch.setattr(
            Path,
            "read_text",
            lambda *args, **kwargs: "CREATE TABLE partial(id INTEGER); INVALID SQL;",
        )
        with pytest.raises(sqlite3.OperationalError):
            AdminStore(path, lambda: 0).migrate()
    with connection(path) as db:
        assert db.execute("SELECT name FROM sqlite_schema").fetchall() == []
        assert db.execute("PRAGMA user_version").fetchone()[0] == 0
    AdminStore(path, lambda: 0).migrate()
    assert AdminStore(path, lambda: 0).login("admin", "admin")[1].must_change_password


def test_contract_snapshot_is_complete_idempotent_and_has_no_side_effects(tmp_path):
    path = tmp_path / "must-not-exist.db"
    app = create_admin_app(path, port=9001)
    schema = app.openapi()
    serialized = json.dumps(schema)
    assert json.dumps(app.openapi()) == serialized
    expected = json.loads(
        (Path(__file__).parents[1] / "contract/admin-openapi.json").read_text()
    )
    assert schema == expected
    assert not path.exists()
    assert schema["components"]["schemas"]["AdminLogin"]["properties"]["password"][
        "writeOnly"
    ]
    assert schema["components"]["schemas"]["PlanExecute"]["properties"][
        "management_token"
    ]["anyOf"][0]["writeOnly"]
    assert not any(
        path.startswith("/admin")
        for path in create_app(tmp_path / "business.db").openapi()["paths"]
    )


@pytest.mark.parametrize(
    "domain",
    [
        "localhost",
        "127.0.0.1",
        "https://bb.example.com",
        "bb.example.com:80",
        "bb.example.com/",
        "*.example.com",
        "bb.example.com.",
        "bb..com",
        "bb.exa_mple.com",
        "bb.-example.com",
        "bb.example.c0m",
    ],
)
def test_domain_contract_rejects_non_hostname_targets(domain):
    with pytest.raises(ValidationError):
        DraftSave(expected_version=0, domain=domain)


def test_domain_contract_normalizes_case_and_preserves_version():
    assert DraftSave(expected_version=3, domain="BB.Example.COM").model_dump() == {
        "expected_version": 3,
        "domain": "bb.example.com",
    }
