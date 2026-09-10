ALTER TABLE "todo_items"
RENAME COLUMN "urgency" TO "priority_quadrant";

ALTER TABLE "todo_items"
ALTER COLUMN "priority_quadrant" SET DEFAULT 2;
