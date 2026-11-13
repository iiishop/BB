CREATE TABLE administrator (
    id INTEGER PRIMARY KEY CHECK(id=1),
    password_hash TEXT NOT NULL,
    must_change_password INTEGER NOT NULL CHECK(must_change_password IN (0,1)),
    epoch INTEGER NOT NULL CHECK(epoch>=1)
);
CREATE TABLE admin_sessions (
    token_hash TEXT PRIMARY KEY,
    csrf_token TEXT NOT NULL,
    expires_at REAL NOT NULL
);
CREATE TABLE admin_attempts (
    id INTEGER PRIMARY KEY CHECK(id=1),
    window_start REAL NOT NULL,
    attempts INTEGER NOT NULL CHECK(attempts>=0)
);
