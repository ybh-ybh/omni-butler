-- 日历槽位的复合身份供映射外键校验所有者。
CREATE UNIQUE INDEX "daily_quote_selections_user_id_id_key"
  ON "daily_quote_selections" ("user_id", "id");

-- 保留不同设备曾使用的日签身份，确保后续更新能命中合并后的槽位。
CREATE TABLE "daily_quote_selection_aliases" (
  "user_id" UUID NOT NULL,
  "record_id" UUID NOT NULL,
  "selection_id" UUID NOT NULL,
  CONSTRAINT "daily_quote_selection_aliases_pkey" PRIMARY KEY ("user_id", "record_id"),
  CONSTRAINT "daily_quote_selection_aliases_user_id_fkey"
    FOREIGN KEY ("user_id") REFERENCES "sync_owners" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT "daily_quote_selection_aliases_user_id_selection_id_fkey"
    FOREIGN KEY ("user_id", "selection_id") REFERENCES "daily_quote_selections" ("user_id", "id") ON DELETE CASCADE ON UPDATE CASCADE
);

-- 支持槽位清理时查找其映射；该内部表不加入 PowerSync publication。
CREATE INDEX "daily_quote_selection_aliases_user_id_selection_id_idx"
  ON "daily_quote_selection_aliases" ("user_id", "selection_id");
