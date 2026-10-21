-- 复用既有同步回执保留冲突意图，不新增业务版本表或候选实体。
ALTER TABLE sync_receipts ADD COLUMN conflict JSONB;
-- MCP实际提交结果中的受影响记录形成持久保护范围，独立于连接是否已撤销。
CREATE INDEX mcp_actions_protected_records ON mcp_actions USING GIN ((result->'protectedRecords')) WHERE result IS NOT NULL;
