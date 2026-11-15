CREATE TABLE space_posts (
 id TEXT PRIMARY KEY, author TEXT NOT NULL REFERENCES users(account), created_at TEXT NOT NULL,
 text TEXT NOT NULL, reference_id TEXT REFERENCES space_posts(id), deleted INTEGER NOT NULL DEFAULT 0,
 seq INTEGER NOT NULL UNIQUE
);
CREATE INDEX space_posts_order ON space_posts(deleted,created_at DESC,id DESC);
CREATE INDEX space_posts_author_order ON space_posts(author,deleted,created_at DESC,id DESC);
CREATE INDEX space_posts_reference ON space_posts(reference_id,deleted);
CREATE TABLE space_drafts (
 id TEXT PRIMARY KEY, author TEXT NOT NULL REFERENCES users(account), created_at TEXT NOT NULL,
 version INTEGER NOT NULL, state TEXT NOT NULL CHECK(state IN ('draft','published','deleted')),
 text TEXT NOT NULL, reference_id TEXT REFERENCES space_posts(id), post_id TEXT REFERENCES space_posts(id)
);
CREATE INDEX space_drafts_owner ON space_drafts(author,state,created_at DESC,id DESC);
CREATE TABLE space_images (
 id TEXT PRIMARY KEY, blob TEXT NOT NULL, filename TEXT NOT NULL, mime TEXT NOT NULL, size INTEGER NOT NULL,
 draft_id TEXT REFERENCES space_drafts(id), post_id TEXT REFERENCES space_posts(id), position INTEGER NOT NULL,
 CHECK((draft_id IS NULL) != (post_id IS NULL))
);
CREATE INDEX space_images_draft ON space_images(draft_id,position);
CREATE INDEX space_images_post ON space_images(post_id,position);
CREATE INDEX space_images_blob ON space_images(blob);
CREATE TABLE space_gc (blob TEXT PRIMARY KEY);
CREATE TABLE space_comments (
 id TEXT PRIMARY KEY, post_id TEXT NOT NULL REFERENCES space_posts(id),
 author TEXT NOT NULL REFERENCES users(account), created_at TEXT NOT NULL, text TEXT,
 root_id TEXT NOT NULL, reply_to_id TEXT, deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX space_comments_roots ON space_comments(post_id,reply_to_id,created_at,id);
CREATE INDEX space_comments_branch ON space_comments(post_id,root_id,created_at,id);
CREATE TABLE space_likes (
 post_id TEXT NOT NULL REFERENCES space_posts(id), account TEXT NOT NULL REFERENCES users(account),
 active INTEGER NOT NULL, PRIMARY KEY(post_id,account)
);
CREATE TABLE space_reads (
 post_id TEXT NOT NULL REFERENCES space_posts(id), account TEXT NOT NULL REFERENCES users(account), PRIMARY KEY(post_id,account)
);
CREATE TABLE space_visits (
 account TEXT NOT NULL REFERENCES users(account), visit_id TEXT NOT NULL,
 post_id TEXT NOT NULL REFERENCES space_posts(id), PRIMARY KEY(account,visit_id)
);
CREATE INDEX space_visits_post ON space_visits(post_id);
CREATE TABLE space_visitors (
 post_id TEXT NOT NULL REFERENCES space_posts(id), account TEXT NOT NULL REFERENCES users(account),
 count INTEGER NOT NULL, last_visited_at TEXT NOT NULL, PRIMARY KEY(post_id,account)
);
CREATE TABLE space_notifications (
 id TEXT PRIMARY KEY, recipient TEXT NOT NULL REFERENCES users(account),
 kind TEXT NOT NULL CHECK(kind IN ('like','comment','reply','repost')),
 post_id TEXT NOT NULL REFERENCES space_posts(id), comment_id TEXT,
 target_post_id TEXT NOT NULL REFERENCES space_posts(id), actor TEXT NOT NULL REFERENCES users(account),
 version INTEGER NOT NULL, ack_version INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX space_like_notification ON space_notifications(recipient,post_id) WHERE kind='like';
CREATE INDEX space_notification_order ON space_notifications(recipient,created_at DESC,id DESC);
CREATE TABLE space_operations (
 account TEXT NOT NULL REFERENCES users(account), operation_id TEXT NOT NULL, request_hash TEXT NOT NULL,
 action TEXT NOT NULL, resource_id TEXT, resource_version INTEGER, PRIMARY KEY(account,operation_id)
);
CREATE TABLE space_events (
 event_id INTEGER PRIMARY KEY AUTOINCREMENT, recipient TEXT REFERENCES users(account),
 type TEXT NOT NULL, post_id TEXT, comment_id TEXT, notification_id TEXT, occurred_at TEXT NOT NULL
);
CREATE INDEX space_events_recipient ON space_events(recipient,event_id);
