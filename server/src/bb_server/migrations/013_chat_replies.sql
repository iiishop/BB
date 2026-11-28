CREATE TABLE chat_replies (
    message_id TEXT PRIMARY KEY NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    original_message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    CHECK(message_id != original_message_id)
);
CREATE INDEX chat_replies_original ON chat_replies(original_message_id, message_id);
