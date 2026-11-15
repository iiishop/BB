"""Space visibility references over the existing media directory/thumbnail codec."""

import base64
import hashlib
import io
import os
import re
import tempfile
from pathlib import Path

from bb_auth_contract.space import MAX_IMAGE_BYTES
from PIL import Image, UnidentifiedImageError

from .media_thumbnails import thumbnail
from .space_queries import fail
from .storage import connection


def decode(body):
    try:
        data = base64.b64decode(body.base64, validate=True)
    except ValueError:
        fail(422, "validation_error")
    if len(data) > MAX_IMAGE_BYTES:
        fail(413, "payload_too_large")
    try:
        with Image.open(io.BytesIO(data)) as img:
            mime = {"PNG": "image/png", "JPEG": "image/jpeg", "WEBP": "image/webp"}.get(img.format)
            if mime is None:
                fail(415, "unsupported_media_type")
            img.verify()
    except (UnidentifiedImageError, OSError, ValueError, SyntaxError, Image.DecompressionBombError):
        fail(415, "unsupported_media_type")
    return data, mime, hashlib.sha256(data).hexdigest()


def store(directory, data, blob):
    """Caller holds the SQLite writer lock, including against reference GC."""
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / blob
    if destination.is_file():
        return
    fd, name = tempfile.mkstemp(prefix="upload-", dir=directory)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
        if os.name != "nt":
            parent_fd = os.open(directory, os.O_RDONLY)
            try:
                os.fsync(parent_fd)
            finally:
                os.close(parent_fd)
    finally:
        temporary.unlink(missing_ok=True)


def release(db, field, value, keep=()):
    assert field in ("post_id", "draft_id")
    for row in db.execute(f"SELECT id,blob FROM space_images WHERE {field}=?", (value,)).fetchall():
        if row["id"] not in keep:
            db.execute("INSERT OR IGNORE INTO space_gc VALUES (?)", (row["blob"],))
            db.execute("DELETE FROM space_images WHERE id=?", (row["id"],))


def collect(path, directory, *, scan=False):
    # Authorize access by live DB references first. Cleanup failure never rolls
    # back a committed delete; the queue remains and maintenance retries it.
    with connection(path, write=True) as db:
        if scan and directory.exists():
            for entry in directory.iterdir():
                if entry.is_file() and re.fullmatch(r"[a-f0-9]{64}", entry.name):
                    db.execute("INSERT OR IGNORE INTO space_gc VALUES (?)", (entry.name,))
                elif entry.is_file() and entry.name.startswith("upload-"):
                    entry.unlink(missing_ok=True)
        for row in db.execute("SELECT blob FROM space_gc").fetchall():
            blob = row["blob"]
            if not db.execute("SELECT 1 FROM space_images WHERE blob=? LIMIT 1", (blob,)).fetchone():
                (directory / blob).unlink(missing_ok=True)
                (directory / "derivatives" / "thumb-v1" / (blob + ".jpg")).unlink(missing_ok=True)
            db.execute("DELETE FROM space_gc WHERE blob=?", (blob,))


def read(db, directory, account, image_id, variant):
    row = db.execute("""SELECT i.* FROM space_images i
        LEFT JOIN space_posts p ON p.id=i.post_id
        LEFT JOIN space_drafts d ON d.id=i.draft_id
        WHERE i.id=? AND ((p.id IS NOT NULL AND p.deleted=0)
          OR (d.author=? AND d.state='draft'))""", (image_id, account)).fetchone()
    if row is None:
        fail(404, "not_found")
    # Read bytes before releasing snapshot. Deletion cannot unlink halfway
    # through a deferred FileResponse after its authorization transaction ends.
    if variant == "thumb":
        source, _ = thumbnail(directory, row["blob"])
        return source.read_bytes(), "image/jpeg"
    return (directory / row["blob"]).read_bytes(), row["mime"]
