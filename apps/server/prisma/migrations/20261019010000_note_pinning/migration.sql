-- 置顶只记录独立元数据；升级已有笔记保持正文、时间和版本事实不变。
ALTER TABLE note_entries ADD COLUMN is_pinned BOOLEAN NOT NULL DEFAULT false;
