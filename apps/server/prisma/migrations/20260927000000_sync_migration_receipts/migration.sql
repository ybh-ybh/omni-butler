-- 独立回执保留跨 owner 重建的幂等结果；不进入 PowerSync 发布。
CREATE TABLE sync_migration_receipts (
  migration_id UUID PRIMARY KEY,
  expected_owner_id UUID NOT NULL,
  owner_id UUID NOT NULL,
  payload_hash VARCHAR(64) NOT NULL,
  created_at TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);
