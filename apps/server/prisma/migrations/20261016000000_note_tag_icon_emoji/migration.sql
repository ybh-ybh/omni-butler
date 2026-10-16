-- 图标是可空完整 Unicode 文字，增量升级仅为历史标签补空值。
ALTER TABLE taxonomy_entries
  ADD COLUMN icon_emoji TEXT;
