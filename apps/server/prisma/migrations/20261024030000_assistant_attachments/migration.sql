-- 附件内容保存在私有对象存储；这里只保存授权、状态和稳定引用。
CREATE TABLE "assistant_attachments" (
  "id" UUID NOT NULL PRIMARY KEY,
  "user_id" UUID NOT NULL REFERENCES "sync_owners"("id") ON DELETE CASCADE,
  "conversation_id" UUID NOT NULL REFERENCES "assistant_conversations"("id") ON DELETE CASCADE,
  "session_id" UUID NOT NULL,
  "name" VARCHAR(180) NOT NULL,
  "mime_type" VARCHAR(120) NOT NULL,
  "size" INTEGER NOT NULL,
  "sha256" VARCHAR(64) NOT NULL,
  "kind" VARCHAR(16) NOT NULL,
  "status" VARCHAR(16) NOT NULL DEFAULT 'uploading',
  "requires_vision" BOOLEAN NOT NULL DEFAULT false,
  "object_key" VARCHAR(220) NOT NULL,
  "manifest_key" VARCHAR(220),
  "image_keys" JSONB,
  "chunk_count" INTEGER NOT NULL DEFAULT 0,
  "units" INTEGER NOT NULL DEFAULT 0,
  "error_code" VARCHAR(80),
  "lease_token" UUID,
  "lease_until" TIMESTAMPTZ(3),
  "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updated_at" TIMESTAMPTZ(3) NOT NULL
);
CREATE INDEX "assistant_attachments_user_id_conversation_id_created_at_idx" ON "assistant_attachments"("user_id", "conversation_id", "created_at");
CREATE INDEX "assistant_attachments_status_lease_until_idx" ON "assistant_attachments"("status", "lease_until");
CREATE TABLE "assistant_message_attachments" (
  "message_id" UUID NOT NULL REFERENCES "assistant_messages"("id") ON DELETE CASCADE,
  "attachment_id" UUID NOT NULL REFERENCES "assistant_attachments"("id") ON DELETE CASCADE,
  CONSTRAINT "assistant_message_attachments_pkey" PRIMARY KEY ("message_id", "attachment_id")
);
CREATE UNIQUE INDEX "assistant_message_attachments_attachment_id_key" ON "assistant_message_attachments"("attachment_id");
CREATE TABLE "assistant_attachment_gc" (
  "id" UUID NOT NULL PRIMARY KEY,
  "user_id" UUID NOT NULL,
  "attachment_id" UUID NOT NULL,
  "keys" JSONB NOT NULL,
  "attempts" INTEGER NOT NULL DEFAULT 0,
  "available_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX "assistant_attachment_gc_available_at_idx" ON "assistant_attachment_gc"("available_at");
