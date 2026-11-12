"""Opt-in test-process diagnostics. No SQL values, headers or credentials logged.

Enable only in an isolated test process via PYTHONPATH and BB_SQL_TRACE.
Uses the original SQLite timeout/transactions, without retry or SQL rewriting.
"""

import json
import os
import sqlite3
import sys
import threading
import time

_path = os.environ.get("BB_SQL_TRACE")


def emit(**entry):
    if _path:
        entry.update(
            pid=os.getpid(), thread=threading.get_ident(), at_ns=time.monotonic_ns()
        )
        fd = os.open(_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, (json.dumps(entry) + "\n").encode())
        finally:
            os.close(fd)


class TraceConnection(sqlite3.Connection):
    def execute(self, sql, *args, **kwargs):
        start = time.monotonic_ns()
        caller = sys._getframe(1).f_code.co_name
        error = None
        try:
            return super().execute(sql, *args, **kwargs)
        except sqlite3.Error as exc:
            error = getattr(exc, "sqlite_errorname", type(exc).__name__)
            raise
        finally:
            emit(
                kind="execute",
                connection=id(self),
                caller=caller,
                sql=sql,
                duration_ms=(time.monotonic_ns() - start) / 1e6,
                error=error,
                transaction=self.in_transaction,
            )

    def __exit__(self, *args):
        start = time.monotonic_ns()
        active = self.in_transaction
        error = None
        try:
            return super().__exit__(*args)
        except sqlite3.Error as exc:
            error = getattr(exc, "sqlite_errorname", type(exc).__name__)
            raise
        finally:
            emit(
                kind="transaction_exit",
                connection=id(self),
                active=active,
                rollback=args[0] is not None,
                duration_ms=(time.monotonic_ns() - start) / 1e6,
                error=error,
            )


if _path:
    _connect = sqlite3.connect

    def connect(*args, **kwargs):
        kwargs.setdefault("factory", TraceConnection)
        start = time.monotonic_ns()
        result = _connect(*args, **kwargs)
        emit(
            kind="connect",
            connection=id(result),
            timeout=kwargs.get("timeout", 5),
            duration_ms=(time.monotonic_ns() - start) / 1e6,
        )
        return result

    sqlite3.connect = connect
