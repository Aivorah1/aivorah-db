-- 0033_ai_teacher_questions.sql
-- AI Teacher (Student Portal): spoken practice questions. The question the
-- student hears and sees is returned to the app; its expected answer stays
-- here (service role only) until the student answers it or asks for the
-- solution, when the server grades the spoken answer and releases it.
--
-- Additive only: one new table, RLS on, no policies, so the browser can never
-- read an answer. Written by aivorah-learning-paths-service routes/aiTeacher.js.

create table if not exists "public"."ai_teacher_questions" (
  "id"               uuid primary key default gen_random_uuid(),
  "student_id"       uuid not null references public.users(id) on delete cascade,
  "subject"          text not null,
  -- The curriculum topic it practises, e.g. 'CBSE|6|Mathematics|5|Common Multiples and Common Factors'.
  "topic_key"        text not null,
  -- Stable fingerprint of the example (e.g. 'lcm:8,12'), so "another question" never repeats it.
  "example_key"      text not null,
  "prompt"           text not null,
  "answer_format"    text not null check (answer_format in ('number', 'text')),
  -- { "values": ["24"], "accept": [...], "steps": [...], "explanation": "..." } — never sent before release.
  "answer"           jsonb not null,
  "duration_seconds" integer check (duration_seconds is null or duration_seconds between 10 and 1800),
  "source"           text not null default 'generated' check (source in ('computed', 'generated', 'curriculum')),
  "status"           text not null default 'open' check (status in ('open', 'answered', 'revealed')),
  "student_answer"   text,
  "correct"          boolean,
  "answered_at"      timestamptz,
  "created_at"       timestamptz not null default now()
);

create index if not exists ai_teacher_questions_student_topic_idx
  on public.ai_teacher_questions (student_id, topic_key, created_at desc);

alter table public.ai_teacher_questions enable row level security;  -- no policies: service role only

comment on table public.ai_teacher_questions is
  'AI Teacher spoken practice questions; expected answers stay server-side until answered or revealed.';
