-- 专用连接和待审批动作只存在服务端，不加入业务发布。
CREATE TABLE mcp_connections (
  id UUID PRIMARY KEY, user_id UUID NOT NULL REFERENCES sync_owners(id) ON DELETE CASCADE,
  name VARCHAR(100) NOT NULL, token_hash VARCHAR(64) NOT NULL UNIQUE,
  session_id UUID NOT NULL, read_modules TEXT[] NOT NULL, write_modules TEXT[] NOT NULL,
  time_zone TEXT, expires_at TIMESTAMPTZ(3) NOT NULL, revoked_at TIMESTAMPTZ(3),
  created_at TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE mcp_actions (
  id UUID PRIMARY KEY, user_id UUID NOT NULL REFERENCES sync_owners(id) ON DELETE CASCADE,
  connection_id UUID NOT NULL REFERENCES mcp_connections(id) ON DELETE CASCADE,
  request_id UUID NOT NULL, input_hash VARCHAR(64) NOT NULL,
  steps JSONB NOT NULL, baseline VARCHAR(64) NOT NULL, preview JSONB NOT NULL,
  approval_hash VARCHAR(64) NOT NULL, status VARCHAR(20) NOT NULL DEFAULT 'pending',
  approved_by UUID, approved_at TIMESTAMPTZ(3), result JSONB,
  expires_at TIMESTAMPTZ(3) NOT NULL, created_at TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(connection_id, request_id)
);
CREATE INDEX mcp_actions_owner_created ON mcp_actions(user_id, created_at);
