import hashlib
import re
import sqlite3
from concurrent.futures import ThreadPoolExecutor

import pytest
from argon2 import PasswordHasher
from fastapi.testclient import TestClient

from bb_server.app import create_app


@pytest.fixture
def api(tmp_path):
    path = tmp_path / "auth.db"
    with TestClient(create_app(path)) as client:
        yield client, path


def register(client, **changes):
    return client.post(
        "/auth/register", json={"username": " Alice ", "password": "Abc123", **changes}
    )


def test_registration_duplicate_names_and_hash(api):
    client, path = api
    first, second = register(client), register(client)
    assert first.status_code == second.status_code == 201
    assert first.json()["username"] == "Alice"
    assert re.fullmatch(r"[1-9][0-9]{7}", first.json()["account"])
    assert first.json()["account"] != second.json()["account"]
    with sqlite3.connect(path) as db:
        rows = db.execute("SELECT account, password FROM users").fetchall()
        assert len(rows) == 2
        for _, password_hash in rows:
            assert password_hash.startswith("$argon2id$")
            assert PasswordHasher().verify(password_hash, "Abc123")
            assert not PasswordHasher().check_needs_rehash(password_hash)


@pytest.mark.parametrize(
    ("password", "code"),
    [
        ("abc123", "missing_uppercase"),
        ("ABC123", "missing_lowercase"),
        ("Abcdef", "missing_digit"),
        ("Ab1", "min_length"),
        ("Äbc123", "missing_uppercase"),
        ("Abc１２３", "missing_digit"),
    ],
)
def test_password_policy_no_insert(api, password, code):
    client, path = api
    result = register(client, password=password)
    assert result.status_code == 422
    error = result.json()["error"]
    assert error["code"] == "validation_error"
    assert code in [f["code"] for f in error["fields"] if f["field"] == "password"]
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT count(*) FROM users").fetchone()[0] == 0


def test_login_token_hash_and_uniform_failures(api):
    client, path = api
    account = register(client).json()["account"]
    response = client.post(
        "/auth/login", json={"account": account, "password": "Abc123"}
    )
    assert response.status_code == 200
    token = response.json()["token"]
    assert len(bytes.fromhex(token)) == 32
    with sqlite3.connect(path) as db:
        row = db.execute(
            "SELECT account, token_hash, created_at FROM sessions"
        ).fetchone()
        assert row[0] == account
        assert row[1] == hashlib.sha256(token.encode()).hexdigest()
        assert row[2]
    missing = "00000000" if account != "00000000" else "99999999"
    bad = client.post("/auth/login", json={"account": account, "password": "x"})
    absent = client.post("/auth/login", json={"account": missing, "password": "x"})
    assert bad.status_code == absent.status_code == 401
    assert (
        bad.json()
        == absent.json()
        == {
            "error": {
                "code": "invalid_credentials",
                "message": "账号或密码错误",
                "fields": [],
            }
        }
    )
    assert (
        client.post(
            "/auth/login", json={"account": "Alice", "password": "Abc123"}
        ).status_code
        == 422
    )


@pytest.mark.parametrize(
    "payload",
    [
        {"username": "Alice", "password": "Abc123", "account": "12345678"},
        {"username": "Alice"},
        {"username": 123, "password": "Abc123"},
        {"username": "  ab  ", "password": "Abc123"},
        {"username": "a" * 25, "password": "Abc123"},
        [],
        None,
    ],
)
def test_reject_bad_shapes_without_echo(api, payload):
    response = api[0].post("/auth/register", json=payload)
    assert response.status_code == 422
    assert "Abc123" not in response.text
    assert response.json()["error"]["fields"]


def test_malformed_json_does_not_echo(api):
    response = api[0].post(
        "/auth/register",
        content='{"password":"secret',
        headers={"content-type": "application/json"},
    )
    assert response.status_code == 422
    assert "secret" not in response.text


def test_account_range_and_collision_retry(api, monkeypatch):
    values = iter([0, 0, 89_999_999])

    def random_value(bound):
        assert bound == 90_000_000
        return next(values)

    monkeypatch.setattr("bb_server.storage.secrets.randbelow", random_value)
    assert register(api[0]).json()["account"] == "10000000"
    assert register(api[0]).json()["account"] == "99999999"


def test_migration_restart_and_constraints(api):
    client, path = api
    account = register(client).json()["account"]
    with TestClient(create_app(path)) as restarted:
        assert (
            restarted.post(
                "/auth/login", json={"account": account, "password": "Abc123"}
            ).status_code
            == 200
        )
    with sqlite3.connect(path) as db:
        db.execute("PRAGMA foreign_keys=ON")
        assert db.execute("PRAGMA user_version").fetchone()[0] == 3
        with pytest.raises(sqlite3.IntegrityError):
            db.execute(
                "INSERT INTO sessions(token_hash,account) VALUES (?,?)",
                ("a" * 64, "not-user"),
            )
        with pytest.raises(sqlite3.IntegrityError):
            db.execute(
                "INSERT INTO users(account,username,password) VALUES ('bad','Alice','hash')"
            )


def test_parallel_same_name_registrations(api):
    with ThreadPoolExecutor(max_workers=3) as pool:
        responses = list(pool.map(lambda _: register(api[0]), range(3)))
    assert all(r.status_code == 201 for r in responses)
    assert len({r.json()["account"] for r in responses}) == 3


def test_locked_db_does_not_confirm_uncommitted_user(api):
    client, path = api
    with sqlite3.connect(path) as lock:
        lock.execute("BEGIN IMMEDIATE")
        result = register(client)
        assert result.status_code == 503
        assert result.json()["error"]["code"] == "storage_busy"
        assert lock.execute("SELECT count(*) FROM users").fetchone()[0] == 0


def test_session_survives_server_restart_and_db_revocation(api):
    client, path = api
    identity = register(client).json()
    token = client.post(
        "/auth/login", json={"account": identity["account"], "password": "Abc123"}
    ).json()["token"]
    headers = {"Authorization": f"Bearer {token}"}
    with TestClient(create_app(path)) as restarted:
        response = restarted.get("/auth/session", headers=headers)
        assert response.status_code == 200
        assert response.json() == identity
        with sqlite3.connect(path) as db:
            db.execute("DELETE FROM sessions")
        assert restarted.get("/auth/session", headers=headers).status_code == 401


@pytest.mark.parametrize(
    "authorization",
    [None, "", "Bearer", "Basic abc", "Bearer invalid", "Bearer " + "a" * 64],
)
def test_invalid_session_is_uniform(api, authorization):
    headers = {} if authorization is None else {"Authorization": authorization}
    response = api[0].get("/auth/session", headers=headers)
    assert response.status_code == 401
    assert response.json() == {
        "error": {"code": "unauthenticated", "message": "请重新登录", "fields": []}
    }


def test_openapi_auth_security(api):
    schema = api[0].get("/openapi.json").json()
    assert schema["paths"]["/auth/session"]["get"]["security"] == [{"HTTPBearer": []}]
    assert "security" not in schema["paths"]["/auth/register"]["post"]


def test_failed_session_write_never_returns_token(api):
    client, path = api
    account = register(client).json()["account"]
    with sqlite3.connect(path) as lock:
        lock.execute("BEGIN IMMEDIATE")
        response = client.post(
            "/auth/login", json={"account": account, "password": "Abc123"}
        )
        assert response.status_code == 503
        assert "token" not in response.json()
        assert lock.execute("SELECT count(*) FROM sessions").fetchone()[0] == 0


def test_password_spaces_are_preserved(api):
    client, _ = api
    account = register(client, password=" Abc1 ").json()["account"]
    assert (
        client.post(
            "/auth/login", json={"account": account, "password": " Abc1 "}
        ).status_code
        == 200
    )
    assert (
        client.post(
            "/auth/login", json={"account": account, "password": "Abc1"}
        ).status_code
        == 401
    )
