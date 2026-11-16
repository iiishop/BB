"""Deterministic defaults and immutable uploaded PNGs; no client-supplied paths."""

import colorsys
import hashlib
import io
import logging
import os
import re
import uuid
import warnings
from pathlib import Path

from bb_auth_contract import ContractError
from bb_auth_contract.profile import MAX_AVATAR_BYTES
from PIL import Image, UnidentifiedImageError

from bb_server.storage import connection

from .media_thumbnails import encode_stream

logger = logging.getLogger(__name__)


def default_version(account: str) -> str:
    return "identicon-v1-" + hashlib.sha256(account.encode("utf-8")).hexdigest()


def identicon(account: str) -> bytes:
    digest = hashlib.sha256(account.encode("utf-8")).digest()
    color = tuple(
        round(c * 255) for c in colorsys.hls_to_rgb(digest[2] / 255, 0.5, 0.65)
    ) + (255,)
    image = Image.new("RGBA", (5, 5), (0, 0, 0, 0))
    for row in range(5):
        for col in range(3):
            index = row * 3 + col
            if digest[index // 8] & (1 << (7 - index % 8)):
                image.putpixel((col, row), color)
                image.putpixel((4 - col, row), color)
    output = io.BytesIO()
    image.resize((250, 250), Image.Resampling.NEAREST).save(output, format="PNG")
    return output.getvalue()


def normalize_image(data: bytes) -> bytes:
    if len(data) > MAX_AVATAR_BYTES:
        raise ContractError(413, "payload_too_large", "头像不能超过 5 MiB")
    magic = (
        "PNG"
        if data.startswith(b"\x89PNG\r\n\x1a\n")
        else "JPEG"
        if data.startswith(b"\xff\xd8\xff")
        else "WEBP"
        if data.startswith(b"RIFF") and data[8:12] == b"WEBP"
        else None
    )
    try:
        if magic is None:
            raise ValueError("format")
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data)) as image:
                if image.format != magic:
                    raise ValueError("format")
                image.verify()
            with Image.open(io.BytesIO(data)) as image:
                image.load()
                # No metadata or animation is copied. Keep uploaded pixel dimensions.
                pixels = image.convert("RGBA")
                pixels.info.clear()
                output = io.BytesIO()
                pixels.save(output, format="PNG")
                return output.getvalue()
    except (
        ValueError,
        OSError,
        UnidentifiedImageError,
        Image.DecompressionBombError,
        Image.DecompressionBombWarning,
    ):
        raise ContractError(
            415, "unsupported_media_type", "头像必须为可解码的 PNG、JPEG 或 WebP"
        ) from None


THUMB_SUFFIX = "-thumb.jpg"


def thumb_name(name: str) -> str:
    return name[: -len(".png")] + THUMB_SUFFIX


def thumbnail(png: bytes) -> bytes:
    """Downscaled copy for lists and bubbles, using the media thumbnail policy.

    Originals stay at upload resolution — a phone photo became a 700 KB PNG and
    every cold client paid for it. Same 512 px / JPEG / byte-cap encoder the chat
    attachments use, so there is one derivative policy rather than two.
    """
    return encode_stream(io.BytesIO(png))


AVATAR_NAME = re.compile(r"[0-9a-f]{32}\.png")
AVATAR_THUMB = re.compile(r"[0-9a-f]{32}-thumb\.jpg")


def avatar_file(directory: Path, name: str) -> Path:
    if not (AVATAR_NAME.fullmatch(name) or AVATAR_THUMB.fullmatch(name)):
        raise OSError("Invalid stored avatar key")
    path = directory / name
    if path.is_symlink():
        raise OSError("Invalid stored avatar file")
    return path


def remove_file(directory: Path, name: str | None):
    if name:
        for candidate in (name, thumb_name(name)):
            try:
                avatar_file(directory, candidate).unlink(missing_ok=True)
            except OSError:
                # The DB already committed. An orphan is harmless and can be
                # cleaned offline; never report a committed update as failed and
                # invite retry.
                logger.warning("avatar_orphan_cleanup_failed")


def replace_avatar(database: Path, directory: Path, account: str, png: bytes | None):
    name = uuid.uuid4().hex + ".png" if png is not None else None
    version = "sha256-" + hashlib.sha256(png).hexdigest() if png is not None else None
    created = False
    try:
        with connection(database, write=True) as db:
            old = db.execute(
                "SELECT avatar_path FROM users WHERE account=?", (account,)
            ).fetchone()[0]
            if name and png is not None:
                directory.mkdir(parents=True, exist_ok=True)
                with avatar_file(directory, name).open("xb") as file:
                    created = True
                    file.write(png)
                    file.flush()
                    os.fsync(file.fileno())
                # Derivative written next to the original: lists and bubbles ask
                # for this one, profile detail keeps the original.
                with avatar_file(directory, thumb_name(name)).open("xb") as file:
                    created = True
                    file.write(thumbnail(png))
                    file.flush()
                    os.fsync(file.fileno())
                if os.name != "nt":
                    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
                    try:
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
            db.execute(
                "UPDATE users SET avatar_path=?,avatar_version=? WHERE account=?",
                (name, version, account),
            )
    except Exception:
        if created:
            remove_file(directory, name)
        raise
    remove_file(directory, old)
    return {
        "avatar_url": f"/avatars/{account}.png",
        "avatar_version": version or default_version(account),
    }


def read_avatar(
    database: Path, directory: Path, account: str, variant: str = "original"
) -> tuple[bytes, str, str]:
    """Stored avatar bytes, its version tag and the media type.

    ``variant="thumb"`` returns the derivative when one exists; uploads made
    before derivatives shipped fall back to the original instead of 404.
    """
    with connection(database, write=True) as db:
        # Serialize file lookup/read with replacement so the old file cannot be
        # removed between the lookup and read, including across server workers.
        row = db.execute(
            "SELECT avatar_path,avatar_version FROM users WHERE account=?", (account,)
        ).fetchone()
        if row is None:
            raise ContractError(404, "not_found", "用户不存在")
        if row["avatar_path"]:
            name = row["avatar_path"]
            version = row["avatar_version"]
            if variant == "thumb":
                try:
                    data = avatar_file(directory, thumb_name(name)).read_bytes()
                    return data, version + THUMB_SUFFIX, "image/jpeg"
                except OSError:
                    pass
            return avatar_file(directory, name).read_bytes(), version, "image/png"
    if variant == "thumb":
        return (
            thumbnail(identicon(account)),
            default_version(account) + THUMB_SUFFIX,
            "image/jpeg",
        )
    return identicon(account), default_version(account), "image/png"


def etag_matches(header: str | None, etag: str) -> bool:
    if not header:
        return False
    return any(
        tag.strip().removeprefix("W/") in (etag, "*") for tag in header.split(",")
    )
