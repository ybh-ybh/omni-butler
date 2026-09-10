-- PowerSync 独立状态库；业务库由 POSTGRES_DB 自动创建。
CREATE DATABASE powersync_storage OWNER omni_butler;

-- PowerSync 读取 PostgreSQL 逻辑复制流所需权限。
ALTER ROLE omni_butler WITH REPLICATION;
