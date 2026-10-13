-- 类别行、关联、墓碑和删列必须一起提交，失败时保留升级前状态。
BEGIN;

-- 只删除笔记类别及其关联；其他模块类别和笔记标签保持不变。
-- 外键级联与现有删除触发器会为类别及关联留下永久墓碑。
DELETE FROM taxonomy_entries WHERE module = 'notes' AND kind = 'category';

-- 类别历史名称一并下线，正文、标签、时间、修订和原音均保持原值。
ALTER TABLE note_entries DROP COLUMN category_id, DROP COLUMN category_name;

-- 即使绕过应用入口也不能重新创建笔记类别。
ALTER TABLE taxonomy_entries ADD CONSTRAINT taxonomy_notes_category_retired
  CHECK (NOT (module = 'notes' AND kind = 'category'));

COMMIT;
