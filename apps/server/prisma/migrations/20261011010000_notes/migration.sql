-- 笔记正文保留稳定修订身份，离线并发候选不覆盖已编辑文字。
CREATE TABLE note_entries (
 id UUID PRIMARY KEY, user_id UUID NOT NULL REFERENCES sync_owners(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
 body TEXT NOT NULL DEFAULT '', day_key VARCHAR(10) NOT NULL,
 category_id UUID, category_name VARCHAR(80), tags TEXT NOT NULL DEFAULT '[]', revision UUID NOT NULL,
 created_at TIMESTAMPTZ(3) NOT NULL, updated_at TIMESTAMPTZ(3) NOT NULL, deleted_at TIMESTAMPTZ(3),
 UNIQUE(user_id,id), CHECK (day_key ~ '^\d{4}-\d{2}-\d{2}$'),
 CHECK (jsonb_typeof(tags::jsonb) = 'array')
);
CREATE INDEX note_entries_user_id_day_key_idx ON note_entries(user_id,day_key);
CREATE TABLE note_versions (
 id UUID PRIMARY KEY, user_id UUID NOT NULL REFERENCES sync_owners(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
 note_id UUID NOT NULL, body TEXT NOT NULL, base_revision UUID NOT NULL, revision UUID NOT NULL,
 created_at TIMESTAMPTZ(3) NOT NULL, deleted_at TIMESTAMPTZ(3),
 FOREIGN KEY(user_id,note_id) REFERENCES note_entries(user_id,id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(user_id,note_id,revision)
);
CREATE INDEX note_versions_user_id_note_id_idx ON note_versions(user_id,note_id);
CREATE TABLE note_audio_segments (
 id UUID PRIMARY KEY, user_id UUID NOT NULL REFERENCES sync_owners(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
 note_id UUID NOT NULL, sort_order INTEGER NOT NULL, duration_ms INTEGER NOT NULL,
 mime VARCHAR(32) NOT NULL, sha256 VARCHAR(64) NOT NULL, byte_size INTEGER NOT NULL, transcript TEXT,
 created_at TIMESTAMPTZ(3) NOT NULL, updated_at TIMESTAMPTZ(3) NOT NULL, deleted_at TIMESTAMPTZ(3),
 UNIQUE(user_id,id), FOREIGN KEY(user_id,note_id) REFERENCES note_entries(user_id,id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
 CHECK(duration_ms BETWEEN 1 AND 1800000), CHECK(byte_size BETWEEN 1 AND 134217728),
 CHECK(sha256 ~ '^[a-f0-9]{64}$'), CHECK(mime IN ('audio/wav','audio/mp4','audio/mpeg','audio/aac','audio/ogg','audio/flac'))
);
CREATE INDEX note_audio_segments_user_id_note_id_sort_order_idx ON note_audio_segments(user_id,note_id,sort_order);
CREATE TABLE note_audio_assets (
 segment_id UUID PRIMARY KEY, user_id UUID NOT NULL REFERENCES sync_owners(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
 object_key TEXT NOT NULL UNIQUE,
 UNIQUE(user_id,segment_id),
 FOREIGN KEY(user_id,segment_id) REFERENCES note_audio_segments(user_id,id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE note_recognition_jobs (
 id UUID PRIMARY KEY, user_id UUID NOT NULL REFERENCES sync_owners(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
 segment_id UUID NOT NULL, provider VARCHAR(32) NOT NULL, model VARCHAR(64) NOT NULL, status VARCHAR(32) NOT NULL,
 provider_task_id VARCHAR(64), transcript TEXT, error_code VARCHAR(128),
 created_at TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
 next_poll_at TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
 FOREIGN KEY(user_id,segment_id) REFERENCES note_audio_segments(user_id,id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
 CHECK(status IN ('queued','submitting','processing','succeeded','failed','submissionUnknown','cancelled'))
);
CREATE INDEX note_recognition_jobs_user_id_segment_id_created_at_idx ON note_recognition_jobs(user_id,segment_id,created_at);
CREATE INDEX note_recognition_jobs_status_next_poll_at_idx ON note_recognition_jobs(status,next_poll_at);
-- 一个音频同时只有一个可执行识别任务。
CREATE UNIQUE INDEX note_recognition_one_active ON note_recognition_jobs(user_id,segment_id)
 WHERE status IN ('queued','submitting','processing','submissionUnknown');
CREATE TABLE note_audio_garbage(object_key TEXT PRIMARY KEY,due_at TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE note_audio_staging (
 migration_id UUID NOT NULL, segment_id UUID NOT NULL, sha256 VARCHAR(64) NOT NULL,
 byte_size INTEGER NOT NULL, mime VARCHAR(32) NOT NULL, object_key TEXT NOT NULL UNIQUE,
 created_at TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
 PRIMARY KEY(migration_id,segment_id)
);
-- 文件删除回执和元数据级联删除原子提交，包括重建归属。
CREATE FUNCTION queue_note_audio_garbage() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO note_audio_garbage(object_key) VALUES(OLD.object_key) ON CONFLICT(object_key) DO UPDATE SET due_at=CURRENT_TIMESTAMP;
 RETURN OLD;
END $$;
CREATE TRIGGER note_audio_cleanup AFTER DELETE ON note_audio_assets FOR EACH ROW EXECUTE FUNCTION queue_note_audio_garbage();
-- 迁移成功接管暂存对象时不清理已被新资产引用的文件。
CREATE FUNCTION queue_note_staging_garbage() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM note_audio_assets WHERE object_key=OLD.object_key) THEN
   INSERT INTO note_audio_garbage(object_key) VALUES(OLD.object_key) ON CONFLICT(object_key) DO UPDATE SET due_at=CURRENT_TIMESTAMP;
 END IF;
 RETURN OLD;
END $$;
CREATE TRIGGER note_staging_cleanup AFTER DELETE ON note_audio_staging FOR EACH ROW EXECUTE FUNCTION queue_note_staging_garbage();
CREATE TRIGGER sync_deletion_tombstone AFTER DELETE ON note_entries FOR EACH ROW EXECUTE FUNCTION remember_sync_deletion();
CREATE TRIGGER sync_deletion_tombstone AFTER DELETE ON note_versions FOR EACH ROW EXECUTE FUNCTION remember_sync_deletion();
CREATE TRIGGER sync_deletion_tombstone AFTER DELETE ON note_audio_segments FOR EACH ROW EXECUTE FUNCTION remember_sync_deletion();
ALTER PUBLICATION powersync ADD TABLE note_entries,note_versions,note_audio_segments;
