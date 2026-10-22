-- 后台重复待办状态只保存在服务端，不加入 PowerSync 业务同步。
-- v3更换公开输入契约，旧待执行输入不再重新解释；历史回执与同步保护保留。
UPDATE "mcp_actions" SET "status" = 'cancelled', "updated_at" = CURRENT_TIMESTAMP
WHERE "status" IN ('pending', 'approved') AND "result" IS NULL;

CREATE TABLE "todo_recurrence_states" (
  "user_id" UUID NOT NULL PRIMARY KEY REFERENCES "sync_owners"("id") ON DELETE CASCADE,
  "status" VARCHAR(32) NOT NULL,
  "time_zone" TEXT,
  "reason" VARCHAR(80),
  "checked_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 每系列单独保存断点，防止新系列被同日旧操作回执跳过。
CREATE TABLE "todo_recurrence_cursors" (
  "user_id" UUID NOT NULL REFERENCES "sync_owners"("id") ON DELETE CASCADE,
  "series_id" UUID NOT NULL,
  "anchor_day" DATE NOT NULL,
  "next_day" DATE NOT NULL,
  "time_zone" TEXT NOT NULL,
  "schedule_signature" VARCHAR(32) NOT NULL,
  "error_code" VARCHAR(80),
  "retry_after" TIMESTAMPTZ(3),
  "updated_at" TIMESTAMPTZ(3) NOT NULL,
  PRIMARY KEY ("user_id", "series_id")
);
