-- 仅修复可明确归属的 UUID 误写；不猜测不存在、禁用、已删除或其他模块的分类。
-- 更新下行游标，使两端名称展示与分类统计同时恢复。
UPDATE time_entries AS record
SET category = taxonomy.name, updated_at = CURRENT_TIMESTAMP
FROM taxonomy_entries AS taxonomy
WHERE record.user_id = taxonomy.user_id
  AND lower(btrim(record.category)) = taxonomy.id::text
  AND taxonomy.module = 'timeline'
  AND taxonomy.kind = 'category'
  AND taxonomy.is_enabled = true
  AND taxonomy.deleted_at IS NULL
  AND record.category IS DISTINCT FROM taxonomy.name;
