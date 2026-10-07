-- 旧任务保持普通任务语义，不改变既有父子关系与完成状态。
ALTER TABLE todo_items
  ADD COLUMN task_type VARCHAR(16) NOT NULL DEFAULT 'normal',
  ADD COLUMN progress_unit VARCHAR(10),
  ADD CONSTRAINT todo_task_type_valid CHECK (task_type IN ('normal', 'progress')),
  ADD CONSTRAINT todo_progress_independent CHECK (
    task_type <> 'progress' OR
    (parent_id IS NULL AND repeat_rule IS NULL AND repeat_series_id IS NULL)
  );

-- 步骤不复用待办树，父任务软删除时保留步骤自身删除标记。
CREATE TABLE todo_progress_steps (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL,
  todo_id UUID NOT NULL,
  name VARCHAR(200),
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_completed BOOLEAN NOT NULL DEFAULT false,
  completed_at TIMESTAMPTZ(3),
  created_at TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ(3) NOT NULL,
  deleted_at TIMESTAMPTZ(3),
  CONSTRAINT todo_progress_steps_user_id_fkey FOREIGN KEY (user_id)
    REFERENCES sync_owners(id) ON DELETE CASCADE ON UPDATE CASCADE
    DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT todo_progress_steps_user_id_todo_id_fkey FOREIGN KEY (user_id, todo_id)
    REFERENCES todo_items(user_id, id) ON DELETE CASCADE ON UPDATE CASCADE
    DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX todo_progress_steps_user_id_todo_id_sort_order_idx
  ON todo_progress_steps(user_id, todo_id, sort_order);
CREATE INDEX todo_progress_steps_user_id_updated_at_idx
  ON todo_progress_steps(user_id, updated_at);

-- 级联删除同样记住步骤身份，拒绝旧设备迟到的重建请求。
CREATE TRIGGER sync_deletion_tombstone AFTER DELETE ON todo_progress_steps
  FOR EACH ROW EXECUTE FUNCTION remember_sync_deletion();
ALTER PUBLICATION powersync ADD TABLE todo_progress_steps;
