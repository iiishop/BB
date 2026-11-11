CREATE TABLE users (
    account TEXT PRIMARY KEY NOT NULL
        CHECK(length(account) = 8 AND account NOT GLOB '*[^0-9]*' AND substr(account,1,1) != '0'),
    username TEXT NOT NULL CHECK(length(username) BETWEEN 3 AND 24),
    password TEXT NOT NULL CHECK(password LIKE '$argon2id$%')
);
CREATE TABLE sessions (
    token_hash TEXT PRIMARY KEY NOT NULL
        CHECK(length(token_hash) = 64 AND token_hash NOT GLOB '*[^0-9a-f]*'),
    account TEXT NOT NULL REFERENCES users(account) ON DELETE CASCADE,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX sessions_account_idx ON sessions(account);
