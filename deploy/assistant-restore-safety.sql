-- 仅在停止API、恢复完整数据库和密钥卷后执行；本脚本不会删除聊天或业务正文。
-- 恢复的旧设备/MCP令牌不能重新获得执行资格，全部设备需要重新连接。
BEGIN;
UPDATE assistant_settings SET enabled=false, revision=revision+1, memory_version=memory_version+1;
UPDATE assistant_tasks SET status='cancelled', approved_hash=NULL
WHERE status IN ('queued','running','waitingConfirmation','waitingInput','submissionUnknown');
UPDATE assistant_runs SET status='cancelled', lease_owner=NULL, lease_until=NULL,
    error_code='ASSISTANT_RESTORE_INVALIDATED', error_message='备份恢复后的旧执行授权已失效，请重新发起任务'
WHERE status IN ('queued','running','waitingConfirmation','waitingInput','submissionUnknown');
UPDATE mcp_actions SET status='cancelled', updated_at=NOW()
WHERE status IN ('pending','approved');
UPDATE mcp_connections SET revoked_at=COALESCE(revoked_at,NOW());
DELETE FROM device_sessions;
DELETE FROM assistant_graph.checkpoint_writes;
DELETE FROM assistant_graph.checkpoint_blobs;
DELETE FROM assistant_graph.checkpoints;
COMMIT;
