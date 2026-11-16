-- 0028_assignment_reasoning_setting.sql
-- Add a per-assignment setting controlling whether students must explain
-- their thinking ("Why did you choose this answer?").
--
-- values: 'off' | 'optional' | 'required'
--   off      — no reasoning box shown, nothing saved
--   optional — reasoning box shown, empty allowed (default for NEW assignments)
--   required — reasoning box shown, submit blocked until every question has one
--
-- Existing assignments default to 'off' so nothing old changes behaviour.
-- Practice (learning-path quizzes) is always 'optional' client-side and does
-- not read this column — it has no assignment row.

ALTER TABLE public.assignments
  ADD COLUMN IF NOT EXISTS require_reasoning text
    DEFAULT 'off'::text NOT NULL
    CHECK (require_reasoning IN ('off', 'optional', 'required'));

COMMENT ON COLUMN public.assignments.require_reasoning IS
  'Student reasoning requirement for quiz questions: off | optional | required. Default off for existing rows.';
