ALTER TABLE "ai_profiles" ADD COLUMN "assistant_capabilities" JSONB;
CREATE TABLE "assistant_attempt_requests" (
  "id" UUID PRIMARY KEY,
  "attempt_id" UUID NOT NULL REFERENCES "assistant_attempts"("id") ON DELETE CASCADE,
  "index" INTEGER NOT NULL CHECK ("index" >= 0),
  "request_hash" VARCHAR(64) NOT NULL,
  "status" VARCHAR(32) NOT NULL,
  "failure" JSONB,
  "retry_at" TIMESTAMPTZ(3),
  "deadline_at" TIMESTAMPTZ(3) NOT NULL,
  "request" JSONB NOT NULL,
  "next_request" JSONB,
  "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updated_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX "assistant_attempt_requests_attempt_id_index_key" ON "assistant_attempt_requests"("attempt_id", "index");
