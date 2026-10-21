-- 部署时须先停止旧API接收请求；旧审批方案不能自动转成新流程执行授权。
UPDATE mcp_actions
SET status = 'cancelled', updated_at = CURRENT_TIMESTAMP
WHERE status IN ('pending', 'approved') AND result IS NULL;
