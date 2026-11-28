CREATE TABLE chat_group_create_operations (
 account TEXT NOT NULL REFERENCES users(account),
 operation_id TEXT NOT NULL,
 request_hash TEXT NOT NULL,
 conversation_id TEXT NOT NULL REFERENCES chat_groups(conversation_id),
 PRIMARY KEY(account,operation_id)
);

CREATE TABLE chat_group_join_requests (
 id TEXT PRIMARY KEY,
 conversation_id TEXT NOT NULL REFERENCES chat_groups(conversation_id),
 account TEXT NOT NULL REFERENCES users(account),
 state TEXT NOT NULL CHECK(state IN ('pending','accepted','rejected','invalidated'))
);
CREATE UNIQUE INDEX chat_group_join_pending ON chat_group_join_requests(conversation_id,account)
 WHERE state='pending';

CREATE TABLE bb_notices (
 sequence INTEGER PRIMARY KEY,
 id TEXT UNIQUE NOT NULL,
 recipient TEXT NOT NULL REFERENCES users(account),
 kind TEXT NOT NULL,
 title TEXT NOT NULL,
 text TEXT NOT NULL,
 created_at TEXT NOT NULL,
 link_type TEXT,
 link_id TEXT,
 request_id TEXT REFERENCES chat_group_join_requests(id),
 initiator TEXT REFERENCES users(account),
 is_read INTEGER NOT NULL DEFAULT 0 CHECK(is_read IN (0,1)),
 state TEXT NOT NULL CHECK(state IN ('informational','pending','processed','invalidated')),
 chosen_action TEXT,
 CHECK((link_type IS NULL) = (link_id IS NULL)),
 CHECK((state='processed') = (chosen_action IS NOT NULL))
);
CREATE INDEX bb_notices_recipient_sequence ON bb_notices(recipient,sequence);
CREATE INDEX bb_notices_recipient_pending ON bb_notices(recipient,sequence) WHERE state='pending';
CREATE INDEX bb_notices_recipient_unread ON bb_notices(recipient) WHERE is_read=0;
CREATE UNIQUE INDEX bb_notices_request_kind ON bb_notices(request_id,kind) WHERE request_id IS NOT NULL;

CREATE TABLE chat_media_gc (media_id TEXT PRIMARY KEY);

-- Notice delivery shares the durable, monotonically increasing chat event cursor.
ALTER TABLE events RENAME TO events_v9;
CREATE TABLE events (
 event_id INTEGER PRIMARY KEY AUTOINCREMENT,
 account TEXT NOT NULL REFERENCES users(account),
 message_id TEXT REFERENCES messages(id) ON DELETE CASCADE,
 conversation_id TEXT REFERENCES chat_conversations(id),
 peer TEXT REFERENCES users(account),
 position INTEGER,
 occurred_at TEXT NOT NULL,
 membership_revision INTEGER,
 active INTEGER CHECK(active IN (0,1)),
 notification_id TEXT UNIQUE REFERENCES bb_notices(id),
 CHECK(
   (notification_id IS NOT NULL AND conversation_id IS NULL AND message_id IS NULL
     AND peer IS NULL AND position IS NULL AND membership_revision IS NULL AND active IS NULL)
   OR (notification_id IS NULL AND conversation_id IS NOT NULL AND position IS NOT NULL AND (
      (peer IS NOT NULL AND message_id IS NOT NULL AND membership_revision IS NULL AND active IS NULL)
      OR (peer IS NULL AND membership_revision IS NOT NULL AND
         ((message_id IS NOT NULL AND active IS NULL) OR (message_id IS NULL AND active IS NOT NULL)))
   ))
 ),
 UNIQUE(account,message_id)
);
INSERT INTO events(event_id,account,message_id,conversation_id,peer,position,occurred_at,membership_revision,active)
 SELECT event_id,account,message_id,conversation_id,peer,position,occurred_at,membership_revision,active
 FROM events_v9;
INSERT INTO sqlite_sequence(name,seq)
 SELECT 'events',seq FROM sqlite_sequence
 WHERE name='events_v9' AND NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name='events');
UPDATE sqlite_sequence SET seq=MAX(seq,COALESCE(
 (SELECT seq FROM sqlite_sequence WHERE name='events_v9'),0)) WHERE name='events';
DROP TABLE events_v9;
CREATE INDEX events_account_cursor ON events(account,event_id);
CREATE INDEX events_message ON events(message_id);
