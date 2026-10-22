-- 后台重复实例的同步保护是持久业务事实，不伪造 MCP 动作或幂等回执。
-- 只关联 owner：撤权、软删除或永久删除实例后仍保留，重建归属才清理。
CREATE TABLE "todo_recurrence_protections" (
  "user_id" UUID NOT NULL REFERENCES "sync_owners"("id") ON DELETE CASCADE,
  "todo_id" UUID NOT NULL,
  "protected_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY ("user_id", "todo_id")
);

-- 私有保护不加入 PowerSync 发布，不修改客户端同步结构或版本。
