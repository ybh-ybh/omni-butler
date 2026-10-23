-- AlterTable
ALTER TABLE "mcp_actions" ADD COLUMN     "source" VARCHAR(16) NOT NULL DEFAULT 'mcp',
ADD COLUMN     "source_id" UUID,
ALTER COLUMN "connection_id" DROP NOT NULL;

-- CreateTable
CREATE TABLE "assistant_settings" (
    "user_id" UUID NOT NULL,
    "revision" INTEGER NOT NULL DEFAULT 0,
    "enabled" BOOLEAN NOT NULL DEFAULT false,
    "profile_id" UUID,
    "memory_read_enabled" BOOLEAN NOT NULL DEFAULT true,
    "memory_write_enabled" BOOLEAN NOT NULL DEFAULT true,
    "memory_version" INTEGER NOT NULL DEFAULT 0,
    "time_zone" VARCHAR(128) NOT NULL DEFAULT 'Asia/Shanghai',

    CONSTRAINT "assistant_settings_pkey" PRIMARY KEY ("user_id")
);

-- CreateTable
CREATE TABLE "assistant_conversations" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "title" VARCHAR(100) NOT NULL,
    "summary" TEXT NOT NULL DEFAULT '',
    "summary_through" TIMESTAMPTZ(3),
    "memory_version" INTEGER NOT NULL DEFAULT 0,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "assistant_conversations_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "assistant_tasks" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "conversation_id" UUID NOT NULL,
    "session_id" UUID NOT NULL,
    "run_id" UUID NOT NULL,
    "status" VARCHAR(32) NOT NULL DEFAULT 'queued',
    "plan_version" INTEGER NOT NULL DEFAULT 0,
    "plan" JSONB,
    "approved_hash" VARCHAR(64),
    "action_id" UUID,
    "plan_request_id" UUID,
    "committed" BOOLEAN NOT NULL DEFAULT false,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "assistant_tasks_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "assistant_runs" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "conversation_id" UUID NOT NULL,
    "task_id" UUID NOT NULL,
    "session_id" UUID NOT NULL,
    "status" VARCHAR(32) NOT NULL DEFAULT 'queued',
    "profile_snapshot" JSONB NOT NULL,
    "state" JSONB NOT NULL,
    "lease_owner" UUID,
    "lease_until" TIMESTAMPTZ(3),
    "event_sequence" INTEGER NOT NULL DEFAULT 0,
    "error_code" VARCHAR(80),
    "error_message" TEXT,
    "elapsed_ms" INTEGER NOT NULL DEFAULT 0,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "assistant_runs_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "assistant_messages" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "conversation_id" UUID NOT NULL,
    "task_id" UUID NOT NULL,
    "client_message_id" UUID,
    "role" VARCHAR(16) NOT NULL,
    "content" TEXT NOT NULL,
    "cards" JSONB NOT NULL,
    "excluded" BOOLEAN NOT NULL DEFAULT false,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "assistant_messages_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "assistant_events" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "run_id" UUID NOT NULL,
    "seq" INTEGER NOT NULL,
    "type" VARCHAR(40) NOT NULL,
    "data" JSONB NOT NULL,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "assistant_events_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "assistant_memories" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "content" VARCHAR(2000) NOT NULL,
    "category" VARCHAR(40) NOT NULL DEFAULT 'preference',
    "enabled" BOOLEAN NOT NULL DEFAULT true,
    "revision" INTEGER NOT NULL DEFAULT 0,
    "source_message_id" UUID,
    "expires_at" TIMESTAMPTZ(3),
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "assistant_memories_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "assistant_attempts" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "run_id" UUID NOT NULL,
    "ordinal" INTEGER NOT NULL,
    "input_hash" VARCHAR(64) NOT NULL,
    "status" VARCHAR(32) NOT NULL,
    "response" JSONB,
    "usage" JSONB,
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "assistant_attempts_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "assistant_conversations_user_id_updated_at_idx" ON "assistant_conversations"("user_id", "updated_at");

-- CreateIndex
CREATE INDEX "assistant_tasks_user_id_conversation_id_status_idx" ON "assistant_tasks"("user_id", "conversation_id", "status");

-- CreateIndex
CREATE INDEX "assistant_runs_status_lease_until_idx" ON "assistant_runs"("status", "lease_until");

-- CreateIndex
CREATE INDEX "assistant_runs_user_id_conversation_id_created_at_idx" ON "assistant_runs"("user_id", "conversation_id", "created_at");

-- CreateIndex
CREATE INDEX "assistant_messages_user_id_conversation_id_created_at_idx" ON "assistant_messages"("user_id", "conversation_id", "created_at");

-- CreateIndex
CREATE UNIQUE INDEX "assistant_messages_user_id_client_message_id_key" ON "assistant_messages"("user_id", "client_message_id");

-- CreateIndex
CREATE UNIQUE INDEX "assistant_events_run_id_seq_key" ON "assistant_events"("run_id", "seq");

-- CreateIndex
CREATE INDEX "assistant_memories_user_id_enabled_idx" ON "assistant_memories"("user_id", "enabled");

-- CreateIndex
CREATE UNIQUE INDEX "assistant_attempts_run_id_ordinal_key" ON "assistant_attempts"("run_id", "ordinal");

-- CreateIndex
CREATE UNIQUE INDEX "mcp_actions_source_source_id_request_id_key" ON "mcp_actions"("source", "source_id", "request_id");

-- AddForeignKey
ALTER TABLE "assistant_settings" ADD CONSTRAINT "assistant_settings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "sync_owners"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "assistant_conversations" ADD CONSTRAINT "assistant_conversations_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "sync_owners"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "assistant_tasks" ADD CONSTRAINT "assistant_tasks_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "sync_owners"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "assistant_runs" ADD CONSTRAINT "assistant_runs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "sync_owners"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "assistant_messages" ADD CONSTRAINT "assistant_messages_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "sync_owners"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "assistant_events" ADD CONSTRAINT "assistant_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "sync_owners"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "assistant_memories" ADD CONSTRAINT "assistant_memories_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "sync_owners"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "assistant_attempts" ADD CONSTRAINT "assistant_attempts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "sync_owners"("id") ON DELETE CASCADE ON UPDATE CASCADE;

UPDATE mcp_actions SET source_id=connection_id WHERE source='mcp';
ALTER TABLE mcp_actions ALTER COLUMN source_id SET NOT NULL;
ALTER TABLE mcp_actions ADD CONSTRAINT mcp_actions_source_scope CHECK ((source='mcp' AND connection_id IS NOT NULL AND source_id=connection_id) OR (source='assistant' AND connection_id IS NULL));
CREATE UNIQUE INDEX assistant_one_active_task ON assistant_tasks(user_id,conversation_id) WHERE status IN ('queued','running','waitingConfirmation','waitingInput','submissionUnknown');
-- LangGraph checkpoint schema pinned to checkpoint-postgres 1.1.2; no user authorization lives here.
CREATE SCHEMA assistant_graph;
CREATE TABLE assistant_graph.checkpoint_migrations (v INTEGER PRIMARY KEY);
INSERT INTO assistant_graph.checkpoint_migrations SELECT generate_series(0,5);
CREATE TABLE assistant_graph.checkpoints (thread_id TEXT NOT NULL, checkpoint_ns TEXT NOT NULL DEFAULT '', checkpoint_id TEXT NOT NULL, parent_checkpoint_id TEXT, type TEXT, checkpoint JSONB NOT NULL, metadata JSONB NOT NULL DEFAULT '{}', PRIMARY KEY(thread_id,checkpoint_ns,checkpoint_id));
CREATE TABLE assistant_graph.checkpoint_blobs (thread_id TEXT NOT NULL, checkpoint_ns TEXT NOT NULL DEFAULT '', channel TEXT NOT NULL, version TEXT NOT NULL, type TEXT NOT NULL, blob BYTEA, PRIMARY KEY(thread_id,checkpoint_ns,channel,version));
CREATE TABLE assistant_graph.checkpoint_writes (thread_id TEXT NOT NULL, checkpoint_ns TEXT NOT NULL DEFAULT '', checkpoint_id TEXT NOT NULL, task_id TEXT NOT NULL, idx INTEGER NOT NULL, channel TEXT NOT NULL, type TEXT, blob BYTEA NOT NULL, task_path TEXT NOT NULL DEFAULT '', PRIMARY KEY(thread_id,checkpoint_ns,checkpoint_id,task_id,idx));
