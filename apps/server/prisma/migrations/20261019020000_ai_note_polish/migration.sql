-- 模型配置及任务为后端私有数据，不加入 PowerSync publication。
CREATE TABLE ai_settings (
  user_id UUID PRIMARY KEY REFERENCES sync_owners(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
  active_profile_id UUID,
  note_polish_enabled BOOLEAN NOT NULL DEFAULT false
);
CREATE TABLE ai_profiles (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES sync_owners(id) ON DELETE CASCADE,
  name VARCHAR(80) NOT NULL,
  provider VARCHAR(16) NOT NULL CHECK(provider IN ('zhipu', 'deepseek', 'custom')),
  base_url VARCHAR(2048) NOT NULL,
  model VARCHAR(128) NOT NULL,
  encrypted_api_key TEXT,
  revision INTEGER NOT NULL DEFAULT 1 CHECK(revision >= 1),
  created_at TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX ai_profiles_user_id_created_at_idx ON ai_profiles(user_id, created_at);
CREATE TABLE note_polish_jobs (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES sync_owners(id) ON DELETE CASCADE,
  segment_id UUID NOT NULL,
  recognition_id UUID NOT NULL REFERENCES note_recognition_jobs(id) ON DELETE CASCADE,
  attempt INTEGER NOT NULL DEFAULT 0 CHECK(attempt >= 0),
  enabled BOOLEAN NOT NULL,
  status VARCHAR(32) NOT NULL CHECK(status IN ('disabled', 'waiting', 'queued', 'processing', 'succeeded', 'failed', 'cancelled', 'submissionUnknown')),
  profile_id UUID,
  profile_revision INTEGER,
  provider VARCHAR(16),
  base_url TEXT,
  model VARCHAR(128),
  encrypted_api_key TEXT,
  prompt_version INTEGER NOT NULL DEFAULT 1,
  source_hash VARCHAR(64),
  text TEXT,
  error_code VARCHAR(128),
  created_at TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ(3) NOT NULL,
  FOREIGN KEY(user_id, segment_id) REFERENCES note_audio_segments(user_id, id) ON DELETE CASCADE
);
CREATE INDEX note_polish_jobs_recognition_lookup_idx ON note_polish_jobs(user_id, segment_id, recognition_id, created_at);
CREATE INDEX note_polish_jobs_status_created_at_idx ON note_polish_jobs(status, created_at);
CREATE UNIQUE INDEX note_polish_jobs_recognition_id_attempt_key ON note_polish_jobs(recognition_id, attempt);
