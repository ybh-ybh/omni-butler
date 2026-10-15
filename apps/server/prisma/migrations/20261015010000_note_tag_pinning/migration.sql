-- 置顶属于标签同步数据，历史记录和旧队列创建均默认未置顶。
ALTER TABLE taxonomy_entries
  ADD COLUMN is_pinned BOOLEAN NOT NULL DEFAULT false;
