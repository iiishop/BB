CREATE TABLE space_follows (
 account TEXT NOT NULL REFERENCES users(account),
 target_account TEXT NOT NULL REFERENCES users(account),
 PRIMARY KEY(account,target_account),
 CHECK(account != target_account)
);
CREATE TABLE space_follow_versions (
 account TEXT PRIMARY KEY REFERENCES users(account),
 revision INTEGER NOT NULL CHECK(revision > 0)
);
