CREATE TABLE profile_covers (
    id INTEGER PRIMARY KEY,
    width INTEGER NOT NULL CHECK (width > 0),
    height INTEGER NOT NULL CHECK (height > 0),
    aspect REAL NOT NULL,
    tone INTEGER NOT NULL,
    signature BLOB NOT NULL,
    anchor BLOB NOT NULL,
    source BLOB NOT NULL,
    display BLOB,
    mime_type TEXT NOT NULL,
    version TEXT NOT NULL
);

CREATE INDEX profile_covers_aspect ON profile_covers(aspect, tone);

CREATE TABLE profile_cover_hashes (
    hash BLOB PRIMARY KEY,
    cover_id INTEGER NOT NULL REFERENCES profile_covers(id) ON DELETE CASCADE
);

CREATE INDEX profile_cover_hashes_cover ON profile_cover_hashes(cover_id);

CREATE TABLE account_covers (
    account TEXT PRIMARY KEY REFERENCES users(account) ON DELETE CASCADE,
    cover_id INTEGER NOT NULL REFERENCES profile_covers(id)
);

CREATE INDEX account_covers_cover ON account_covers(cover_id);
