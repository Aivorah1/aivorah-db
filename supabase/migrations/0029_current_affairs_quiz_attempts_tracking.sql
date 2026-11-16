-- Current Affairs quiz: track in-progress attempts so the answer-check flow
-- is server-side and the first checked answer is final.
--
-- Before: POST /current-affairs/quiz/check revealed the correct answer to
-- anyone (no sign-in) and stored nothing; POST /quiz/submit graded whatever
-- answers the client sent. A student could probe every question's answer key
-- without committing, or submit a full answer set after peeking.
--
-- After: /quiz/check requires the student's sign-in, creates (or reuses) an
-- in-progress attempt, and records each checked answer there. The first
-- answer recorded for a question is final — later checks for the same
-- question return the recorded result without changing it. /quiz/submit
-- grades only the recorded answers and marks the attempt submitted. The
-- correct index is never returned before an answer is recorded.

alter table "public"."ca_quiz_attempts"
  add column if not exists "status" text not null default 'in_progress'
    check (status in ('in_progress', 'submitted'));

alter table "public"."ca_quiz_attempts"
  add column if not exists "started_at" timestamptz not null default now();

-- An in-progress attempt is visible to its owner; a submitted one too.
-- (The existing select_own policy already covers both, since it matches on
-- student_email regardless of status.)

notify pgrst, 'reload schema';
