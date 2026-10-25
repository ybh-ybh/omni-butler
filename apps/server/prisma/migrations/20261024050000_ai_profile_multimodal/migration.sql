-- 已有配置默认关闭，旧图片探测结果不能代替用户开启多模态。
ALTER TABLE "ai_profiles" ADD COLUMN "multimodal" BOOLEAN NOT NULL DEFAULT false;
