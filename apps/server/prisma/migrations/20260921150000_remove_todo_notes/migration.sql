-- 每日待办不再使用备注，旧备注数据直接丢弃。
ALTER TABLE "todo_items" DROP COLUMN "notes";
