-- 永久连接以空到期日表达；保留现有连接原到期日。
ALTER TABLE mcp_connections ALTER COLUMN expires_at DROP NOT NULL;
