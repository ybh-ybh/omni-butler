-- 在线业务回执与离线同步回执分开；不进入 PowerSync 发布。
CREATE TABLE business_operation_receipts (
  user_id UUID NOT NULL REFERENCES sync_owners(id) ON DELETE CASCADE,
  operation_id UUID NOT NULL,
  action VARCHAR(80) NOT NULL,
  payload_hash VARCHAR(64) NOT NULL,
  result JSONB NOT NULL,
  created_at TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, operation_id)
);

-- 多态业务引用没有 record_id 外键，永久删除时补齐关联清理与原有墓碑。
CREATE FUNCTION delete_business_taxonomy_links() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  -- 固定触发器参数指定业务模块，不接收客户端表名。
  business_module TEXT := TG_ARGV[0];
BEGIN
  DELETE FROM record_taxonomy_links
  WHERE user_id=OLD.user_id AND module=business_module AND record_id=OLD.id;
  RETURN OLD;
END $$;
CREATE TRIGGER inventory_taxonomy_cleanup AFTER DELETE ON inventory_items
  FOR EACH ROW EXECUTE FUNCTION delete_business_taxonomy_links('inventory');
CREATE TRIGGER time_taxonomy_cleanup AFTER DELETE ON time_entries
  FOR EACH ROW EXECUTE FUNCTION delete_business_taxonomy_links('timeline');
CREATE TRIGGER membership_taxonomy_cleanup AFTER DELETE ON memberships
  FOR EACH ROW EXECUTE FUNCTION delete_business_taxonomy_links('membership');

-- 修正既有孤立关系；软删除的业务记录仍存在，关系继续保留供恢复。
DELETE FROM record_taxonomy_links AS link
WHERE (link.module='inventory' AND NOT EXISTS (SELECT 1 FROM inventory_items item WHERE item.id=link.record_id AND item.user_id=link.user_id))
   OR (link.module='timeline' AND NOT EXISTS (SELECT 1 FROM time_entries item WHERE item.id=link.record_id AND item.user_id=link.user_id))
   OR (link.module='membership' AND NOT EXISTS (SELECT 1 FROM memberships item WHERE item.id=link.record_id AND item.user_id=link.user_id));
