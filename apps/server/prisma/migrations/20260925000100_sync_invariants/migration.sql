-- 每日选择是可反复重选的日历槽位；删除名言只清空引用，不删除槽位或数据归属。
-- Prisma 尚不能表达复合外键 SET NULL 的列子集，此约束以迁移 SQL 为准。
ALTER TABLE daily_quote_selections DROP CONSTRAINT daily_quote_selections_user_id_quote_id_fkey;
ALTER TABLE daily_quote_selections ADD CONSTRAINT daily_quote_selections_user_id_quote_id_fkey
  FOREIGN KEY (user_id, quote_id) REFERENCES quotes(user_id, id)
  ON DELETE SET NULL (quote_id) ON UPDATE CASCADE;

-- 初始导入保留完整客户端事务，外键在事务结束时统一验证，允许子行先于父行出现。
DO $$
DECLARE
  -- 当前需要延迟检查的外键。
  foreign_key RECORD;
BEGIN
  FOR foreign_key IN
    SELECT conrelid::regclass AS table_name, conname
    FROM pg_constraint WHERE contype = 'f' AND connamespace = 'public'::regnamespace
  LOOP
    EXECUTE format('ALTER TABLE %s ALTER CONSTRAINT %I DEFERRABLE INITIALLY DEFERRED',
      foreign_key.table_name, foreign_key.conname);
  END LOOP;
END $$;

-- 使用 BIGINT 存储 Flutter 无符号 ARGB，但拒绝范围外的非法颜色。
ALTER TABLE taxonomy_entries ADD CONSTRAINT taxonomy_color_range
  CHECK (color_value IS NULL OR color_value BETWEEN 0 AND 4294967295);
ALTER TABLE todo_items ADD CONSTRAINT todo_parent_not_self CHECK (parent_id IS NULL OR parent_id <> id);

-- 包括外键级联删除在内的每一条实际删除都记录墓碑。
CREATE FUNCTION remember_sync_deletion() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM sync_owners WHERE id = OLD.user_id) THEN
    INSERT INTO sync_tombstones(user_id, table_name, record_id)
    VALUES (OLD.user_id, TG_TABLE_NAME, OLD.id)
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN OLD;
END $$;

DO $$
DECLARE
  -- 固定同步表白名单，不包含凭证和同步内部表。
  table_name TEXT;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'todo_items', 'quotes', 'daily_quote_selections', 'taxonomy_entries',
    'record_taxonomy_links', 'events', 'event_completions', 'inventory_items',
    'time_entries', 'memberships', 'membership_payments'
  ] LOOP
    EXECUTE format('CREATE TRIGGER sync_deletion_tombstone AFTER DELETE ON %I FOR EACH ROW EXECUTE FUNCTION remember_sync_deletion()', table_name);
  END LOOP;
END $$;
