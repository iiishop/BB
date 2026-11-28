"""Durable reclamation of chat media after a group is dissolved."""

import logging
import os
import re

from .storage import connection

logger = logging.getLogger(__name__)


def release(db):
    # A cover can outlive the group that uploaded it while another conversation
    # references it. Reconsider those covers after each group deletion.
    removed = db.execute(
        """WITH RECURSIVE retired(id) AS (
            SELECT m.id FROM chat_groups g JOIN media m ON m.group_id=g.conversation_id
            WHERE g.status='dissolved'
        ), kept(id) AS (
            SELECT r.id FROM retired r WHERE (
                EXISTS(SELECT 1 FROM chat_message_media x WHERE x.media_id=r.id)
                OR EXISTS(SELECT 1 FROM media v WHERE v.cover_id=r.id
                    AND NOT EXISTS(SELECT 1 FROM retired WHERE id=v.id))
            )
            UNION
            SELECT m.cover_id FROM media m JOIN kept k ON k.id=m.id
            WHERE m.cover_id IS NOT NULL
        )
        DELETE FROM media WHERE id IN (
            SELECT id FROM retired WHERE id NOT IN (SELECT id FROM kept)
        ) RETURNING id"""
    ).fetchall()
    db.executemany(
        "INSERT INTO chat_media_gc(media_id) VALUES (?) ON CONFLICT DO NOTHING",
        removed,
    )


def collect(path, directory):
    with connection(path) as db:
        if db.execute("SELECT 1 FROM chat_media_gc LIMIT 1").fetchone() is None:
            return
    with connection(path, write=True) as db:
        for (media_id,) in db.execute("SELECT media_id FROM chat_media_gc").fetchall():
            if not re.fullmatch(r"[a-f0-9]{32}", media_id):
                logger.error("chat_media_gc_invalid_key")
                continue
            live = db.execute("SELECT 1 FROM media WHERE id=?", (media_id,)).fetchone()
            if not live:
                try:
                    (directory / media_id).unlink(missing_ok=True)
                    thumbs = directory / "derivatives" / "thumb-v1"
                    (thumbs / (media_id + ".jpg")).unlink(missing_ok=True)
                    for leftover in thumbs.glob(media_id + ".*.tmp"):
                        leftover.unlink(missing_ok=True)
                    if os.name == "posix":
                        for parent in (directory, thumbs):
                            if parent.is_dir():
                                descriptor = os.open(
                                    parent, os.O_RDONLY | os.O_DIRECTORY
                                )
                                try:
                                    os.fsync(descriptor)
                                finally:
                                    os.close(descriptor)
                except OSError:
                    logger.warning("chat_media_gc_retry")
                    continue
            db.execute("DELETE FROM chat_media_gc WHERE media_id=?", (media_id,))
