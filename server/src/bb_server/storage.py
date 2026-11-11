import secrets
import sqlite3
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
        if version > 1:
            raise RuntimeError("Database schema is newer than this server")
        if version == 0:
            sql = (Path(__file__).parent / "migrations" / "001_auth.sql").read_text(
                encoding="utf-8"
            )
            # execute each statement in the current transaction; executescript commits first.
            for statement in sql.split(";"):
                if statement.strip():
                    db.execute(statement)
            db.execute("PRAGMA user_version=1")


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


def insert_session(path: Path, account: str, token_hash: str):
    with connection(path) as db:
        db.execute(
            "INSERT INTO sessions(token_hash,account) VALUES (?,?)",
            (token_hash, account),
        )


def find_session(path: Path, token_hash: str):
    with connection(path) as db:
        return db.execute(
            "SELECT users.account, users.username FROM sessions JOIN users USING(account) WHERE token_hash=?",
            (token_hash,),
        ).fetchone()
