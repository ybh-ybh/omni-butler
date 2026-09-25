-- 复制发布属于数据库结构，由迁移创建；只发布客户端需要的业务表。
-- 会话摘要、回执和删除墓碑不进入 PowerSync 复制流。
DROP PUBLICATION IF EXISTS powersync;
CREATE PUBLICATION powersync FOR TABLE
  todo_items, quotes, daily_quote_selections, taxonomy_entries,
  record_taxonomy_links, events, event_completions, inventory_items,
  time_entries, memberships, membership_payments;
