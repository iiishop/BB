CREATE TABLE chat_conversations (
 id TEXT PRIMARY KEY,
 kind TEXT NOT NULL CHECK(kind IN ('direct','group')),
 direct_low TEXT REFERENCES users(account),
 direct_high TEXT REFERENCES users(account),
 last_position INTEGER NOT NULL DEFAULT 0 CHECK(last_position>=0),
 created_at TEXT NOT NULL,
 CHECK((kind='direct' AND direct_low IS NOT NULL AND direct_high IS NOT NULL
        AND id='dm:'||direct_low||':'||direct_high)
    OR (kind='group' AND direct_low IS NULL AND direct_high IS NULL)),
 UNIQUE(direct_low,direct_high)
);
CREATE INDEX chat_conversations_direct_high ON chat_conversations(direct_high,direct_low);
INSERT INTO chat_conversations(id,kind,direct_low,direct_high,last_position,created_at)
 SELECT 'dm:'||pair_low||':'||pair_high,'direct',pair_low,pair_high,MAX(position),MIN(created_at)
 FROM messages GROUP BY pair_low,pair_high;

CREATE TABLE chat_groups (
 conversation_id TEXT PRIMARY KEY REFERENCES chat_conversations(id),
 group_number TEXT UNIQUE NOT NULL CHECK(length(group_number)=8
     AND substr(group_number,1,1)!='0' AND group_number NOT GLOB '*[^0-9]*'),
 owner TEXT NOT NULL REFERENCES users(account),
 name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 80),
 description TEXT NOT NULL DEFAULT '',
 avatar_path TEXT,
 avatar_version TEXT,
 allow_member_invites INTEGER NOT NULL DEFAULT 0 CHECK(allow_member_invites IN (0,1)),
 status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','dissolved'))
);
CREATE TABLE chat_group_members (
 conversation_id TEXT NOT NULL REFERENCES chat_groups(conversation_id),
 account TEXT NOT NULL REFERENCES users(account),
 active INTEGER NOT NULL CHECK(active IN (0,1)),
 history_through INTEGER NOT NULL CHECK(history_through>=0),
 membership_revision INTEGER NOT NULL CHECK(membership_revision>0),
 PRIMARY KEY(conversation_id,account)
);
CREATE INDEX chat_group_members_account ON chat_group_members(account,active,conversation_id);

ALTER TABLE events RENAME TO events_v8;
ALTER TABLE operations RENAME TO operations_v8;
ALTER TABLE messages RENAME TO messages_v8;
ALTER TABLE media RENAME TO media_v8;
CREATE TABLE messages (
 id TEXT PRIMARY KEY,
 conversation_id TEXT NOT NULL REFERENCES chat_conversations(id),
 position INTEGER NOT NULL CHECK(position>0),
 sender TEXT REFERENCES users(account),
 created_at TEXT NOT NULL,
 payload TEXT NOT NULL,
 UNIQUE(conversation_id,position)
);
INSERT INTO messages
 SELECT id,'dm:'||pair_low||':'||pair_high,position,sender,created_at,payload FROM messages_v8;
CREATE TABLE operations (
 account TEXT NOT NULL REFERENCES users(account),
 operation_id TEXT NOT NULL,
 request_hash TEXT NOT NULL,
 message_id TEXT REFERENCES messages(id) ON DELETE SET NULL,
 PRIMARY KEY(account,operation_id)
);
INSERT INTO operations SELECT * FROM operations_v8;
CREATE INDEX operations_message ON operations(message_id);

CREATE TABLE events (
 event_id INTEGER PRIMARY KEY AUTOINCREMENT,
 account TEXT NOT NULL REFERENCES users(account),
 message_id TEXT REFERENCES messages(id) ON DELETE CASCADE,
 conversation_id TEXT NOT NULL REFERENCES chat_conversations(id),
 peer TEXT REFERENCES users(account),
 position INTEGER NOT NULL,
 occurred_at TEXT NOT NULL,
 membership_revision INTEGER,
 active INTEGER CHECK(active IN (0,1)),
 CHECK((peer IS NOT NULL AND message_id IS NOT NULL AND membership_revision IS NULL AND active IS NULL)
    OR (peer IS NULL AND membership_revision IS NOT NULL AND
       ((message_id IS NOT NULL AND active IS NULL) OR (message_id IS NULL AND active IS NOT NULL)))),
 UNIQUE(account,message_id)
);
INSERT INTO events(event_id,account,message_id,conversation_id,peer,position,occurred_at)
 SELECT e.event_id,e.account,e.message_id,m.conversation_id,e.peer,e.position,e.occurred_at
 FROM events_v8 e JOIN messages m ON m.id=e.message_id;
INSERT INTO sqlite_sequence(name,seq)
 SELECT 'events',seq FROM sqlite_sequence
 WHERE name='events_v8' AND NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name='events');
UPDATE sqlite_sequence SET seq=MAX(seq,COALESCE(
 (SELECT seq FROM sqlite_sequence WHERE name='events_v8'),0)) WHERE name='events';
DROP TABLE events_v8;
DROP TABLE operations_v8;
DROP TABLE messages_v8;
CREATE INDEX events_account_cursor ON events(account,event_id);
CREATE INDEX events_message ON events(message_id);

CREATE TABLE media (
 id TEXT PRIMARY KEY,
 owner TEXT NOT NULL REFERENCES users(account),
 peer TEXT REFERENCES users(account),
 mime TEXT NOT NULL,
 kind TEXT NOT NULL,
 filename TEXT NOT NULL,
 size INTEGER NOT NULL CHECK(size>0),
 cover_id TEXT REFERENCES media(id),
 group_id TEXT REFERENCES chat_groups(conversation_id),
 CHECK((peer IS NULL) != (group_id IS NULL))
);
INSERT INTO media(id,owner,peer,mime,kind,filename,size,cover_id)
 SELECT id,owner,peer,mime,kind,filename,size,cover_id FROM media_v8;
DROP TABLE media_v8;
CREATE INDEX media_group ON media(group_id);
CREATE INDEX media_cover ON media(cover_id);
CREATE TABLE chat_message_media (
 message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
 media_id TEXT NOT NULL REFERENCES media(id),
 PRIMARY KEY(message_id,media_id)
);
CREATE INDEX chat_message_media_by_media ON chat_message_media(media_id);
