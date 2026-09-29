CREATE TABLE business_images (
  user_id uuid NOT NULL REFERENCES sync_owners(id) ON DELETE CASCADE,
  business_type varchar(32) NOT NULL CHECK (business_type IN ('inventoryImage', 'membershipImage')),
  business_id uuid NOT NULL,
  attachment_id uuid,
  revision uuid NOT NULL,
  object_key text UNIQUE,
  sha256 varchar(64),
  mime_type varchar(32),
  size_bytes integer,
  PRIMARY KEY (user_id, business_type, business_id),
  CHECK ((attachment_id IS NULL AND object_key IS NULL AND sha256 IS NULL AND mime_type IS NULL AND size_bytes IS NULL)
    OR (attachment_id IS NOT NULL AND object_key IS NOT NULL AND sha256 IS NOT NULL AND mime_type IS NOT NULL AND size_bytes > 0))
);
CREATE TABLE image_operation_receipts (
  user_id uuid NOT NULL REFERENCES sync_owners(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL,
  payload_hash varchar(64) NOT NULL,
  result jsonb NOT NULL,
  PRIMARY KEY (user_id, operation_id)
);
CREATE TABLE image_object_garbage (object_key text PRIMARY KEY, due_at timestamptz(3) NOT NULL);
CREATE INDEX image_object_garbage_due_at_idx ON image_object_garbage(due_at);

-- owner 级联删除和显式换图均先持久记录对象回收任务。
CREATE FUNCTION enqueue_image_object_garbage() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.object_key IS NOT NULL AND (TG_OP = 'DELETE' OR OLD.object_key IS DISTINCT FROM NEW.object_key) THEN
    INSERT INTO image_object_garbage(object_key, due_at) VALUES (OLD.object_key, now() + interval '1 hour')
    ON CONFLICT (object_key) DO NOTHING;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER business_image_garbage BEFORE DELETE OR UPDATE ON business_images
FOR EACH ROW EXECUTE FUNCTION enqueue_image_object_garbage();

-- 只响应物理删除；回收站软删除继续保留图片。
CREATE FUNCTION delete_business_image() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM business_images WHERE user_id = OLD.user_id AND business_id = OLD.id
    AND business_type = CASE WHEN TG_TABLE_NAME = 'inventory_items' THEN 'inventoryImage' ELSE 'membershipImage' END;
  RETURN OLD;
END $$;
CREATE TRIGGER inventory_image_delete AFTER DELETE ON inventory_items FOR EACH ROW EXECUTE FUNCTION delete_business_image();
CREATE TRIGGER membership_image_delete AFTER DELETE ON memberships FOR EACH ROW EXECUTE FUNCTION delete_business_image();
