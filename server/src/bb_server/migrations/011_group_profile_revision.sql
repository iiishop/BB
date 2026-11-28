ALTER TABLE chat_groups ADD COLUMN profile_revision INTEGER NOT NULL DEFAULT 1 CHECK(profile_revision>0);
ALTER TABLE chat_groups ADD COLUMN invite_settings_revision INTEGER NOT NULL DEFAULT 1 CHECK(invite_settings_revision>0);
