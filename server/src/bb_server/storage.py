import secrets
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path


@contextmanager
def connection(path: Path):
    db = sqlite3.connect(path, timeout=1.0)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    try:
        with db:
            yield db
    finally:
        db.close()


def migrate(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with connection(path) as db:
        db.execute("BEGIN IMMEDIATE")
        version = db.execute("PRAGMA user_version").fetchone()[0]
        if version > 3:
            raise RuntimeError("Database schema is newer than this server")
        for number, filename in [
            (1, "001_auth.sql"),
            (2, "002_profile.sql"),
            (3, "003_chat.sql"),
        ]:
            if version >= number:
                continue
            sql = (Path(__file__).parent / "migrations" / filename).read_text(
                encoding="utf-8"
            )
            # execute each statement in the current transaction; executescript commits first.
            for statement in sql.split(";"):
                if statement.strip():
                    db.execute(statement)
            db.execute(f"PRAGMA user_version={number}")


def insert_user(path: Path, username: str, password_hash: str) -> str:
    with connection(path) as db:
        for _ in range(100):
            account = str(10_000_000 + secrets.randbelow(90_000_000))
            cursor = db.execute(
                "INSERT INTO users(account,username,password) VALUES (?,?,?) ON CONFLICT(account) DO NOTHING",
                (account, username, password_hash),
            )
            if cursor.rowcount:
                return account
    raise sqlite3.OperationalError("Account allocation exhausted")


def find_user(path: Path, account: str):
    with connection(path) as db:
        return db.execute(
            "SELECT account,username,password FROM users WHERE account=?", (account,)
        ).fetchone()


def insert_session(path: Path, account: str, token_hash: str, now: float | None = None):
    with connection(path) as db:
        db.execute(
            "INSERT INTO sessions(token_hash,account,last_seen_at) VALUES (?,?,?)",
            (token_hash, account, time.time() if now is None else now),
        )


def maintain_sessions(db, now: float):
    # Derive the offline boundary even after a server outage. Both operations are
    # in one write transaction, also shared by heartbeat to prevent resurrection.
    db.execute(
        "UPDATE sessions SET status='offline', offline_since=last_seen_at+90 WHERE last_seen_at<=? AND status='online'",
        (now - 90,),
    )
    db.execute(
        "DELETE FROM sessions WHERE status='offline' AND offline_since<?",
        (now - 86400,),
    )


def cleanup_sessions(path: Path, now: float):
    with connection(path) as db:
        db.execute("BEGIN IMMEDIATE")
        maintain_sessions(db, now)


def find_session(path: Path, token_hash: str, now: float | None = None):
    with connection(path) as db:
        db.execute("BEGIN IMMEDIATE")
        maintain_sessions(db, time.time() if now is None else now)
        return db.execute(
            "SELECT users.account, users.username FROM sessions JOIN users USING(account) WHERE token_hash=?",
            (token_hash,),
        ).fetchone()


def heartbeat(path: Path, token_hash: str, now: float) -> bool:
    with connection(path) as db:
        db.execute("BEGIN IMMEDIATE")
        maintain_sessions(db, now)
        return bool(
            db.execute(
                "UPDATE sessions SET last_seen_at=?, status='online', offline_since=NULL WHERE token_hash=?",
                (now, token_hash),
            ).rowcount
        )


def delete_session(path: Path, token_hash: str):
    with connection(path) as db:
        db.execute("DELETE FROM sessions WHERE token_hash=?", (token_hash,))


def get_profile(path: Path, account: str):
    with connection(path) as db:
        return db.execute(
            "SELECT account,username,signature,avatar_path,avatar_version FROM users WHERE account=?",
            (account,),
        ).fetchone()


def update_profile(path: Path, account: str, changes: dict):
    with connection(path) as db:
        for field in ("username", "signature"):
            if field in changes:
                db.execute(
                    f"UPDATE users SET {field}=? WHERE account=?",
                    (changes[field], account),
                )
