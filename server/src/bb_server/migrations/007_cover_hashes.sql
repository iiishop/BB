DELETE FROM profile_cover_hashes;

INSERT INTO profile_cover_hashes (hash, cover_id)
SELECT cover_source_sha256(source), id FROM profile_covers;
