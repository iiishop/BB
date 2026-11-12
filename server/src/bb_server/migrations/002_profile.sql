ALTER TABLE users ADD COLUMN signature TEXT CHECK(signature IS NULL OR length(signature) <= 49);
ALTER TABLE users ADD COLUMN avatar_path TEXT;
ALTER TABLE users ADD COLUMN avatar_version TEXT CHECK((avatar_path IS NULL) = (avatar_version IS NULL));
ALTER TABLE sessions ADD COLUMN last_seen_at REAL NOT NULL DEFAULT 0;
ALTER TABLE sessions ADD COLUMN status TEXT NOT NULL DEFAULT 'online' CHECK(status IN ('online', 'offline'));
ALTER TABLE sessions ADD COLUMN offline_since REAL;
UPDATE sessions SET last_seen_at = CAST(strftime('%s', 'now') AS REAL);
CREATE INDEX sessions_presence_idx ON sessions(last_seen_at);
