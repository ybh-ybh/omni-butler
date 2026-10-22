-- 停止旧API接收请求后执行。只修复可明确解释的UUID误写，不推断旧象限4或冲突分类的真实意图。
BEGIN;

-- 名称字段确为同归属有效分类ID，且没有其他相矛盾的分类关系时，才纳入修复。
CREATE TEMP TABLE mcp_named_taxonomy_repairs ON COMMIT DROP AS
WITH inputs AS (
  SELECT item.id AS record_id, item.user_id, 'inventory'::text AS module,
         fields.kind, fields.label
  FROM inventory_items AS item
  CROSS JOIN LATERAL (VALUES ('category', item.category), ('location', item.location)) AS fields(kind, label)
  UNION ALL
  SELECT id, user_id, 'membership', 'category', category FROM memberships
)
SELECT input.record_id, input.user_id, input.module, input.kind,
       taxonomy.id AS taxonomy_id, taxonomy.name
FROM inputs AS input
JOIN taxonomy_entries AS taxonomy
  ON taxonomy.user_id = input.user_id
 AND taxonomy.module = input.module AND taxonomy.kind = input.kind
 AND taxonomy.id::text = lower(btrim(input.label))
 AND taxonomy.deleted_at IS NULL AND taxonomy.is_enabled = true
WHERE NOT EXISTS (
  SELECT 1 FROM record_taxonomy_links AS link
  JOIN taxonomy_entries AS old_taxonomy
    ON old_taxonomy.id = link.taxonomy_id AND old_taxonomy.user_id = link.user_id
  WHERE link.user_id = input.user_id AND link.module = input.module
    AND link.record_id = input.record_id AND link.deleted_at IS NULL
    AND old_taxonomy.kind = input.kind AND link.taxonomy_id <> taxonomy.id
);

UPDATE inventory_items AS item
SET category = repair.name, updated_at = CURRENT_TIMESTAMP
FROM mcp_named_taxonomy_repairs AS repair
WHERE repair.module = 'inventory' AND repair.kind = 'category'
  AND item.id = repair.record_id AND item.user_id = repair.user_id
  AND item.category IS DISTINCT FROM repair.name;

UPDATE inventory_items AS item
SET location = repair.name, updated_at = CURRENT_TIMESTAMP
FROM mcp_named_taxonomy_repairs AS repair
WHERE repair.module = 'inventory' AND repair.kind = 'location'
  AND item.id = repair.record_id AND item.user_id = repair.user_id
  AND item.location IS DISTINCT FROM repair.name;

UPDATE memberships AS member
SET category = repair.name, updated_at = CURRENT_TIMESTAMP
FROM mcp_named_taxonomy_repairs AS repair
WHERE repair.module = 'membership' AND member.id = repair.record_id
  AND member.user_id = repair.user_id AND member.category IS DISTINCT FROM repair.name;

-- 同时补齐规范关联，避免只修文字而让显示与筛选继续采用不同来源。
INSERT INTO record_taxonomy_links (id, user_id, module, record_id, taxonomy_id, created_at)
SELECT gen_random_uuid(), repair.user_id, repair.module, repair.record_id,
       repair.taxonomy_id, CURRENT_TIMESTAMP
FROM mcp_named_taxonomy_repairs AS repair
WHERE NOT EXISTS (
  SELECT 1 FROM record_taxonomy_links AS link
  WHERE link.user_id = repair.user_id AND link.module = repair.module
    AND link.record_id = repair.record_id AND link.taxonomy_id = repair.taxonomy_id
    AND link.deleted_at IS NULL
);

-- 物品tags是兼容文字；只替换能明确映射同归属有效分类/标签的UUID片段，保留其他内容和顺序。
WITH repaired_tags AS (
  SELECT item.id, item.user_id,
         string_agg(coalesce(taxonomy.name, part.label), ',' ORDER BY part.ordinality) AS tags
  FROM inventory_items AS item
  CROSS JOIN LATERAL unnest(string_to_array(item.tags, ',')) WITH ORDINALITY AS part(label, ordinality)
  LEFT JOIN taxonomy_entries AS taxonomy
    ON taxonomy.user_id = item.user_id AND taxonomy.module = 'inventory'
   AND taxonomy.kind IN ('category', 'tag') AND taxonomy.deleted_at IS NULL
   AND taxonomy.is_enabled = true AND taxonomy.id::text = lower(btrim(part.label))
  GROUP BY item.id, item.user_id
)
UPDATE inventory_items AS item
SET tags = repaired.tags, updated_at = CURRENT_TIMESTAMP
FROM repaired_tags AS repaired
WHERE item.id = repaired.id AND item.user_id = repaired.user_id
  AND item.tags IS DISTINCT FROM repaired.tags;

COMMIT;
