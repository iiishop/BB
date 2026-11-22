"""Account-owned pointers to deduplicated profile cover images."""

import hashlib
from dataclasses import dataclass
from functools import cache
from pathlib import Path

from bb_auth_contract import ContractError
from bb_auth_contract.cover import MAX_DISPLAY_BYTES, READ_PATH, CoverResponse

from .cover_images import (
    ASPECT_TOLERANCE,
    CoverSource,
    decode_source,
    detail_agrees,
    display_image,
    signatures_agree,
)
from .storage import connection, maintain_sessions


@dataclass(frozen=True)
class Display:
    data: bytes
    mime_type: str
    version: str
    is_default: bool = False


def _version(data: bytes) -> str:
    return "sha256-" + hashlib.sha256(data).hexdigest()


@cache
def default_cover() -> Display:
    data = Path(__file__).with_name("profile_cover_default.png").read_bytes()
    return Display(data, "image/png", _version(data), is_default=True)


def read_cover(path: Path, account: str) -> Display:
    with connection(path) as db:
        row = db.execute(
            """SELECT COALESCE(c.display, c.source) AS data, c.mime_type, c.version
               FROM users u
               LEFT JOIN account_covers a ON a.account=u.account
               LEFT JOIN profile_covers c ON c.id=a.cover_id
               WHERE u.account=?""",
            (account,),
        ).fetchone()
    if row is None:
        raise ContractError(404, "not_found", "用户不存在")
    if row["version"] is None:
        return default_cover()
    return Display(row["data"], row["mime_type"], row["version"])


def _exact(db, digest):
    return db.execute(
        """SELECT c.id, c.version
           FROM profile_cover_hashes h JOIN profile_covers c ON c.id=h.cover_id
           WHERE h.hash=?""",
        (digest,),
    ).fetchone()


def _same_cover(db, source: CoverSource):
    if min(source.pixels.size) < 96:
        return None
    candidates = db.execute(
        """SELECT id, width, height, signature, anchor, version FROM profile_covers
           WHERE aspect BETWEEN ? AND ? AND tone BETWEEN ? AND ?
             AND width>=96 AND height>=96""",
        (
            source.aspect / (1 + ASPECT_TOLERANCE),
            source.aspect * (1 + ASPECT_TOLERANCE),
            source.tone - 11,
            source.tone + 11,
        ),
    )
    match = None
    for candidate in candidates:
        signature, anchor = candidate["signature"], candidate["anchor"]
        if not signatures_agree(source.signature, signature):
            continue
        if anchor != signature and not signatures_agree(source.signature, anchor):
            continue
        raw = db.execute(
            "SELECT source FROM profile_covers WHERE id=?", (candidate["id"],)
        ).fetchone()["source"]
        if not detail_agrees(source.pixels, decode_source(raw).pixels):
            continue
        # More than one confirmed-looking candidate is ambiguous.
        if match is not None:
            return None
        match = candidate
    return match


def _store_source(db, digest, raw: bytes, source: CoverSource):
    existing = _same_cover(db, source)
    width, height = source.pixels.size
    if existing and width * height <= existing["width"] * existing["height"]:
        cover_id, version = existing["id"], existing["version"]
    else:
        display, mime = (
            (None, source.mime_type)
            if source.safe_original
            else display_image(source, prefer_lossless=len(raw) <= MAX_DISPLAY_BYTES)
        )
        version = _version(raw if display is None else display)
        values = (
            width,
            height,
            source.aspect,
            source.tone,
            source.signature,
            raw,
            display,
            mime,
            version,
        )
        if existing:
            cover_id = existing["id"]
            db.execute(
                """UPDATE profile_covers SET width=?, height=?, aspect=?, tone=?, signature=?,
                   source=?, display=?, mime_type=?, version=? WHERE id=?""",
                (*values, cover_id),
            )
        else:
            cover_id = db.execute(
                """INSERT INTO profile_covers
                   (width,height,aspect,tone,signature,source,display,mime_type,version,anchor)
                   VALUES (?,?,?,?,?,?,?,?,?,?)""",
                (*values, source.signature),
            ).lastrowid
    db.execute("INSERT INTO profile_cover_hashes VALUES (?,?)", (digest, cover_id))
    return cover_id, version


def replace_cover(path: Path, session_digest: str, raw: bytes, clock) -> CoverResponse:
    digest = hashlib.sha256(raw).digest()
    with connection(path) as db:
        known = _exact(db, digest)
    # The exact path does not decode. Retry the lookup after acquiring the
    # writer lock, since another replacement may have collected the image.
    source = None if known else decode_source(raw)
    while True:
        with connection(path, write=True) as db:
            maintain_sessions(db, clock())
            session = db.execute(
                "SELECT account FROM sessions WHERE token_hash=?", (session_digest,)
            ).fetchone()
            if session is None:
                raise ContractError(401, "unauthenticated", "请重新登录")
            account = session["account"]
            exact = _exact(db, digest)
            if exact or source is not None:
                cover_id, version = (
                    exact if exact else _store_source(db, digest, raw, source)
                )
                old = db.execute(
                    "SELECT cover_id FROM account_covers WHERE account=?", (account,)
                ).fetchone()
                db.execute(
                    """INSERT INTO account_covers VALUES (?,?)
                       ON CONFLICT(account) DO UPDATE SET cover_id=excluded.cover_id""",
                    (account, cover_id),
                )
                if old is not None and old["cover_id"] != cover_id:
                    db.execute(
                        """DELETE FROM profile_covers WHERE id=?
                           AND NOT EXISTS (SELECT 1 FROM account_covers WHERE cover_id=?)""",
                        (old["cover_id"], old["cover_id"]),
                    )
                return CoverResponse(
                    cover_url=READ_PATH.format(account=account), cover_version=version
                )
        source = decode_source(raw)
