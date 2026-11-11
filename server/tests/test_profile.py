import hashlib
import io
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from bb_auth_contract.profile import MAX_AVATAR_BYTES
from bb_server.app import create_app
from bb_server.avatars import identicon
from fastapi.testclient import TestClient
from PIL import Image


def login(api, name="Alice"):
    account = api.post(
        "/auth/register", json={"username": name, "password": "Abc123"}
    ).json()["account"]
    token = api.post(
        "/auth/login", json={"account": account, "password": "Abc123"}
    ).json()["token"]
    return account, {"Authorization": f"Bearer {token}"}


@pytest.fixture
def profile_api(tmp_path):
    path = tmp_path / "auth.db"
    with TestClient(create_app(path)) as api:
        account, headers = login(api)
        yield api, path, account, headers


def test_default_profile_is_authenticated_deterministic_and_fileless(profile_api):
    api, path, account, headers = profile_api
    url = f"/users/{account}/profile"
    assert api.get(url).status_code == 401
    profile = api.get(url, headers=headers)
    assert profile.status_code == 200
    body = profile.json()
    assert body["username"] == "Alice" and body["signature"] is None
    avatar = api.get(body["avatar_url"], headers=headers)
    assert avatar.status_code == 200
    assert avatar.content.startswith(b"\x89PNG\r\n\x1a\n")
    assert avatar.content == api.get(body["avatar_url"], headers=headers).content
    assert (
        api.get(
            body["avatar_url"],
            headers={**headers, "If-None-Match": avatar.headers["etag"]},
        ).status_code
        == 304
    )
    with sqlite3.connect(path) as db:
        assert (
            db.execute(
                "SELECT avatar_path FROM users WHERE account=?", (account,)
            ).fetchone()[0]
            is None
        )
    assert not list(path.parent.rglob("*.png"))


def test_profile_mutations_do_not_accept_another_account(profile_api):
    api, _, account, headers = profile_api
    other, _ = login(api, "Other")
    assert (
        api.patch(
            "/me/profile",
            headers=headers,
            json={"account": other, "username": "Stolen"},
        ).status_code
        == 422
    )
    assert (
        api.patch(
            "/me/profile",
            headers=headers,
            json={"username": "  New name  ", "signature": " 你好🌏 "},
        ).json()["signature"]
        == "你好🌏"
    )
    assert (
        api.get(f"/users/{other}/profile", headers=headers).json()["username"]
        == "Other"
    )
    assert (
        api.get(f"/users/{account}/profile", headers=headers).json()["username"]
        == "New name"
    )


def image_bytes(format="PNG", color="red"):
    output = io.BytesIO()
    Image.new("RGB", (12, 8), color).save(output, format=format)
    return output.getvalue()


def upload(api, headers, data, filename="../../untrusted.exe", mime="text/plain"):
    return api.post(
        "/me/avatar", headers=headers, files={"file": (filename, data, mime)}
    )


def test_identicon_twenty_accounts_and_bit_layout():
    images = [identicon(str(10000000 + i)) for i in range(20)]
    assert len(set(images)) == 20
    for i, data in enumerate(images):
        account = str(10000000 + i)
        assert data == identicon(account)
        image = Image.open(io.BytesIO(data))
        assert image.size == (250, 250) and image.mode == "RGBA"
        digest = hashlib.sha256(account.encode()).digest()
        colors = set()
        for row in range(5):
            for col in range(5):
                bit = row * 3 + min(col, 4 - col)
                pixel = image.getpixel((col * 50 + 25, row * 50 + 25))
                assert bool(pixel[3]) == bool(digest[bit // 8] & (1 << (7 - bit % 8)))
                assert pixel == image.getpixel(((4 - col) * 50 + 25, row * 50 + 25))
                if pixel[3]:
                    colors.add(pixel)
        assert len(colors) == 1


@pytest.mark.parametrize("format", ["PNG", "JPEG", "WEBP"])
def test_magic_bytes_upload_normalization_and_delete_fallback(profile_api, format):
    api, path, account, headers = profile_api
    url = f"/avatars/{account}.png"
    original = api.get(url, headers=headers)
    response = upload(api, headers, image_bytes(format))
    assert response.status_code == 200
    assert response.json()["avatar_version"] != original.headers["etag"].strip('"')
    fetched = api.get(
        url, headers={**headers, "If-None-Match": original.headers["etag"]}
    )
    assert fetched.status_code == 200 and fetched.content != original.content
    assert Image.open(io.BytesIO(fetched.content)).format == "PNG"
    assert fetched.headers["etag"] == '"' + response.json()["avatar_version"] + '"'
    assert fetched.headers["cache-control"] == "private, no-cache"
    assert (
        api.get(
            url,
            headers={
                **headers,
                "If-None-Match": '"other", W/' + fetched.headers["etag"],
            },
        ).status_code
        == 304
    )
    # Same content retains its version, even when the storage key changes.
    assert (
        upload(api, headers, image_bytes(format)).json()["avatar_version"]
        == response.json()["avatar_version"]
    )
    assert len(list(path.parent.rglob("*.png"))) == 1
    assert api.delete("/me/avatar", headers=headers).status_code == 200
    assert api.get(url, headers=headers).content == original.content
    assert not list(path.parent.rglob("*.png"))
    assert api.delete("/me/avatar", headers=headers).status_code == 200


@pytest.mark.parametrize(
    "payload",
    [
        {"username": ""},
        {"username": "ab"},
        {"username": "x" * 25},
        {"username": None},
        {"signature": "中" * 50},
        {"signature": "x" * 51},
        {"signature": 1},
        {"nickname": "Other"},
        {"username": "Valid", "signature": "x" * 50},
    ],
)
def test_invalid_profile_patch_is_atomic(profile_api, payload):
    api, _, account, headers = profile_api
    before = api.get(f"/users/{account}/profile", headers=headers).json()
    response = api.patch("/me/profile", json=payload, headers=headers)
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"
    assert api.get(f"/users/{account}/profile", headers=headers).json() == before


def test_unicode_boundaries_omitted_fields_and_clear(profile_api):
    api, _, _, headers = profile_api
    value = "🌏" * 49
    assert (
        api.patch(
            "/me/profile",
            json={"signature": " " + value + " ", "username": "🌏" * 24},
            headers=headers,
        ).json()["signature"]
        == value
    )
    assert (
        api.patch("/me/profile", json={}, headers=headers).json()["signature"] == value
    )
    for clear in (None, "", " \t\n "):
        assert (
            api.patch("/me/profile", json={"signature": clear}, headers=headers).json()[
                "signature"
            ]
            is None
        )


def test_upload_size_type_and_decode_failures_leave_old_image(profile_api):
    api, _, account, headers = profile_api
    assert upload(api, headers, image_bytes()).status_code == 200
    before = api.get(f"/avatars/{account}.png", headers=headers)
    for data, status in [
        (b"not-an-image", 415),
        (image_bytes("GIF"), 415),
        (b"\x89PNG\r\n\x1a\ntruncated", 415),
        (image_bytes()[:40], 415),
        (b"x" * (MAX_AVATAR_BYTES + 1), 413),
        (b"x" * (MAX_AVATAR_BYTES + 65537), 413),
    ]:
        response = upload(api, headers, data, filename="avatar.png", mime="image/png")
        assert response.status_code == status
        assert "error" in response.json()
        assert (
            api.get(f"/avatars/{account}.png", headers=headers).content
            == before.content
        )
    # The exact raw-byte limit is inclusive (PNG ignores legal trailing data).
    png = image_bytes()
    assert (
        upload(api, headers, png + b"\0" * (MAX_AVATAR_BYTES - len(png))).status_code
        == 200
    )


def test_all_routes_reject_unauthenticated_and_overrides(profile_api):
    api, _, account, headers = profile_api
    for method, url, kwargs in [
        ("get", f"/users/{account}/profile", {}),
        ("get", f"/avatars/{account}.png", {}),
        ("patch", "/me/profile", {"json": {"username": "Other"}}),
        ("post", "/me/avatar", {"files": {"file": ("x.png", image_bytes())}}),
        ("delete", "/me/avatar", {}),
    ]:
        assert getattr(api, method)(url, **kwargs).status_code == 401
    for method, url, kwargs in [
        ("patch", "/me/profile", {"json": {"username": "Other"}}),
        ("post", "/me/avatar", {"files": {"file": ("x.png", image_bytes())}}),
        ("delete", "/me/avatar", {}),
    ]:
        assert (
            getattr(api, method)(
                url + "?account=12345678", headers=headers, **kwargs
            ).status_code
            == 422
        )
    response = api.post(
        "/me/avatar",
        headers=headers,
        files={"file": ("x.png", image_bytes())},
        data={"account": "12345678"},
    )
    assert response.status_code == 422
    response = api.post(
        "/me/avatar",
        headers=headers,
        files=[("file", ("x.png", image_bytes())), ("file", ("y.png", image_bytes()))],
    )
    assert response.status_code == 422
    assert api.get("/users/00000000/profile", headers=headers).status_code == 404
    assert api.get("/avatars/00000000.png", headers=headers).status_code == 404
    assert (
        api.patch(
            f"/users/{account}/profile", headers=headers, json={"username": "Nope"}
        ).status_code
        == 405
    )


def test_disk_failure_and_locked_db_preserve_uploaded_avatar(profile_api, monkeypatch):
    api, path, account, headers = profile_api
    assert upload(api, headers, image_bytes()).status_code == 200
    before = api.get(f"/avatars/{account}.png", headers=headers)
    with sqlite3.connect(path) as lock:
        lock.execute("BEGIN IMMEDIATE")
        response = upload(api, headers, image_bytes(color="blue"))
        assert response.status_code == 503
    original = Path.open

    def fail_write(self, *args, **kwargs):
        if args and args[0] == "xb":
            raise OSError("sensitive-storage-path")
        return original(self, *args, **kwargs)

    monkeypatch.setattr(Path, "open", fail_write)
    response = upload(api, headers, image_bytes(color="blue"))
    assert response.status_code == 503 and "sensitive" not in response.text
    after = api.get(f"/avatars/{account}.png", headers=headers)
    assert (
        before.content == after.content
        and before.headers["etag"] == after.headers["etag"]
    )
    assert len(list(path.parent.rglob("*.png"))) == 1


def test_parallel_replacement_keeps_current_file(profile_api):
    api, path, account, headers = profile_api
    with ThreadPoolExecutor(max_workers=3) as pool:
        results = list(
            pool.map(
                lambda color: upload(api, headers, image_bytes(color=color)),
                ["red", "green", "blue"],
            )
        )
    assert all(result.status_code == 200 for result in results)
    current = api.get(f"/avatars/{account}.png", headers=headers)
    assert current.status_code == 200
    assert current.headers["etag"].strip('"') in {
        result.json()["avatar_version"] for result in results
    }
    assert len(list(path.parent.rglob("*.png"))) == 1


def test_broken_file_is_diagnosable_not_a_silent_identicon(profile_api):
    api, path, account, headers = profile_api
    upload(api, headers, image_bytes())
    next(path.parent.rglob("*.png")).unlink()
    assert api.get(f"/avatars/{account}.png", headers=headers).status_code == 503


def test_sql_failure_after_file_write_rolls_back_and_removes_new_file(profile_api):
    api, path, account, headers = profile_api
    upload(api, headers, image_bytes())
    original = api.get(f"/avatars/{account}.png", headers=headers)
    with sqlite3.connect(path) as db:
        db.execute(
            "CREATE TRIGGER fail_avatar BEFORE UPDATE OF avatar_path ON users BEGIN SELECT RAISE(ABORT, 'injected failure'); END"
        )
    failed = upload(api, headers, image_bytes(color="blue"))
    assert failed.status_code == 503
    assert (
        api.get(f"/avatars/{account}.png", headers=headers).content == original.content
    )
    assert len(list(path.parent.rglob("*.png"))) == 1


def test_other_account_sees_current_avatar_immediately(profile_api):
    api, _, account, headers = profile_api
    _, viewer = login(api, "Viewer")
    url = f"/avatars/{account}.png"
    old = api.get(url, headers=viewer)
    uploaded = upload(api, headers, image_bytes(color="blue")).json()
    current = api.get(url, headers={**viewer, "If-None-Match": old.headers["etag"]})
    assert current.status_code == 200 and current.content != old.content
    assert current.headers["etag"].strip('"') == uploaded["avatar_version"]


def test_streamed_oversized_request_is_bounded(profile_api):
    api, _, _, headers = profile_api
    response = api.post(
        "/me/avatar",
        headers={**headers, "Content-Type": "multipart/form-data; boundary=test"},
        content=iter([b"x" * (MAX_AVATAR_BYTES + 65537)]),
    )
    assert response.status_code == 413
    assert response.json()["error"]["code"] == "payload_too_large"


def test_storage_key_collision_does_not_remove_an_existing_avatar(
    profile_api, monkeypatch
):
    import uuid

    api, path, account, headers = profile_api
    upload(api, headers, image_bytes())
    original = api.get(f"/avatars/{account}.png", headers=headers).content
    existing = next(path.parent.rglob("*.png"))
    monkeypatch.setattr(
        "bb_server.avatars.uuid.uuid4", lambda: uuid.UUID(existing.stem)
    )
    assert upload(api, headers, image_bytes(color="blue")).status_code == 503
    assert existing.exists()
    assert api.get(f"/avatars/{account}.png", headers=headers).content == original
