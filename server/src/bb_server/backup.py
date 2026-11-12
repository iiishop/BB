"""Consistent SQLite backup to a new, explicitly selected local file."""

import argparse
import sqlite3
from pathlib import Path


def backup(source: Path, destination: Path):
    source = source.resolve(strict=True)
    # Exclusive creation prevents accidentally replacing a database or prior backup.
    with destination.open("xb"):
        pass
    try:
        destination.chmod(0o600)
        reader = sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)
        try:
            writer = sqlite3.connect(destination)
            try:
                reader.backup(writer)
                if writer.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise RuntimeError("Backup integrity check failed")
            finally:
                writer.close()
        finally:
            reader.close()
    except Exception:
        destination.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    backup(args.source, args.destination)


if __name__ == "__main__":
    main()
