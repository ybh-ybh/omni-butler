-- 置顶仅是会话展示偏好，不修改历史活动时间。
ALTER TABLE "assistant_conversations"
ADD COLUMN "is_pinned" BOOLEAN NOT NULL DEFAULT false;

-- 稳定回答身份独立于可被遗忘操作清理的内部状态。
ALTER TABLE "assistant_runs"
ADD COLUMN "answer_message_id" UUID;

-- 只回填确实保存过的合法 UUID；已清理或不可恢复的历史保持 NULL。
UPDATE "assistant_runs"
SET "answer_message_id" = ("state" ->> 'messageId')::uuid
WHERE jsonb_typeof("state" -> 'messageId') = 'string'
  AND ("state" ->> 'messageId') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

CREATE INDEX "assistant_runs_user_id_conversation_id_answer_message_id_idx"
ON "assistant_runs"("user_id", "conversation_id", "answer_message_id");
