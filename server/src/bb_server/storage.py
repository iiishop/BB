import logging
import random
import secrets
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path

LOCK_WAIT_SECONDS = 3.0
logger = logging.getLogger(__name__)


def _lock_statement(db, statement, deadline):
    """Retry only BUSY at a transaction boundary, never the operation body.

    SQLite keeps a transaction active when COMMIT returns BUSY. IO/LOCKED/other
    errors are not retried. One budget covers acquisition, body time and commit.
    """
    started = time.monotonic()
    attempts = 0
    while True:
        attempts += 1
        try:
            db.execute(statement)
            if attempts > 1:
                logger.warning(
                    "storage_lock_recovered phase=%s attempts=%d wait_ms=%.1f",
                    statement,
                    attempts,
                    (time.monotonic() - started) * 1000,
                )
            return
        except sqlite3.Error as error:
            if getattr(error, "sqlite_errorcode", 0) & 255 != sqlite3.SQLITE_BUSY:
                raise
            elapsed = (time.monotonic() - started) * 1000
            error.storage_attempts = attempts
            error.storage_wait_ms = round(elapsed, 1)
            error.storage_phase = statement
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise
            if attempts == 1:
                logger.warning(
                    "storage_lock_retry phase=%s sqlite_error=SQLITE_BUSY budget_ms=%.1f",
                    statement,
                    remaining * 1000,
                )
            delay = min(0.01 * 2 ** min(attempts - 1, 4), 0.1)
            time.sleep(min(remaining, random.uniform(delay / 2, delay)))


@contextmanager
def connection(path: Path, *, write=False):
    db = sqlite3.connect(path, timeout=0, isolation_level=None)
    db.row_factory = sqlite3.Row
    try:
        db.execute("PRAGMA foreign_keys=ON")
        deadline = time.monotonic() + LOCK_WAIT_SECONDS
        if write:
            _lock_statement(db, "BEGIN IMMEDIATE", deadline)
        else:
            db.execute("PRAGMA query_only=ON")
            db.execute("BEGIN")
            # BEGIN is deferred: acquire the SHARED snapshot before yielding.
            # A pending/exclusive writer may block this, even for a read route.
            # Retry acquisition only; never rerun a partially executed body.
            _lock_statement(db, "SELECT rootpage FROM sqlite_schema LIMIT 1", deadline)
        yield db
        if write:
            _lock_statement(db, "COMMIT", deadline)
        else:
            db.commit()
    except BaseException:
        db.rollback()
        raise
    finally:
        db.close()


def migrate(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with connection(path, write=True) as db:
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
    with connection(path, write=True) as db:
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
    with connection(path, write=True) as db:
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
    with connection(path, write=True) as db:
        maintain_sessions(db, now)


def find_session(path: Path, token_hash: str, now: float | None = None):
    timestamp = time.time() if now is None else now
    with connection(path) as db:
        # Authentication is normally read-only. Taking the sole writer lock for
        # every lookup competes with message commits even when no session is due.
        # Do not retain a read transaction while acquiring the writer lock: the
        # maintenance statements recheck their predicates after BEGIN IMMEDIATE.
        due = db.execute(
            "SELECT 1 FROM sessions WHERE (status='online' AND last_seen_at<=?) OR (status='offline' AND offline_since<?) LIMIT 1",
            (timestamp - 90, timestamp - 86400),
        ).fetchone()
        if not due:
            return db.execute(
                "SELECT users.account, users.username FROM sessions JOIN users USING(account) WHERE token_hash=?",
                (token_hash,),
            ).fetchone()
    # Release the read snapshot before waiting for a writer: no lock upgrade.
    with connection(path, write=True) as db:
        maintain_sessions(db, timestamp)
        return db.execute(
            "SELECT users.account, users.username FROM sessions JOIN users USING(account) WHERE token_hash=?",
            (token_hash,),
        ).fetchone()


def heartbeat(path: Path, token_hash: str, now: float) -> bool:
    with connection(path, write=True) as db:
        maintain_sessions(db, now)
        return bool(
            db.execute(
                "UPDATE sessions SET last_seen_at=?, status='online', offline_since=NULL WHERE token_hash=?",
                (now, token_hash),
            ).rowcount
        )


def delete_session(path: Path, token_hash: str):
    with connection(path, write=True) as db:
        db.execute("DELETE FROM sessions WHERE token_hash=?", (token_hash,))


def get_profile(path: Path, account: str):
    with connection(path) as db:
        return db.execute(
            "SELECT account,username,signature,avatar_path,avatar_version FROM users WHERE account=?",
            (account,),
        ).fetchone()


def update_profile(path: Path, account: str, changes: dict):
    with connection(path, write=True) as db:
        for field in ("username", "signature"):
            if field in changes:
                db.execute(
                    f"UPDATE users SET {field}=? WHERE account=?",
                    (changes[field], account),
                )
