"""Separate management store. All identity writes serialize here, not in BB users."""

import hashlib
import os
import secrets
from pathlib import Path

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from bb_auth_contract import ContractError
from bb_auth_contract.admin import SESSION_SECONDS, AdminSession

from bb_server.storage import connection

APPLICATION_ID = 0x42424144
ATTEMPT_LIMIT = 5
ATTEMPT_WINDOW = 60


def digest(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def unauthenticated():
    return ContractError(401, "unauthenticated", "请重新登录管理员账号")


class AdminStore:
    def __init__(self, path: Path, clock):
        self.path = path
        self.clock = clock
        self.hasher = PasswordHasher()

    def migrate(self):
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Create with private mode, rather than chmod after SQLite has written secrets.
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        os.close(fd)
        if os.name == "posix" and self.path.stat().st_mode & 0o077:
            raise RuntimeError("Management database must have mode 0600")
        with connection(self.path, write=True) as db:
            app_id = db.execute("PRAGMA application_id").fetchone()[0]
            version = db.execute("PRAGMA user_version").fetchone()[0]
            if app_id == APPLICATION_ID and version == 1:
                return
            if (
                app_id
                or version
                or db.execute("SELECT 1 FROM sqlite_schema").fetchone()
            ):
                raise RuntimeError("Not an empty or supported management database")
            sql = (Path(__file__).parent / "migrations/admin_001.sql").read_text(
                encoding="utf-8"
            )
            for statement in sql.split(";"):
                if statement.strip():
                    db.execute(statement)
            db.execute(
                "INSERT INTO administrator VALUES (1, ?, 1, 1)",
                (self.hasher.hash("admin"),),
            )
            db.execute("INSERT INTO admin_attempts VALUES (1, 0, 0)")
            db.execute(f"PRAGMA application_id={APPLICATION_ID}")
            db.execute("PRAGMA user_version=1")

    def _reserve_attempt(self, db, now):
        row = db.execute("SELECT * FROM admin_attempts WHERE id=1").fetchone()
        # A backwards wall-clock jump must not reset the attempt budget.
        if now >= row["window_start"] + ATTEMPT_WINDOW:
            db.execute(
                "UPDATE admin_attempts SET window_start=?, attempts=1 WHERE id=1",
                (now,),
            )
        elif row["attempts"] >= ATTEMPT_LIMIT:
            raise ContractError(429, "rate_limited", "尝试过于频繁，请稍后重试")
        else:
            db.execute("UPDATE admin_attempts SET attempts=attempts+1 WHERE id=1")

    def _session(self, db, token, now):
        row = db.execute(
            "SELECT s.*, a.must_change_password, a.password_hash, a.epoch "
            "FROM admin_sessions s JOIN administrator a ON a.id=1 "
            "WHERE s.token_hash=? AND s.expires_at>?",
            (digest(token), now),
        ).fetchone()
        if row is None:
            raise unauthenticated()
        return row

    @staticmethod
    def _response(row):
        return AdminSession(
            must_change_password=bool(row["must_change_password"]),
            csrf_token=row["csrf_token"],
            expires_at=row["expires_at"],
        )

    def session(self, token):
        with connection(self.path) as db:
            return self._response(self._session(db, token, self.clock()))

    def login(self, username, password):
        with connection(self.path, write=True) as db:
            self._reserve_attempt(db, self.clock())
            identity = db.execute("SELECT * FROM administrator WHERE id=1").fetchone()
        # Expensive verification outside the sole writer lock; recheck epoch at commit.
        try:
            valid = self.hasher.verify(identity["password_hash"], password)
        except VerifyMismatchError:
            valid = False
        if not valid or username != "admin":
            raise ContractError(401, "invalid_credentials", "管理员账号或密码错误")
        token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        with connection(self.path, write=True) as db:
            current = db.execute("SELECT * FROM administrator WHERE id=1").fetchone()
            if current["epoch"] != identity["epoch"]:
                raise unauthenticated()
            now = self.clock()
            db.execute("DELETE FROM admin_sessions WHERE expires_at<=?", (now,))
            db.execute(
                "INSERT INTO admin_sessions VALUES (?, ?, ?)",
                (digest(token), csrf, now + SESSION_SECONDS),
            )
            result = self._response(self._session(db, token, now))
        return token, result

    @staticmethod
    def _csrf(row, csrf):
        if not secrets.compare_digest(row["csrf_token"].encode(), csrf.encode()):
            raise ContractError(403, "csrf_rejected", "管理请求校验失败")

    def change_password(self, token, csrf, old_password, new_password):
        with connection(self.path, write=True) as db:
            identity = self._session(db, token, self.clock())
            self._csrf(identity, csrf)
            self._reserve_attempt(db, self.clock())
        try:
            self.hasher.verify(identity["password_hash"], old_password)
        except VerifyMismatchError:
            raise ContractError(403, "invalid_old_password", "原密码不正确") from None
        if new_password == old_password:
            raise ContractError(422, "password_unchanged", "新密码不能与原密码相同")
        password_hash = self.hasher.hash(new_password)
        with connection(self.path, write=True) as db:
            current = self._session(db, token, self.clock())
            self._csrf(current, csrf)
            if current["epoch"] != identity["epoch"]:
                raise unauthenticated()
            db.execute(
                "UPDATE administrator SET password_hash=?, must_change_password=0, epoch=epoch+1 WHERE id=1",
                (password_hash,),
            )
            db.execute("DELETE FROM admin_sessions")

    def logout(self, token, csrf):
        with connection(self.path, write=True) as db:
            row = self._session(db, token, self.clock())
            self._csrf(row, csrf)
            db.execute(
                "DELETE FROM admin_sessions WHERE token_hash=?", (digest(token),)
            )
