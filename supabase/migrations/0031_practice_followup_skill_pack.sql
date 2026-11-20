-- 0031_practice_followup_skill_pack.sql
-- Practise This Skill for ANY topic: when a test question isn't in the vetted
-- skill catalogue, aivorah-learning-paths-service builds a "topic skill" pack
-- (teaching, fresh questions WITH their answer keys, hints, solutions, rubric)
-- from that topic's lesson text, once per follow-up, and keeps it here so the
-- session is the same after a reload and the answer keys never leave the server.
--
-- Additive only: one nullable column. RLS on this table already has no
-- policies (service role only), so students can never read the answer keys.

alter table public.practice_followups
  add column if not exists skill_pack jsonb;

comment on column public.practice_followups.skill_pack is
  'Generated topic-skill pack (teaching, questions with answer keys, rubric) for follow-ups whose skill_id starts with topic:. Null for catalogue skills.';
