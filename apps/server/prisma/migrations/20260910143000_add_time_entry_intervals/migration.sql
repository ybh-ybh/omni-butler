-- 为跨天和进行中记录增加绝对时间字段。
ALTER TABLE "time_entries"
ADD COLUMN "started_at" TIMESTAMPTZ(3),
ADD COLUMN "ended_at" TIMESTAMPTZ(3);

-- 将历史自然日加分钟偏移回填为绝对时间，1440 分钟会自然进入下一天。
UPDATE "time_entries"
SET "started_at" = "entry_date"::timestamp + ("start_minute" * INTERVAL '1 minute'),
    "ended_at" = "entry_date"::timestamp + ("end_minute" * INTERVAL '1 minute');

-- 历史数据回填后，开始时间保持必填。
ALTER TABLE "time_entries"
ALTER COLUMN "started_at" SET NOT NULL,
ALTER COLUMN "activity" DROP NOT NULL;

-- 为按绝对时间查询周期记录增加索引。
CREATE INDEX "time_entries_user_id_started_at_idx"
ON "time_entries"("user_id", "started_at");
