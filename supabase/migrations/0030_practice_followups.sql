-- 0030_practice_followups.sql
-- "Practise This Skill": follow-up practice that starts from a practice test
-- report (topic_attempts) and is checked in Ask Aivorah.
--
-- One persisted source of follow-up results for the Student (History), Parent
-- (AI Progress Report) and Teacher (Need Support) portals.
--
--   practice_followups           one row per original test attempt + curriculum
--                                skill: why it was recommended, the saved
--                                teaching method(s), the question being asked
--                                now, help shown on it, and completion.
--   practice_followup_responses  one row per follow-up question the student
--                                answered: their answer and reasoning, help
--                                used, the server's grading and reasoning
--                                outcome, and the credit it earned.
--
-- Written only by aivorah-learning-paths-service (routes/practiceFollowup.js)
-- with the service role, after it checks who is asking. RLS on with no
-- policies, so the browser can never read or write these tables directly.
--
-- Additive only: no existing table or column changes. Idempotent.

create table if not exists "public"."practice_followups" (
  "id"                       uuid primary key default gen_random_uuid(),
  "student_id"               uuid not null references public.users(id) on delete cascade,
  -- The exact original test this follow-up came from.
  "attempt_id"               uuid not null references public.topic_attempts(id) on delete cascade,
  -- Curriculum skill id from the service's vetted skill catalogue,
  -- e.g. 'en.figurative.pun-vs-alliteration', 'math.fractions.equivalent'.
  "skill_id"                 text not null,
  "topic"                    text not null,
  "topic_id"                 uuid,
  "subject"                  text not null,
  "grade"                    text not null,
  "curriculum"               text not null default '',
  -- The original test's score (percent). Copied for display only; the
  -- original attempt itself is never changed by follow-up practice.
  "original_score"           numeric(5,2),
  -- Why it was recommended: one item per original question,
  -- { index, kind: 'incorrect' | 'second_try' | 'reasoning_misconception', ... }
  "evidence"                 jsonb not null default '[]'::jsonb,
  "evidence_question_count"  integer not null default 0 check (evidence_question_count >= 0),
  "status"                   text not null default 'available'
                             check (status in ('available', 'in_progress', 'completed')),
  -- Teaching methods already shown (e.g. 'definition', 'side_by_side'), so a
  -- refresh never repeats one; current_method is the one on screen now.
  "teaching_methods_used"    text[] not null default '{}'::text[],
  "current_method"           text,
  -- The fresh question being asked now (catalogue id) and the help shown on it.
  "current_question_id"      text,
  "current_help"             text not null default 'none'
                             check (current_help in ('none', 'hint', 'solution')),
  -- Consecutive correct, independent answers with sound reasoning (2 = done).
  "independent_streak"       integer not null default 0 check (independent_streak >= 0),
  "completed_at"             timestamptz,
  "created_at"               timestamptz not null default now(),
  "updated_at"               timestamptz not null default now(),
  constraint practice_followups_attempt_skill_key unique (attempt_id, skill_id)
);

create index if not exists practice_followups_student_skill_idx
  on public.practice_followups (student_id, skill_id, created_at desc);

create table if not exists "public"."practice_followup_responses" (
  "id"                 uuid primary key default gen_random_uuid(),
  "followup_id"        uuid not null references public.practice_followups(id) on delete cascade,
  "student_id"         uuid not null references public.users(id) on delete cascade,
  "skill_id"           text not null,
  "question_id"        text not null,
  "question_type"      text not null check (question_type in ('mcq', 'fill_blank')),
  "question_text"      text not null,
  -- Order the questions were answered in this follow-up (1, 2, 3 ...).
  "seq"                integer not null check (seq > 0),
  "answer"             text,
  "reasoning"          text,
  -- The student's one short follow-up explanation, when the first was unclear.
  "clarification"      text,
  "help_shown"         text not null default 'none' check (help_shown in ('none', 'hint', 'solution')),
  "grading_outcome"    text not null check (grading_outcome in ('correct', 'incorrect', 'not_answered')),
  "reasoning_outcome"  text not null
                       check (reasoning_outcome in ('supported', 'unclear', 'misconception', 'unable_to_evaluate', 'not_evaluated')),
  "credit"             text not null check (credit in ('independent', 'assisted', 'none', 'pending_clarification')),
  "feedback"           text,
  "created_at"         timestamptz not null default now(),
  "finalized_at"       timestamptz,
  -- A question is answered once: a repeated or concurrent submit of the same
  -- question can never add a second piece of evidence.
  constraint practice_followup_responses_question_key unique (followup_id, question_id),
  constraint practice_followup_responses_seq_key unique (followup_id, seq)
);

create index if not exists practice_followup_responses_student_skill_idx
  on public.practice_followup_responses (student_id, skill_id, created_at desc);

alter table public.practice_followups enable row level security;           -- no policies: service role only
alter table public.practice_followup_responses enable row level security;  -- no policies: service role only

comment on table public.practice_followups is
  'Practise This Skill: follow-up practice for one curriculum skill from one original practice test (topic_attempts).';
comment on table public.practice_followup_responses is
  'Practise This Skill: each follow-up question a student answered, with server grading, reasoning outcome and credit.';
