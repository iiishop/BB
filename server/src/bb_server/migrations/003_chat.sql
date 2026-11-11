CREATE TABLE media (
 id TEXT PRIMARY KEY, owner TEXT NOT NULL REFERENCES users(account), peer TEXT NOT NULL REFERENCES users(account),
 mime TEXT NOT NULL, kind TEXT NOT NULL, filename TEXT NOT NULL, size INTEGER NOT NULL CHECK(size>0),
 cover_id TEXT REFERENCES media(id)
);
CREATE TABLE messages (
 id TEXT PRIMARY KEY, pair_low TEXT NOT NULL REFERENCES users(account), pair_high TEXT NOT NULL REFERENCES users(account),
 position INTEGER NOT NULL CHECK(position>0), sender TEXT NOT NULL REFERENCES users(account), target TEXT NOT NULL REFERENCES users(account),
 created_at TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(pair_low,pair_high,position)
);
CREATE TABLE operations (
 account TEXT NOT NULL REFERENCES users(account), operation_id TEXT NOT NULL,
 request_hash TEXT NOT NULL, message_id TEXT NOT NULL REFERENCES messages(id), PRIMARY KEY(account,operation_id)
);
CREATE TABLE events (
 event_id INTEGER PRIMARY KEY AUTOINCREMENT, account TEXT NOT NULL REFERENCES users(account),
 message_id TEXT NOT NULL REFERENCES messages(id), peer TEXT NOT NULL REFERENCES users(account), position INTEGER NOT NULL, occurred_at TEXT NOT NULL,
 UNIQUE(account,message_id)
);
CREATE INDEX events_account_cursor ON events(account,event_id);
