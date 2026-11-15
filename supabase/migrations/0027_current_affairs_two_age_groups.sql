-- Current Affairs: two age groups instead of three.
--   under-8 → 7-12   (children under 8 now read the 7-12 version)
--   8-12    → 7-12
--   13+     → 13-15
--
-- Tables with an age_group column: ca_quiz_questions, ca_quiz_attempts,
-- ca_progress, ca_digest_views, ca_story_reads. ca_stories has no age_group:
-- each row holds every version in its own columns (_young / _kid / _teen).
-- 7-12 reads _kid and 13-15 reads _teen; the under-8 text (_young) is kept
-- as it is but no longer shown or required (its NOT NULL is dropped, since
-- editors now write two versions only).
--
-- under-8 rows that duplicate an 8-12 version:
--   ca_quiz_questions  an under-8 question in a week that already has 8-12
--                      questions (the 7-12 quiz of that week) is ARCHIVED,
--                      not deleted. Otherwise it is relabelled 7-12.
--   ca_quiz_attempts   a student's under-8 attempt in a week where they also
--                      have an 8-12 attempt: the 8-12 one is kept, the under-8
--                      one is moved to the backup table.
--   ca_progress        a student with both an under-8 and an 8-12 row: the two
--                      are merged into one 7-12 row (points and counts added,
--                      best values and badges kept); the under-8 row is moved
--                      to the backup table.
--   ca_digest_views,   unique per student and day / per student and story,
--   ca_story_reads     not per age group: relabelled only.
--
-- Nothing is lost: every row this migration changes, archives, merges or
-- deletes is first copied (whole row, as JSON) into ca_age_group_backup.
-- The counts of each case are printed as NOTICEs when it runs.
--
-- Writes that still use the old values — the content pipeline
-- (aivorah-current-affairs-service GitHub Actions), an old service version
-- during the switch — are converted by a trigger instead of failing. An
-- under-8 quiz question written after this migration is stored as an
-- archived 7-12 question, because the pipeline writes the 8-12 version of
-- the same week too.
--
-- Impact before running (read-only):
--   select 'questions under-8 to archive' as what, count(*) from ca_quiz_questions q
--     where q.age_group = 'under-8' and exists (select 1 from ca_quiz_questions o
--       where o.age_group = '8-12' and o.week_start = q.week_start and o.status not in ('rejected','archived'))
--   union all select 'questions under-8 to relabel', count(*) from ca_quiz_questions q
--     where q.age_group = 'under-8' and not exists (select 1 from ca_quiz_questions o
--       where o.age_group = '8-12' and o.week_start = q.week_start and o.status not in ('rejected','archived'))
--   union all select 'questions 8-12 / 13+', count(*) from ca_quiz_questions where age_group in ('8-12','13+')
--   union all select 'attempts under-8 duplicate', count(*) from ca_quiz_attempts a where a.age_group = 'under-8'
--     and exists (select 1 from ca_quiz_attempts o where o.age_group = '8-12' and o.student_email = a.student_email and o.week_start = a.week_start)
--   union all select 'attempts with an old value (incl. duplicates)', count(*) from ca_quiz_attempts where age_group in ('under-8','8-12','13+')
--   union all select 'progress rows to merge', count(*) from ca_progress p where p.age_group = 'under-8'
--     and exists (select 1 from ca_progress o where o.age_group = '8-12' and o.student_email = p.student_email)
--   union all select 'progress rows with an old value (incl. merged)', count(*) from ca_progress where age_group in ('under-8','8-12','13+')
--   union all select 'digest views to relabel', count(*) from ca_digest_views where age_group in ('under-8','8-12','13+')
--   union all select 'story reads to relabel', count(*) from ca_story_reads where age_group in ('under-8','8-12','13+');

-- ── Old value → new value ───────────────────────────────────────────────────
create or replace function "public"."ca_normalize_age_group"(value text) returns text
language sql immutable
as $$
  select case lower(trim(value))
    when 'under-8' then '7-12'
    when '8-12'    then '7-12'
    when '13+'     then '13-15'
    else value
  end;
$$;

-- ── Backup of every row this migration changes ──────────────────────────────
create table if not exists "public"."ca_age_group_backup" (
  "id"          bigserial primary key,
  "table_name"  text not null,
  "action"      text not null,      -- relabelled / archived / merged_into_7_12 / merged_from_under_8 / removed_duplicate
  "row_data"    jsonb not null,     -- the row exactly as it was before
  "backed_up_at" timestamptz not null default now()
);
alter table "public"."ca_age_group_backup" enable row level security; -- no policies: service role only

-- ── Drop the old CHECKs (allowing only under-8 / 8-12 / 13+) ────────────────
do $$
declare c record;
begin
  for c in
    select con.conrelid::regclass as tbl, con.conname
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace ns on ns.oid = rel.relnamespace
    where ns.nspname = 'public' and con.contype = 'c'
      and rel.relname in ('ca_quiz_questions','ca_quiz_attempts','ca_progress','ca_digest_views','ca_story_reads')
      and pg_get_constraintdef(con.oid) like '%age_group%'
  loop
    execute format('alter table %s drop constraint %I', c.tbl, c.conname);
  end loop;
end $$;

-- ── Convert the data ────────────────────────────────────────────────────────
do $$
declare n integer;
begin
  -- Quiz questions: under-8 duplicates of a week's 8-12 quiz are archived.
  create temp table ca_tmp_dup_questions on commit drop as
    select q.id from "public"."ca_quiz_questions" q
    where q.age_group = 'under-8'
      and exists (select 1 from "public"."ca_quiz_questions" o
                  where o.age_group = '8-12' and o.week_start = q.week_start
                    and o.status not in ('rejected','archived'));
  insert into "public"."ca_age_group_backup" (table_name, action, row_data)
    select 'ca_quiz_questions', 'archived', to_jsonb(q) from "public"."ca_quiz_questions" q
    where q.id in (select id from ca_tmp_dup_questions);
  update "public"."ca_quiz_questions" set status = 'archived', age_group = '7-12',
    review_notes = concat_ws(' | ', nullif(review_notes, ''), 'archived: under-8 version of a week that has a 7-12 (8-12) quiz')
    where id in (select id from ca_tmp_dup_questions);
  get diagnostics n = row_count;
  raise notice 'ca_quiz_questions: % under-8 duplicates archived', n;

  insert into "public"."ca_age_group_backup" (table_name, action, row_data)
    select 'ca_quiz_questions', 'relabelled', to_jsonb(q) from "public"."ca_quiz_questions" q
    where q.age_group in ('under-8','8-12','13+');
  update "public"."ca_quiz_questions" set age_group = "public"."ca_normalize_age_group"(age_group)
    where age_group in ('under-8','8-12','13+');
  get diagnostics n = row_count;
  raise notice 'ca_quiz_questions: % relabelled', n;

  -- Quiz attempts: one per student / age group / week. Keep the 8-12 attempt.
  create temp table ca_tmp_dup_attempts on commit drop as
    select a.id from "public"."ca_quiz_attempts" a
    where a.age_group = 'under-8'
      and exists (select 1 from "public"."ca_quiz_attempts" o
                  where o.age_group = '8-12' and o.student_email = a.student_email and o.week_start = a.week_start);
  insert into "public"."ca_age_group_backup" (table_name, action, row_data)
    select 'ca_quiz_attempts', 'removed_duplicate', to_jsonb(a) from "public"."ca_quiz_attempts" a
    where a.id in (select id from ca_tmp_dup_attempts);
  delete from "public"."ca_quiz_attempts" where id in (select id from ca_tmp_dup_attempts);
  get diagnostics n = row_count;
  raise notice 'ca_quiz_attempts: % under-8 duplicates moved to ca_age_group_backup', n;

  insert into "public"."ca_age_group_backup" (table_name, action, row_data)
    select 'ca_quiz_attempts', 'relabelled', to_jsonb(a) from "public"."ca_quiz_attempts" a
    where a.age_group in ('under-8','8-12','13+');
  update "public"."ca_quiz_attempts" set age_group = "public"."ca_normalize_age_group"(age_group)
    where age_group in ('under-8','8-12','13+');
  get diagnostics n = row_count;
  raise notice 'ca_quiz_attempts: % relabelled', n;

  -- Progress: one row per student and age group. Merge under-8 into 8-12.
  insert into "public"."ca_age_group_backup" (table_name, action, row_data)
    select 'ca_progress', case p.age_group when 'under-8' then 'merged_into_7_12' else 'merged_from_under_8' end, to_jsonb(p)
    from "public"."ca_progress" p
    where p.age_group in ('under-8','8-12')
      and exists (select 1 from "public"."ca_progress" y where y.age_group = 'under-8' and y.student_email = p.student_email)
      and exists (select 1 from "public"."ca_progress" k where k.age_group = '8-12' and k.student_email = p.student_email);
  update "public"."ca_progress" k set
    points              = k.points + y.points,
    digests_completed   = k.digests_completed + y.digests_completed,
    stories_read        = k.stories_read + y.stories_read,
    quizzes_completed   = k.quizzes_completed + y.quizzes_completed,
    current_streak      = case when y.last_digest_date > k.last_digest_date or k.last_digest_date is null
                               then y.current_streak else k.current_streak end,
    longest_streak      = greatest(k.longest_streak, y.longest_streak),
    best_quiz_score     = greatest(k.best_quiz_score, y.best_quiz_score),
    last_quiz_score     = case when y.last_quiz_date > k.last_quiz_date or k.last_quiz_date is null
                               then coalesce(y.last_quiz_score, k.last_quiz_score) else k.last_quiz_score end,
    badge_excellence    = k.badge_excellence or y.badge_excellence,
    badge_weekly_streak = k.badge_weekly_streak or y.badge_weekly_streak,
    badge_growth        = k.badge_growth or y.badge_growth,
    last_digest_date    = greatest(k.last_digest_date, y.last_digest_date),
    last_story_date     = greatest(k.last_story_date, y.last_story_date),
    last_quiz_date      = greatest(k.last_quiz_date, y.last_quiz_date),
    created_at          = least(k.created_at, y.created_at),
    updated_at          = greatest(k.updated_at, y.updated_at)
  from "public"."ca_progress" y
  where k.age_group = '8-12' and y.age_group = 'under-8' and y.student_email = k.student_email;
  get diagnostics n = row_count;
  delete from "public"."ca_progress" y
    where y.age_group = 'under-8'
      and exists (select 1 from "public"."ca_progress" k where k.age_group = '8-12' and k.student_email = y.student_email);
  raise notice 'ca_progress: % students had under-8 and 8-12 rows, merged into one', n;

  insert into "public"."ca_age_group_backup" (table_name, action, row_data)
    select 'ca_progress', 'relabelled', to_jsonb(p) from "public"."ca_progress" p
    where p.age_group in ('under-8','8-12','13+');
  update "public"."ca_progress" set age_group = "public"."ca_normalize_age_group"(age_group)
    where age_group in ('under-8','8-12','13+');
  get diagnostics n = row_count;
  raise notice 'ca_progress: % relabelled', n;

  -- Digest views and story reads: relabel only.
  insert into "public"."ca_age_group_backup" (table_name, action, row_data)
    select 'ca_digest_views', 'relabelled', to_jsonb(v) from "public"."ca_digest_views" v
    where v.age_group in ('under-8','8-12','13+');
  update "public"."ca_digest_views" set age_group = "public"."ca_normalize_age_group"(age_group)
    where age_group in ('under-8','8-12','13+');
  get diagnostics n = row_count;
  raise notice 'ca_digest_views: % relabelled', n;

  insert into "public"."ca_age_group_backup" (table_name, action, row_data)
    select 'ca_story_reads', 'relabelled', to_jsonb(r) from "public"."ca_story_reads" r
    where r.age_group in ('under-8','8-12','13+');
  update "public"."ca_story_reads" set age_group = "public"."ca_normalize_age_group"(age_group)
    where age_group in ('under-8','8-12','13+');
  get diagnostics n = row_count;
  raise notice 'ca_story_reads: % relabelled', n;
end $$;

-- ── Old values written later are converted, not rejected ────────────────────
create or replace function "public"."ca_age_group_on_write"() returns trigger
language plpgsql
as $$
begin
  if tg_table_name = 'ca_quiz_questions' and tg_op = 'INSERT' and lower(trim(new.age_group)) = 'under-8' then
    new.status := 'archived';
  end if;
  new.age_group := "public"."ca_normalize_age_group"(new.age_group);
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['ca_quiz_questions','ca_quiz_attempts','ca_progress','ca_digest_views','ca_story_reads'] loop
    execute format('drop trigger if exists ca_age_group_on_write on "public".%I', t);
    execute format('create trigger ca_age_group_on_write before insert or update of age_group on "public".%I
                    for each row execute function "public"."ca_age_group_on_write"()', t);
  end loop;
end $$;

-- ── New CHECKs: only the two age groups ─────────────────────────────────────
alter table "public"."ca_quiz_questions" add constraint ca_quiz_questions_age_group_check check (age_group in ('7-12','13-15'));
alter table "public"."ca_quiz_attempts"  add constraint ca_quiz_attempts_age_group_check  check (age_group in ('7-12','13-15'));
alter table "public"."ca_progress"       add constraint ca_progress_age_group_check       check (age_group in ('7-12','13-15'));
alter table "public"."ca_digest_views"   add constraint ca_digest_views_age_group_check   check (age_group in ('7-12','13-15'));
alter table "public"."ca_story_reads"    add constraint ca_story_reads_age_group_check    check (age_group in ('7-12','13-15'));

-- ── Stories: the under-8 version is no longer written ───────────────────────
alter table "public"."ca_stories" alter column "title_young"         drop not null;
alter table "public"."ca_stories" alter column "summary_young"       drop not null;
alter table "public"."ca_stories" alter column "what_happened_young" drop not null;
alter table "public"."ca_stories" alter column "why_important_young" drop not null;
comment on column "public"."ca_stories"."title_kid"   is '7-12 version (was 8-12)';
comment on column "public"."ca_stories"."title_teen"  is '13-15 version (was 13+)';
comment on column "public"."ca_stories"."title_young" is 'retired under-8 version: kept, not shown (under-8 students read the 7-12 version)';

notify pgrst, 'reload schema';
