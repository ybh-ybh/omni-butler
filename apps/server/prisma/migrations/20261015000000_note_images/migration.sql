-- 每张图片使用独立业务槽位；正文版本与图片增删互不覆盖。
CREATE TABLE note_images (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES sync_owners(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  note_id UUID NOT NULL,
  sort_order INTEGER NOT NULL CHECK (sort_order >= 0),
  created_at TIMESTAMPTZ(3) NOT NULL,
  updated_at TIMESTAMPTZ(3) NOT NULL,
  deleted_at TIMESTAMPTZ(3),
  FOREIGN KEY(user_id,note_id) REFERENCES note_entries(user_id,id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX note_images_user_id_note_id_sort_order_idx ON note_images(user_id,note_id,sort_order);
ALTER TABLE business_images DROP CONSTRAINT business_images_business_type_check;
ALTER TABLE business_images ADD CONSTRAINT business_images_business_type_check
  CHECK (business_type IN ('inventoryImage','membershipImage','noteImage'));
-- 软删保留原件；永久删除登记墓碑并通过已有队列回收对象。
CREATE FUNCTION delete_note_image() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM business_images WHERE user_id=OLD.user_id AND business_type='noteImage' AND business_id=OLD.id;
  RETURN OLD;
END $$;
CREATE TRIGGER note_image_delete AFTER DELETE ON note_images FOR EACH ROW EXECUTE FUNCTION delete_note_image();
CREATE TRIGGER sync_deletion_tombstone AFTER DELETE ON note_images FOR EACH ROW EXECUTE FUNCTION remember_sync_deletion();
ALTER PUBLICATION powersync ADD TABLE note_images;
