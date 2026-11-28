CREATE TABLE chat_unread_alerts (
 account TEXT NOT NULL REFERENCES users(account),
 conversation_id TEXT NOT NULL,
 position INTEGER NOT NULL,
 mention INTEGER NOT NULL DEFAULT 0 CHECK(mention IN (0,1)),
 reply INTEGER NOT NULL DEFAULT 0 CHECK(reply IN (0,1)),
 CHECK(mention=1 OR reply=1),
 PRIMARY KEY(account,conversation_id,position),
 FOREIGN KEY(conversation_id,position)
  REFERENCES messages(conversation_id,position) ON DELETE CASCADE
);
CREATE INDEX chat_unread_alerts_message ON chat_unread_alerts(conversation_id,position);
