-- 删除事件说明及其旧内容，保留事件备注和其他业务数据。
ALTER TABLE events DROP COLUMN description;
