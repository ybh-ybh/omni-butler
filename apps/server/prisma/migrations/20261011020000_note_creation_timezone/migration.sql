-- 独立增量升级：历史TIMESTAMPTZ无法反推出原设备地区和偏移。
ALTER TABLE note_entries ADD COLUMN creation_timezone VARCHAR(128) NOT NULL DEFAULT 'legacy:unknown';
ALTER TABLE note_entries ADD CONSTRAINT note_creation_timezone_nonempty CHECK (length(trim(creation_timezone)) > 0);
-- 创建事实不随当前设备时区、正文编辑或回收站状态改变。
CREATE FUNCTION preserve_note_creation_timezone() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.creation_timezone IS DISTINCT FROM OLD.creation_timezone THEN
   RAISE EXCEPTION '笔记创建时区不可修改' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER note_creation_timezone_immutable BEFORE UPDATE ON note_entries FOR EACH ROW EXECUTE FUNCTION preserve_note_creation_timezone();
