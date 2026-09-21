-- AlterTable
ALTER TABLE "todo_items" ADD COLUMN "parent_id" UUID;

-- CreateIndex
CREATE UNIQUE INDEX "todo_items_user_id_id_key" ON "todo_items"("user_id", "id");

-- CreateIndex
CREATE INDEX "todo_items_user_id_parent_id_sort_order_idx" ON "todo_items"("user_id", "parent_id", "sort_order");

-- CreateIndex
CREATE INDEX "todo_items_user_id_is_completed_completed_at_idx" ON "todo_items"("user_id", "is_completed", "completed_at");

-- AddForeignKey
ALTER TABLE "todo_items" ADD CONSTRAINT "todo_items_user_id_parent_id_fkey" FOREIGN KEY ("user_id", "parent_id") REFERENCES "todo_items"("user_id", "id") ON DELETE CASCADE ON UPDATE CASCADE;
