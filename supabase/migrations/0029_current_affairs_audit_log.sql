-- 0029_current_affairs_audit_log.sql
-- Current Affairs approval history: one row for every story or quiz-question
-- change an editor (or the daily pipeline) makes, so approvals, rejections and
-- edits can always be traced back to a person and a time.
--
-- Before: ca_stories / ca_quiz_questions only kept the LAST reviewer
-- (reviewed_by, reviewed_at); each new approval or edit overwrote it.
--
-- Same table design as the earlier Phase 2 proposal (reverted with it on
-- 2026-11-16), so a database that already has ca_audit_log keeps it as it is.
-- Additive only: no existing table or column changes.
--
-- Written by aivorah-world-and-you-service (current-affairs/services/audit.js)
-- with the service role. Never read by students: RLS on, no policies.

create table if not exists "public"."ca_audit_log" (
  "id"            bigserial primary key,
  "actor"         text not null,           -- editor email, or 'pipeline'
  "action"        text not null,           -- e.g. 'story.publish', 'story.edit', 'quiz.reject'
  "entity_type"   text not null,           -- 'story' | 'quiz_question'
  "entity_id"     uuid,
  "before"        jsonb,                   -- the changed fields before (when available)
  "after"         jsonb,                   -- the changed fields after (when available)
  "detail"        text,                    -- short human-readable note
  "created_at"    timestamptz not null default now()
);

create index if not exists ca_audit_entity_idx on "public"."ca_audit_log" (entity_type, entity_id, created_at desc);
create index if not exists ca_audit_actor_idx  on "public"."ca_audit_log" (actor, created_at desc);

alter table "public"."ca_audit_log" enable row level security;  -- no policies: service role only

comment on table "public"."ca_audit_log" is
  'Current Affairs approval history: who approved, rejected, scheduled or edited which story/quiz question, and when.';
