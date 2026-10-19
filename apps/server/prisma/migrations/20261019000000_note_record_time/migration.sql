-- 记录时间与真实创建时间独立；旧记录保留空值，由创建事实确定显示默认值。
ALTER TABLE note_entries
  ADD COLUMN record_time_seconds INTEGER,
  ADD COLUMN record_utc_offset_minutes INTEGER;

-- 两个字段必须同时为空或同时有效，单次 UPDATE 保证时间组原子落库。
ALTER TABLE note_entries ADD CONSTRAINT note_entries_record_time_check CHECK (
  (record_time_seconds IS NULL AND record_utc_offset_minutes IS NULL)
  OR (record_time_seconds IS NOT NULL AND record_utc_offset_minutes IS NOT NULL
    AND record_time_seconds BETWEEN 0 AND 86399
    AND record_utc_offset_minutes BETWEEN -840 AND 840)
);
