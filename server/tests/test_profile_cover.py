import hashlib
import io
import random
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from pathlib import Path

import pytest
from bb_auth_contract.cover import DEFAULT_HEADER, MAX_COVER_BYTES, MAX_DISPLAY_BYTES
from fastapi.testclient import TestClient
from PIL import Image, ImageDraw, ImageOps, PngImagePlugin
from test_profile import login

from bb_server.app import create_app
from bb_server.cover_images import DISPLAY_EDGE


def encode(image, fmt="PNG", **options):
    output = io.BytesIO()
    image.save(output, fmt, **options)
    return output.getvalue()


def upload(api, headers, data, url="/me/cover"):
    return api.post(
        url,
        headers=headers,
        files={"file": ("untrusted.extension", data, "text/plain")},
    )


def cover_rows(path):
    with closing(sqlite3.connect(path)) as db:
        return (
            db.execute(
                "SELECT width,height,length(source),length(display) FROM profile_covers"
            ).fetchall(),
            db.execute("SELECT count(*) FROM profile_cover_hashes").fetchone()[0],
            dict(db.execute("SELECT account,cover_id FROM account_covers")),
        )


@pytest.fixture
def account_pair(tmp_path):
    path = tmp_path / "cover.db"
    with TestClient(create_app(path)) as api:
        yield api, path, login(api), login(api, "Other")


def test_auth_cache_failure_and_reopen(account_pair):
    api, path, (alice, a), (bob, b) = account_pair
    url = f"/covers/{alice}"
    before = api.get(url, headers=b)
    assert before.status_code == 200 and before.headers[DEFAULT_HEADER] == "true"
    assert before.content == api.get(f"/covers/{bob}", headers=a).content
    assert len(before.content) <= MAX_DISPLAY_BYTES
    assert (
        before.headers["etag"]
        == '"sha256-' + hashlib.sha256(before.content).hexdigest() + '"'
    )
    assert api.get(url, headers={"If-None-Match": "*"}).status_code == 401
    assert (
        api.get(
            f"/covers/{bob}", headers={**a, "If-None-Match": before.headers["etag"]}
        ).status_code
        == 304
    )
    assert api.get("/covers/not-an-account", headers=a).status_code == 422
    unknown = next(
        str(i) for i in range(10000000, 10000003) if str(i) not in {alice, bob}
    )
    assert api.get(f"/covers/{unknown}", headers=a).status_code == 404

    raw = encode(Image.new("RGB", (96, 60), "navy"))
    assert upload(api, {}, raw).status_code == 401
    assert upload(api, b, raw, f"/me/cover?account={alice}").status_code == 422
    assert (
        api.post(
            "/me/cover",
            headers=b,
            data={"account": alice},
            files={"file": ("cover", raw)},
        ).status_code
        == 422
    )
    saved = upload(api, a, raw)
    assert saved.status_code == 200 and saved.json()["cover_url"] == url
    current = api.get(url, headers={**b, "If-None-Match": before.headers["etag"]})
    assert current.content == raw and current.headers[DEFAULT_HEADER] == "false"
    assert current.headers["etag"] == '"' + saved.json()["cover_version"] + '"'
    assert upload(api, a, b"invalid file").status_code == 415
    assert upload(api, a, bytes(MAX_COVER_BYTES + 1)).status_code == 413
    assert api.get(f"/covers/{bob}", headers=a).content == before.content

    # A new app/DB connection retains the old successful upload.
    with TestClient(create_app(path)) as reopened:
        assert reopened.get(url, headers=a).content == raw


@pytest.mark.parametrize("fmt", ["PNG", "JPEG", "WEBP"])
def test_small_clean_image_is_never_reencoded(account_pair, fmt):
    api, path, (account, headers), _ = account_pair
    raw = encode(Image.new("RGB", (220, 160), "seagreen"), fmt)
    assert upload(api, headers, raw).status_code == 200
    assert api.get(f"/covers/{account}", headers=headers).content == raw
    assert cover_rows(path)[:2] == ([(220, 160, len(raw), None)], 1)


@pytest.mark.parametrize("large_first", [False, True])
def test_reencoded_resize_reuses_highest_source_in_either_order(
    account_pair, large_first
):
    api, path, (alice, a), (bob, b) = account_pair
    asset = Path(__file__).parents[1] / "src/bb_server/profile_cover_default.webp"
    with Image.open(asset) as wave:
        full = wave.convert("RGB").resize((1200, 600), Image.Resampling.LANCZOS)
    large = encode(full, "JPEG", quality=92)
    small = encode(
        full.resize((480, 240), Image.Resampling.LANCZOS), "WEBP", quality=90
    )
    first, second = (large, small) if large_first else (small, large)
    initial = upload(api, a, first).json()
    assert upload(api, a, first).json() == initial
    winner = upload(api, b, second).json()
    assert api.get(f"/covers/{alice}", headers=b).content == large
    assert api.get(f"/covers/{bob}", headers=a).content == large
    assert upload(api, a, small).json()["cover_version"] == winner["cover_version"]
    reencoded = encode(full, "WEBP", quality=92)
    assert upload(api, a, reencoded).json()["cover_version"] == winner["cover_version"]
    rows, hashes, ownership = cover_rows(path)
    assert rows == [(1200, 600, len(large), None)] and hashes == 3
    assert set(ownership) == {alice, bob} and len(set(ownership.values())) == 1

    # Mirror preserves the histogram and dimensions, but changes the picture.
    other = encode(ImageOps.mirror(full), "JPEG", quality=92)
    assert upload(api, b, other).status_code == 200
    assert api.get(f"/covers/{bob}", headers=a).content == other
    assert api.get(f"/covers/{alice}", headers=b).content == large
    assert len(cover_rows(path)[0]) == 2


def test_a_small_local_edit_is_not_pooled_even_when_the_rest_matches(account_pair):
    api, path, (alice, a), (bob, b) = account_pair
    asset = Path(__file__).parents[1] / "src/bb_server/profile_cover_default.webp"
    with Image.open(asset) as wave:
        full = wave.convert("RGB").resize((1200, 600), Image.Resampling.LANCZOS)
    original = encode(full, "JPEG", quality=92)
    ImageDraw.Draw(full).rectangle((110, 80, 180, 130), fill=(245, 230, 210))
    edited = encode(full, "JPEG", quality=92)
    assert upload(api, a, original).status_code == 200
    assert upload(api, b, edited).status_code == 200
    assert api.get(f"/covers/{alice}", headers=b).content == original
    assert api.get(f"/covers/{bob}", headers=a).content == edited
    assert len(cover_rows(path)[0]) == 2


def test_small_cover_metadata_and_orientation_are_handled_without_upscaling(
    account_pair,
):
    api, path, (account, headers), _ = account_pair
    source = Image.new("RGB", (120, 100), "seaGreen")
    exif = source.getexif()
    exif[274] = 6  # 90 degrees clockwise.
    exif[270] = "private test description"
    raw = encode(source, "JPEG", exif=exif)
    assert len(raw) < MAX_DISPLAY_BYTES
    assert upload(api, headers, raw).status_code == 200
    displayed = api.get(f"/covers/{account}", headers=headers)
    with Image.open(io.BytesIO(displayed.content)) as result:
        assert result.size == (100, 120)
        assert 270 not in result.getexif()
    assert cover_rows(path)[0] == [(100, 120, len(raw), len(displayed.content))]

    info = PngImagePlugin.PngInfo()
    info.add_text("Comment", "private test text")
    raw = encode(source, pnginfo=info)
    assert upload(api, headers, raw).status_code == 200
    displayed = api.get(f"/covers/{account}", headers=headers)
    assert b"private test text" not in displayed.content
    with Image.open(io.BytesIO(displayed.content)) as result:
        assert result.size == (120, 100)


def test_large_derivative_caps_and_concurrent_exact_upload(account_pair):
    api, path, (alice, a), (bob, b) = account_pair
    size = (2400, 1200)
    rng = random.Random(492)
    high_detail = Image.frombytes("RGB", size, rng.randbytes(size[0] * size[1] * 3))
    raw = encode(high_detail, "JPEG", quality=96)
    assert MAX_DISPLAY_BYTES < len(raw) <= MAX_COVER_BYTES
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(lambda h: upload(api, h, raw), (a, b)))
    assert [r.status_code for r in responses] == [200, 200]
    assert responses[0].json()["cover_version"] == responses[1].json()["cover_version"]
    displayed = api.get(f"/covers/{alice}", headers=a)
    assert displayed.content == api.get(f"/covers/{bob}", headers=b).content
    with Image.open(io.BytesIO(displayed.content)) as result:
        assert result.format == "WEBP"
        assert result.width == 2 * result.height and result.width <= DISPLAY_EDGE
    assert len(displayed.content) <= MAX_DISPLAY_BYTES
    assert cover_rows(path)[:2] == ([(2400, 1200, len(raw), len(displayed.content))], 1)


def test_cover_pointer_and_source_rollback_together(account_pair):
    api, path, (alice, a), _ = account_pair
    previous = encode(Image.new("RGB", (96, 60), "navy"))
    assert upload(api, a, previous).status_code == 200
    initial_rows = cover_rows(path)
    with closing(sqlite3.connect(path)) as db:
        db.execute(
            """CREATE TRIGGER fail_cover_update BEFORE UPDATE ON account_covers
               BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END"""
        )
    replacement = encode(Image.new("RGB", (96, 60), "red"))
    assert upload(api, a, replacement).status_code == 503
    assert api.get(f"/covers/{alice}", headers=a).content == previous
    assert cover_rows(path) == initial_rows
    with closing(sqlite3.connect(path)) as db:
        db.execute("DROP TRIGGER fail_cover_update")
    assert upload(api, a, replacement).status_code == 200
    assert api.get(f"/covers/{alice}", headers=a).content == replacement
    assert cover_rows(path)[:2] == ([(96, 60, len(replacement), None)], 1)
