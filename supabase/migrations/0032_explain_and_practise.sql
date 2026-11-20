-- 0032_explain_and_practise.sql
-- Report → each wrong question → [Explain This Question] [Practise This Skill].
--
--   practice_explanations          every explanation Ask Aivorah showed for one
--                                  wrong question of one test (method used, the
--                                  text shown), so "Explain Another Way" never
--                                  repeats a method and the report can say
--                                  "Explanation reviewed".
--   practice_generated_questions   fresh practice questions generated one batch
--                                  at a time for one wrong question, WITH their
--                                  answer keys (server only). A content
--                                  fingerprint stops a lightly reworded copy
--                                  from counting as new.
--   practice_followups (+cols)     the wrong question and level the active
--                                  practice question belongs to, and whether
--                                  it is a delayed memory check.
--   practice_followup_responses (+cols)
--                                  per answer: the wrong question it practises,
--                                  question level, delayed memory check flag,
--                                  skipped flag and the diagnosed mistake step.
--
-- Additive only: new tables and nullable / defaulted columns. Existing rows and
-- the first version of the feature keep working. RLS on, no policies: only
-- aivorah-learning-paths-service (service role) reads or writes these.

alter table public.practice_followups
  add column if not exists current_focus_index integer,
  add column if not exists current_question_level smallint,
  add column if not exists current_is_memory_check boolean not null default false;

alter table public.practice_followup_responses
  add column if not exists origin_question_index integer,
  add column if not exists question_level smallint,
  add column if not exists is_memory_check boolean not null default false,
  add column if not exists skipped boolean not null default false,
  add column if not exists mistake_tag text;

create index if not exists practice_followup_responses_origin_idx
  on public.practice_followup_responses (followup_id, origin_question_index);

create table if not exists "public"."practice_explanations" (
  "id"              uuid primary key default gen_random_uuid(),
  "followup_id"     uuid not null references public.practice_followups(id) on delete cascade,
  "student_id"      uuid not null references public.users(id) on delete cascade,
  "attempt_id"      uuid not null references public.topic_attempts(id) on delete cascade,
  -- Index of the wrong question in topic_attempts.per_question_results.
  "question_index"  integer not null check (question_index >= 0),
  -- Teaching method: 'rule' | 'steps' | 'visual' (or a catalogue method id).
  "method"          text not null,
  "variant"         text not null default 'first' check (variant in ('first', 'again', 'another_way')),
  -- Short name of the idea behind the question, e.g. 'Finding the LCM'.
  "skill_label"     text,
  -- What was shown: { title, body, steps?, example?, table? }.
  "payload"         jsonb not null,
  "created_at"      timestamptz not null default now()
);

create index if not exists practice_explanations_attempt_idx
  on public.practice_explanations (attempt_id, question_index, created_at);
create index if not exists practice_explanations_student_idx
  on public.practice_explanations (student_id, created_at desc);

create table if not exists "public"."practice_generated_questions" (
  "id"                     uuid primary key default gen_random_uuid(),
  "followup_id"            uuid not null references public.practice_followups(id) on delete cascade,
  -- Stable id used in practice_followup_responses.question_id ('gq-…').
  "question_id"            text not null,
  "origin_question_index"  integer,
  "level"                  smallint not null default 2 check (level between 1 and 3),
  -- Full question incl. the answer key, hint and solution. Never sent as-is.
  "payload"                jsonb not null,
  -- Normalised question text: a repeat of the same text can't be stored twice.
  "fingerprint"            text not null,
  "created_at"             timestamptz not null default now(),
  constraint practice_generated_questions_id_key unique (followup_id, question_id),
  constraint practice_generated_questions_fingerprint_key unique (followup_id, fingerprint)
);

create index if not exists practice_generated_questions_origin_idx
  on public.practice_generated_questions (followup_id, origin_question_index);

alter table public.practice_explanations enable row level security;          -- no policies: service role only
alter table public.practice_generated_questions enable row level security;   -- no policies: service role only

comment on table public.practice_explanations is
  'Explain This Question: each explanation Ask Aivorah showed for one wrong question of one test.';
comment on table public.practice_generated_questions is
  'Practise This Skill: fresh practice questions (with server-only answer keys) generated for one wrong question.';
