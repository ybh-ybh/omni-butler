-- 思考开关独立于多模态，任务按创建时配置固定请求模式。
ALTER TABLE "ai_profiles" ADD COLUMN "thinking_enabled" BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE "note_polish_jobs" ADD COLUMN "thinking_enabled" BOOLEAN NOT NULL DEFAULT false;
