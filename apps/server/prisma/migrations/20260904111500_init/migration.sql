-- CreateSchema
CREATE SCHEMA IF NOT EXISTS "public";

-- CreateTable
CREATE TABLE "users" (
    "id" UUID NOT NULL,
    "email" VARCHAR(320) NOT NULL,
    "password_hash" TEXT NOT NULL,
    "role" VARCHAR(16) NOT NULL DEFAULT 'USER',
    "token_version" INTEGER NOT NULL DEFAULT 0,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "users_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "refresh_tokens" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "token_hash" TEXT NOT NULL,
    "expires_at" TIMESTAMPTZ(3) NOT NULL,
    "revoked_at" TIMESTAMPTZ(3),
    "replaced_by_id" UUID,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "refresh_tokens_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "todo_items" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "title" VARCHAR(200) NOT NULL,
    "description" TEXT,
    "scheduled_date" DATE NOT NULL,
    "due_at" TIMESTAMPTZ(3),
    "urgency" INTEGER NOT NULL DEFAULT 1,
    "is_completed" BOOLEAN NOT NULL DEFAULT false,
    "completed_at" TIMESTAMPTZ(3),
    "reminder_at" TIMESTAMPTZ(3),
    "repeat_rule" VARCHAR(16),
    "repeat_series_id" UUID,
    "sort_order" INTEGER NOT NULL DEFAULT 0,
    "notes" TEXT,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,
    "deleted_at" TIMESTAMPTZ(3),

    CONSTRAINT "todo_items_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "quotes" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "content" TEXT NOT NULL,
    "source" TEXT,
    "is_enabled" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,
    "deleted_at" TIMESTAMPTZ(3),

    CONSTRAINT "quotes_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "daily_quote_selections" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "day_key" VARCHAR(10) NOT NULL,
    "quote_id" UUID NOT NULL,
    "is_manual" BOOLEAN NOT NULL DEFAULT false,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "daily_quote_selections_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "banner_settings" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "key" VARCHAR(64) NOT NULL,
    "attachment_id" UUID,
    "overlay_strength" DOUBLE PRECISION NOT NULL DEFAULT 0.45,
    "text_color_value" INTEGER,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "banner_settings_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "attachments" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "business_type" VARCHAR(32) NOT NULL,
    "business_id" UUID NOT NULL,
    "object_key" TEXT,
    "mime_type" VARCHAR(128),
    "size_bytes" INTEGER,
    "sha256" VARCHAR(64),
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,
    "deleted_at" TIMESTAMPTZ(3),

    CONSTRAINT "attachments_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "taxonomy_entries" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "module" VARCHAR(24) NOT NULL,
    "kind" VARCHAR(16) NOT NULL,
    "name" VARCHAR(80) NOT NULL,
    "normalized_name" VARCHAR(80) NOT NULL,
    "color_value" INTEGER,
    "icon_code_point" INTEGER,
    "sort_order" INTEGER NOT NULL DEFAULT 0,
    "is_enabled" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,
    "deleted_at" TIMESTAMPTZ(3),

    CONSTRAINT "taxonomy_entries_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "record_taxonomy_links" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "module" VARCHAR(24) NOT NULL,
    "record_id" UUID NOT NULL,
    "taxonomy_id" UUID NOT NULL,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "deleted_at" TIMESTAMPTZ(3),

    CONSTRAINT "record_taxonomy_links_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "events" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "name" VARCHAR(200) NOT NULL,
    "category" TEXT,
    "description" TEXT,
    "interval_value" INTEGER NOT NULL DEFAULT 1,
    "interval_unit" VARCHAR(16) NOT NULL DEFAULT 'month',
    "last_completed_at" TIMESTAMPTZ(3),
    "reminder_enabled" BOOLEAN NOT NULL DEFAULT false,
    "reminder_days_before" INTEGER NOT NULL DEFAULT 0,
    "reminder_time_minutes" INTEGER NOT NULL DEFAULT 540,
    "is_archived" BOOLEAN NOT NULL DEFAULT false,
    "archived_at" TIMESTAMPTZ(3),
    "notes" TEXT,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,
    "deleted_at" TIMESTAMPTZ(3),

    CONSTRAINT "events_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "event_completions" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "event_id" UUID NOT NULL,
    "completed_at" TIMESTAMPTZ(3) NOT NULL,
    "notes" TEXT,
    "source" VARCHAR(24) NOT NULL DEFAULT 'manual',
    "is_revoked" BOOLEAN NOT NULL DEFAULT false,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "deleted_at" TIMESTAMPTZ(3),

    CONSTRAINT "event_completions_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "inventory_items" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "name" VARCHAR(200) NOT NULL,
    "category" TEXT,
    "brand" TEXT,
    "model" TEXT,
    "quantity" INTEGER NOT NULL DEFAULT 1,
    "purchase_price_cents" INTEGER,
    "purchase_date" DATE,
    "location" TEXT,
    "purchase_url" TEXT,
    "status" VARCHAR(24) NOT NULL DEFAULT 'inUse',
    "warranty_expiration" DATE,
    "tags" TEXT,
    "parent_item_id" UUID,
    "notes" TEXT,
    "image_attachment_id" UUID,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,
    "deleted_at" TIMESTAMPTZ(3),

    CONSTRAINT "inventory_items_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "time_entries" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "entry_date" DATE NOT NULL,
    "start_minute" INTEGER NOT NULL,
    "end_minute" INTEGER NOT NULL,
    "activity" VARCHAR(200) NOT NULL,
    "category" TEXT,
    "notes" TEXT,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,
    "deleted_at" TIMESTAMPTZ(3),

    CONSTRAINT "time_entries_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "memberships" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "name" VARCHAR(200) NOT NULL,
    "provider" TEXT,
    "category" TEXT,
    "description" TEXT,
    "website_url" TEXT,
    "purchase_platform" TEXT,
    "payment_method" TEXT,
    "price_cents" INTEGER NOT NULL DEFAULT 0,
    "billing_cycle" VARCHAR(24) NOT NULL DEFAULT 'year',
    "base_status" VARCHAR(24) NOT NULL DEFAULT 'active',
    "purchase_date" DATE NOT NULL,
    "expiration_date" DATE,
    "is_permanent" BOOLEAN NOT NULL DEFAULT false,
    "auto_renew" BOOLEAN NOT NULL DEFAULT false,
    "renewal_date" DATE,
    "is_favorite" BOOLEAN NOT NULL DEFAULT false,
    "needs_renewal" BOOLEAN NOT NULL DEFAULT false,
    "expiration_reminder_enabled" BOOLEAN NOT NULL DEFAULT false,
    "expiration_reminder_days" INTEGER NOT NULL DEFAULT 30,
    "renewal_reminder_enabled" BOOLEAN NOT NULL DEFAULT false,
    "renewal_reminder_days" INTEGER NOT NULL DEFAULT 7,
    "reminder_time_minutes" INTEGER NOT NULL DEFAULT 540,
    "cancel_guide" TEXT,
    "notes" TEXT,
    "image_attachment_id" UUID,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,
    "deleted_at" TIMESTAMPTZ(3),

    CONSTRAINT "memberships_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "membership_payments" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "membership_id" UUID NOT NULL,
    "amount_cents" INTEGER NOT NULL,
    "billing_cycle" VARCHAR(24),
    "paid_at" TIMESTAMPTZ(3) NOT NULL,
    "valid_from" DATE,
    "valid_until" DATE,
    "notes" TEXT,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "deleted_at" TIMESTAMPTZ(3),

    CONSTRAINT "membership_payments_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "users_email_key" ON "users"("email");

-- CreateIndex
CREATE INDEX "refresh_tokens_user_id_expires_at_idx" ON "refresh_tokens"("user_id", "expires_at");

-- CreateIndex
CREATE INDEX "todo_items_user_id_scheduled_date_idx" ON "todo_items"("user_id", "scheduled_date");

-- CreateIndex
CREATE INDEX "todo_items_user_id_updated_at_idx" ON "todo_items"("user_id", "updated_at");

-- CreateIndex
CREATE INDEX "quotes_user_id_updated_at_idx" ON "quotes"("user_id", "updated_at");

-- CreateIndex
CREATE UNIQUE INDEX "quotes_user_id_id_key" ON "quotes"("user_id", "id");

-- CreateIndex
CREATE INDEX "daily_quote_selections_user_id_updated_at_idx" ON "daily_quote_selections"("user_id", "updated_at");

-- CreateIndex
CREATE UNIQUE INDEX "daily_quote_selections_user_id_day_key_key" ON "daily_quote_selections"("user_id", "day_key");

-- CreateIndex
CREATE UNIQUE INDEX "banner_settings_user_id_key_key" ON "banner_settings"("user_id", "key");

-- CreateIndex
CREATE INDEX "attachments_user_id_business_type_business_id_idx" ON "attachments"("user_id", "business_type", "business_id");

-- CreateIndex
CREATE INDEX "attachments_user_id_updated_at_idx" ON "attachments"("user_id", "updated_at");

-- CreateIndex
CREATE INDEX "taxonomy_entries_user_id_updated_at_idx" ON "taxonomy_entries"("user_id", "updated_at");

-- CreateIndex
CREATE UNIQUE INDEX "taxonomy_entries_user_id_id_key" ON "taxonomy_entries"("user_id", "id");

-- CreateIndex
CREATE UNIQUE INDEX "taxonomy_entries_user_id_module_kind_normalized_name_key" ON "taxonomy_entries"("user_id", "module", "kind", "normalized_name");

-- CreateIndex
CREATE INDEX "record_taxonomy_links_user_id_module_record_id_idx" ON "record_taxonomy_links"("user_id", "module", "record_id");

-- CreateIndex
CREATE INDEX "record_taxonomy_links_taxonomy_id_idx" ON "record_taxonomy_links"("taxonomy_id");

-- CreateIndex
CREATE INDEX "events_user_id_updated_at_idx" ON "events"("user_id", "updated_at");

-- CreateIndex
CREATE UNIQUE INDEX "events_user_id_id_key" ON "events"("user_id", "id");

-- CreateIndex
CREATE INDEX "event_completions_user_id_event_id_completed_at_idx" ON "event_completions"("user_id", "event_id", "completed_at");

-- CreateIndex
CREATE INDEX "inventory_items_user_id_parent_item_id_idx" ON "inventory_items"("user_id", "parent_item_id");

-- CreateIndex
CREATE INDEX "inventory_items_user_id_updated_at_idx" ON "inventory_items"("user_id", "updated_at");

-- CreateIndex
CREATE UNIQUE INDEX "inventory_items_user_id_id_key" ON "inventory_items"("user_id", "id");

-- CreateIndex
CREATE INDEX "time_entries_user_id_entry_date_idx" ON "time_entries"("user_id", "entry_date");

-- CreateIndex
CREATE INDEX "time_entries_user_id_updated_at_idx" ON "time_entries"("user_id", "updated_at");

-- CreateIndex
CREATE INDEX "memberships_user_id_expiration_date_idx" ON "memberships"("user_id", "expiration_date");

-- CreateIndex
CREATE INDEX "memberships_user_id_updated_at_idx" ON "memberships"("user_id", "updated_at");

-- CreateIndex
CREATE UNIQUE INDEX "memberships_user_id_id_key" ON "memberships"("user_id", "id");

-- CreateIndex
CREATE INDEX "membership_payments_user_id_membership_id_paid_at_idx" ON "membership_payments"("user_id", "membership_id", "paid_at");

-- AddForeignKey
ALTER TABLE "refresh_tokens" ADD CONSTRAINT "refresh_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "todo_items" ADD CONSTRAINT "todo_items_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "quotes" ADD CONSTRAINT "quotes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "daily_quote_selections" ADD CONSTRAINT "daily_quote_selections_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "daily_quote_selections" ADD CONSTRAINT "daily_quote_selections_user_id_quote_id_fkey" FOREIGN KEY ("user_id", "quote_id") REFERENCES "quotes"("user_id", "id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "banner_settings" ADD CONSTRAINT "banner_settings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "attachments" ADD CONSTRAINT "attachments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "taxonomy_entries" ADD CONSTRAINT "taxonomy_entries_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "record_taxonomy_links" ADD CONSTRAINT "record_taxonomy_links_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "record_taxonomy_links" ADD CONSTRAINT "record_taxonomy_links_user_id_taxonomy_id_fkey" FOREIGN KEY ("user_id", "taxonomy_id") REFERENCES "taxonomy_entries"("user_id", "id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "events" ADD CONSTRAINT "events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "event_completions" ADD CONSTRAINT "event_completions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "event_completions" ADD CONSTRAINT "event_completions_user_id_event_id_fkey" FOREIGN KEY ("user_id", "event_id") REFERENCES "events"("user_id", "id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "inventory_items" ADD CONSTRAINT "inventory_items_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "inventory_items" ADD CONSTRAINT "inventory_items_user_id_parent_item_id_fkey" FOREIGN KEY ("user_id", "parent_item_id") REFERENCES "inventory_items"("user_id", "id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "time_entries" ADD CONSTRAINT "time_entries_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "memberships" ADD CONSTRAINT "memberships_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "membership_payments" ADD CONSTRAINT "membership_payments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "membership_payments" ADD CONSTRAINT "membership_payments_user_id_membership_id_fkey" FOREIGN KEY ("user_id", "membership_id") REFERENCES "memberships"("user_id", "id") ON DELETE CASCADE ON UPDATE CASCADE;
