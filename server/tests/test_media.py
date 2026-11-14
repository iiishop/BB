"""Media byte boundaries, access checks and recovery using synthetic accounts."""

import io
import json
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
import test_chat as chat_cases
from bb_auth_contract.chat import Media
from bb_auth_contract.media import THUMB_MAX_BYTES, THUMB_MAX_EDGE
from fastapi.testclient import TestClient
from PIL import Image
from test_admin_http import free_port, running

from bb_server.app import create_app

chat = chat_cases.chat


def picture(size=(1200, 900)):
    output = io.BytesIO()
    # Deterministic high-entropy pixels exercise the byte cap, not just dimensions.
    import random

    Image.frombytes(
        "RGB", size, random.Random(471).randbytes(size[0] * size[1] * 3)
    ).save(output, format="PNG")
    return output.getvalue()


def upload(api, owner, peer, data, mime="image/png", cover=None):
    response = api.post(
        "/media",
        headers=owner[1],
        data={
            "target_account": peer[0],
            **({"cover_media_id": cover} if cover else {}),
        },
        files={"file": ("synthetic-media", data, mime)},
    )
    assert response.status_code == 200, response.text
    return Media.model_validate(response.json()).model_dump()


def check_thumb(response):
    assert response.status_code == 200, response.text[:200]
    assert response.headers["content-type"] == "image/jpeg"
    assert len(response.content) <= THUMB_MAX_BYTES
    assert int(response.headers["content-length"]) == len(response.content)
    with Image.open(io.BytesIO(response.content)) as image:
        image.load()
        assert max(image.size) <= THUMB_MAX_EDGE
        assert not image.getexif()


def test_real_media_cli_restart(tmp_path):
    port = free_port()
    env = {
        **os.environ,
        "BB_DATABASE_PATH": str(tmp_path / "chat.db"),
        "BB_AVATAR_DIRECTORY": str(tmp_path / "avatars"),
        "BB_MEDIA_DIRECTORY": str(tmp_path / "media"),
        "BB_HOST": "127.0.0.1",
        "BB_PORT": str(port),
    }
    url = f"http://127.0.0.1:{port}"
    original = picture()
    assert len(original) > 3 * 1024 * 1024
    with running("bb-server", env, url, tmp_path / "first.log") as api:
        people = []
        for name in ("SyntheticSender", "SyntheticRecipient"):
            account = api.post(
                "/auth/register", json={"username": name, "password": "Abc123"}
            ).json()["account"]
            token = api.post(
                "/auth/login", json={"account": account, "password": "Abc123"}
            ).json()["token"]
            people.append((account, {"Authorization": "Bearer " + token}))
        a, b = people
        media = upload(api, a, b, original)
        route = f"/media/{media['media_id']}"
        assert api.get(route + "/metadata", headers=b[1]).json() == media
        thumb = api.get(route + "?variant=thumb", headers=b[1])
        check_thumb(thumb)
        ranged = api.get(route, headers={**b[1], "Range": "bytes=2-17"})
        assert ranged.status_code == 206
        assert ranged.content == original[2:18]
        assert ranged.headers["content-range"] == f"bytes 2-17/{len(original)}"
    with running("bb-server", env, url, tmp_path / "restart.log") as api:
        cached = api.get(route + "?variant=thumb", headers=b[1])
        assert cached.content == thumb.content
        assert cached.headers["etag"] == thumb.headers["etag"]
        assert api.get(route, headers=b[1]).content == original
        derivative = next((tmp_path / "media" / "derivatives").rglob("*.jpg"))
        derivative.unlink()  # Disposable cache: cold generation after a restart.
        assert api.get(route + "?variant=thumb", headers=b[1]).content == thumb.content


def test_metadata_history_acl_and_no_file_access(chat):
    api, path, (a, b, c) = chat
    original = picture((40, 40))
    media = upload(api, a, b, original)
    mid = media["media_id"]
    body = {
        "target_account": b[0],
        "client_nonce": "historic-picture",
        "content": [{"type": "image", "media_id": mid}],
    }
    assert api.post("/messages", json=body, headers=a[1]).status_code == 200
    message = api.get(f"/conversations/{a[0]}/messages", headers=b[1]).json()["items"][
        0
    ]
    assert message["content"] == body["content"]
    directory = path.parent / (path.name + ".media")
    (directory / mid).unlink()
    route = f"/media/{message['content'][0]['media_id']}/metadata"
    with TestClient(create_app(path)) as restarted:
        for person in (a, b):
            result = restarted.get(route, headers=person[1])
            assert result.status_code == 200
            assert result.json() == media
            assert result.json()["byte_size"] == len(original)
            assert result.headers["cache-control"] == "private, no-store"
        assert restarted.get(route, headers=c[1]).status_code == 404
        assert restarted.get(route).status_code == 401
        assert restarted.get("/media/missing/metadata", headers=a[1]).status_code == 404
    assert not (directory / "derivatives").exists()


@pytest.mark.parametrize("size", [(1200, 900), (512, 512)])
def test_thumbnail_bounds_conditional_acl_and_original_ranges(chat, size):
    api, path, (a, b, c) = chat
    original = picture(size)
    media = upload(api, a, b, original)
    route = "/media/" + media["media_id"]
    thumb_url = route + "?variant=thumb"
    assert api.get(thumb_url, headers=c[1]).status_code == 404
    directory = path.parent / (path.name + ".media")
    assert not (directory / "derivatives").exists()
    thumb = api.get(thumb_url, headers=b[1])
    check_thumb(thumb)
    assert thumb.headers["cache-control"] == "private, no-cache"
    assert thumb.headers["x-content-type-options"] == "nosniff"
    for condition in (
        thumb.headers["etag"],
        "*",
        '"other", W/' + thumb.headers["etag"],
    ):
        cached = api.get(thumb_url, headers={**a[1], "If-None-Match": condition})
        assert cached.status_code == 304 and cached.content == b""
        assert (
            api.get(thumb_url, headers={**c[1], "If-None-Match": condition}).status_code
            == 404
        )
        assert (
            api.get(thumb_url, headers={"If-None-Match": condition}).status_code == 401
        )
    partial = api.get(thumb_url, headers={**b[1], "Range": "bytes=0-9"})
    assert partial.status_code == 206 and partial.content == thumb.content[:10]
    for suffix in ("", "?variant=original"):
        assert api.get(route + suffix, headers=b[1]).content == original
        partial = api.get(route + suffix, headers={**b[1], "Range": "bytes=-11"})
        assert partial.status_code == 206 and partial.content == original[-11:]
        invalid = api.get(
            route + suffix, headers={**b[1], "Range": f"bytes={len(original)}-"}
        )
        assert invalid.status_code == 416
        assert invalid.headers["content-range"] == f"bytes */{len(original)}"
        malformed = api.get(route + suffix, headers={**b[1], "Range": "bytes=oops"})
        assert malformed.status_code == 400
    assert api.get(route + "?variant=unknown", headers=a[1]).status_code == 422


def test_cover_and_non_image_variants(chat):
    api, _, (a, b, c) = chat
    cover = upload(api, a, b, picture((80, 60)))
    video_bytes = b"0000ftyp" + b"synthetic-video" * 100
    video = upload(api, a, b, video_bytes, "video/mp4", cover["media_id"])
    route = "/media/" + video["media_id"]
    assert api.get(route + "/metadata", headers=b[1]).json() == video
    assert api.get(route + "?variant=thumb", headers=b[1]).status_code == 415
    assert api.get(route + "?variant=thumb", headers=c[1]).status_code == 404
    check_thumb(api.get(f"/media/{cover['media_id']}?variant=thumb", headers=b[1]))
    ranged = api.get(route, headers={**b[1], "Range": "bytes=0-7"})
    assert ranged.status_code == 206 and ranged.content == video_bytes[:8]


@pytest.mark.parametrize("failure_stage", ["fsync", "replace"])
def test_concurrent_generation_write_failure_retry_and_missing_source(
    chat, monkeypatch, failure_stage
):
    from bb_server import media_thumbnails

    api, path, (a, b, _) = chat
    original = picture()
    media = upload(api, a, b, original)
    route = f"/media/{media['media_id']}?variant=thumb"
    directory = path.parent / (path.name + ".media")
    replace = media_thumbnails.os.replace

    def fail_replace(*args):
        raise OSError("synthetic failure before publication")

    with monkeypatch.context() as patch:
        patch.setattr(media_thumbnails.os, failure_stage, fail_replace)
        failed = api.get(route, headers=b[1])
        assert failed.status_code == 503
        assert failed.json()["error"]["code"] == "thumbnail_unavailable"
    assert not list((directory / "derivatives").rglob("*.tmp"))
    assert not list((directory / "derivatives").rglob("*.jpg"))
    assert media_thumbnails.os.replace is replace
    with ThreadPoolExecutor(max_workers=8) as pool:
        replies = list(pool.map(lambda _: api.get(route, headers=b[1]), range(8)))
    for response in replies:
        check_thumb(response)
    assert len({response.content for response in replies}) == 1
    assert not list((directory / "derivatives").rglob("*.tmp"))
    assert len(list((directory / "derivatives").rglob("*.jpg"))) == 1
    assert (directory / media["media_id"]).read_bytes() == original
    # A missing source is retryable without changing the authoritative record.
    other = upload(api, a, b, picture((30, 30)))
    source = directory / other["media_id"]
    data = source.read_bytes()
    source.unlink()
    other_route = f"/media/{other['media_id']}?variant=thumb"
    assert api.get(other_route, headers=b[1]).status_code == 503
    source.write_bytes(b"corrupted source")
    assert api.get(other_route, headers=b[1]).status_code == 503
    source.write_bytes(data)
    # A hard-killed writer's temporary file is not a published cache hit.
    orphan = (
        directory / "derivatives" / "thumb-v1" / (other["media_id"] + ".crashed.tmp")
    )
    orphan.write_bytes(b"half a derivative")
    check_thumb(api.get(other_route, headers=b[1]))
    assert orphan.read_bytes() == b"half a derivative"


@pytest.mark.parametrize("kind", ["transparent", "oriented", "animated"])
def test_thumbnail_pixel_policy(chat, kind):
    api, _, (a, b, _) = chat
    output = io.BytesIO()
    if kind == "transparent":
        Image.new("RGBA", (30, 20), (255, 0, 0, 0)).save(output, format="PNG")
        mime, expected_size, expected_pixel = "image/png", (30, 20), (255, 255, 255)
    elif kind == "oriented":
        exif = Image.Exif()
        exif[274] = 6
        Image.new("RGB", (30, 20), "red").save(output, format="JPEG", exif=exif)
        mime, expected_size, expected_pixel = "image/jpeg", (20, 30), (254, 0, 0)
    else:
        Image.new("RGB", (30, 20), "red").save(
            output,
            format="WEBP",
            save_all=True,
            append_images=[Image.new("RGB", (30, 20), "blue")],
            duration=100,
            lossless=True,
        )
        mime, expected_size, expected_pixel = "image/webp", (30, 20), (254, 0, 0)
    media = upload(api, a, b, output.getvalue(), mime)
    result = api.get(f"/media/{media['media_id']}?variant=thumb", headers=b[1])
    check_thumb(result)
    with Image.open(io.BytesIO(result.content)) as image:
        assert image.size == expected_size
        assert all(
            abs(x - y) <= 2 for x, y in zip(image.getpixel((0, 0)), expected_pixel)
        )


def test_media_openapi_matches_export():
    schema = create_app(Path("unused-for-schema")).openapi()
    snapshot = json.loads((Path(__file__).parents[1] / "openapi.json").read_text())
    assert schema == snapshot
    metadata = schema["paths"]["/media/{media_id}/metadata"]["get"]
    assert metadata["responses"]["200"]["content"]["application/json"]["schema"] == {
        "$ref": "#/components/schemas/Media"
    }
    params = schema["paths"]["/media/{media_id}"]["get"]["parameters"]
    variant = next(p for p in params if p["name"] == "variant")
    assert variant["schema"]["enum"] == ["original", "thumb"]
    assert variant["schema"]["default"] == "original"
    replies = schema["paths"]["/media/{media_id}"]["get"]["responses"]
    assert {"200", "206", "304", "400", "416"} <= replies.keys()
    for status in ("200", "206"):
        assert replies[status]["content"]["image/jpeg"]["schema"]["format"] == "binary"
