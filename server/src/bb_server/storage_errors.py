"""Public storage failures and sanitized diagnostics (never exception text)."""

import logging
import sqlite3

logger = logging.getLogger(__name__)


def storage_failure(error, *, method="background", route="session_maintenance"):
    number = getattr(error, "sqlite_errorcode", None)
    primary = number & 255 if isinstance(number, int) else None
    if primary in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED):
        category, code = "busy", "storage_busy"
    elif isinstance(error, OSError) or primary in (
        sqlite3.SQLITE_IOERR,
        sqlite3.SQLITE_CANTOPEN,
        sqlite3.SQLITE_FULL,
        sqlite3.SQLITE_READONLY,
    ):
        category, code = "io", "storage_io_error"
    else:
        category, code = "other", "storage_unavailable"
    logger.warning(
        "storage_failure category=%s code=%s method=%s route=%s "
        "sqlite_code=%s errno=%s phase=%s attempts=%s wait_ms=%s",
        category,
        code,
        method,
        route,
        number,
        getattr(error, "errno", None),
        getattr(error, "storage_phase", "statement"),
        getattr(error, "storage_attempts", 1),
        getattr(error, "storage_wait_ms", None),
    )
    return code
