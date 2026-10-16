-- 共享列继续服务物品、时间和会员模块，只移除笔记标签的颜色数据。
UPDATE "taxonomy_entries"
SET "color_value" = NULL
WHERE "module" = 'notes' AND "kind" = 'tag';

-- 包含软删除的标签，阻止旧客户端或直接 SQL 重新写回颜色。
ALTER TABLE "taxonomy_entries"
ADD CONSTRAINT "note_tags_have_no_color"
CHECK ("module" <> 'notes' OR "kind" <> 'tag' OR "color_value" IS NULL);
