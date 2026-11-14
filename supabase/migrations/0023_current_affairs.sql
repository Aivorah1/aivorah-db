-- Current Affairs (aivorah-current-affairs-service): the daily news digest,
-- the weekly quiz, and students' points, streaks and badges.
--
-- These tables were first created by hand from the service's schema.sql, so
-- this migration is written to run on a database that already has them:
-- tables and indexes are created only when missing, columns added by later
-- versions are added if missing, functions and policies are replaced. No
-- demo rows: content comes from the pipeline and the admin content tool.
--
--   ca_stories          news stories, 3 age versions each (status-gated)
--   ca_quiz_questions   weekly quiz questions incl. answers (status-gated,
--                       never readable by students directly)
--   ca_digest_views     one row per student per day the digest was completed
--   ca_story_reads      one row per student per story read (+ reading time)
--   ca_quiz_attempts    one weekly quiz attempt per student / age group / week
--   ca_progress         points, streaks, counts, badges per student + age group

-- ── Stories ─────────────────────────────────────────────────────────────────
create table if not exists "public"."ca_stories" (
  "id"                  uuid primary key default gen_random_uuid(),
  "category"            text not null
                        check (category in ('india','world','economy','science','environment','sports','society')),
  "publish_date"        date not null default current_date,
  -- review = waiting for an editor; published = visible in the app;
  -- draft = being written in the admin tool; rejected/archived = never shown
  "status"              text not null default 'review'
                        check (status in ('draft','review','published','rejected','archived')),
  "priority"            integer not null default 0,           -- higher shows first
  "title_young"         text not null,                        -- under-8
  "title_kid"           text not null,                        -- 8-12
  "title_teen"          text not null,                        -- 13+
  "summary_young"       text not null,
  "summary_kid"         text not null,
  "summary_teen"        text not null,
  "what_happened_young" text not null,
  "what_happened_kid"   text not null,
  "what_happened_teen"  text not null,
  "why_important_young" text not null,
  "why_important_kid"   text not null,
  "why_important_teen"  text not null,
  "did_you_know"        text,
  "new_word_1"          text,
  "def_1"               text,
  "new_word_2"          text,
  "def_2"               text,
  "think_about_it"      text,
  "image_url"           text,
  "source"              text not null,
  "source_url"          text,
  "is_true_fact"        boolean not null default false,       -- an editor checked it against the source
  "review_notes"        text,                                 -- automatic-check flags for the editor
  "created_at"          timestamptz not null default now(),
  "updated_at"          timestamptz not null default now()
);

-- Added by later versions of the service's schema.sql.
alter table "public"."ca_stories" add column if not exists "new_word_3" text;
alter table "public"."ca_stories" add column if not exists "def_3" text;
alter table "public"."ca_stories" add column if not exists "age_extras" jsonb not null default '{}'::jsonb;
alter table "public"."ca_stories" add column if not exists "source_url_hash" text;
-- Who approved or rejected it in the admin tool, and when ('auto' = the pipeline).
alter table "public"."ca_stories" add column if not exists "reviewed_by" text;
alter table "public"."ca_stories" add column if not exists "reviewed_at" timestamptz;

create index if not exists ca_stories_published_idx
  on "public"."ca_stories" (publish_date desc, priority desc) where status = 'published';
create unique index if not exists ca_stories_source_url_hash_key
  on "public"."ca_stories" (source_url_hash) where source_url_hash is not null;
create index if not exists ca_stories_status_idx
  on "public"."ca_stories" (status, publish_date desc);

-- ── Quiz questions ──────────────────────────────────────────────────────────
-- week_start is the Sunday the quiz is released; it is played until Saturday.
create table if not exists "public"."ca_quiz_questions" (
  "id"             uuid primary key default gen_random_uuid(),
  "week_start"     date not null,
  "age_group"      text not null check (age_group in ('under-8','8-12','13+')),
  "category"       text not null
                   check (category in ('india','world','economy','science','environment','sports','society')),
  "question_type"  text not null default 'mcq' check (question_type in ('mcq','true_false','reasoning')),
  "question"       text not null,
  "options"        jsonb not null,
  "correct_index"  integer not null check (correct_index >= 0),
  "explanation"    text not null,
  "extra_fact"     text,
  "story_id"       uuid references "public"."ca_stories"(id) on delete set null,
  "status"         text not null default 'review'
                   check (status in ('draft','review','published','rejected','archived')),
  "position"       integer not null default 0,
  "created_at"     timestamptz not null default now(),
  check (jsonb_typeof(options) = 'array' and correct_index < jsonb_array_length(options))
);

alter table "public"."ca_quiz_questions" add column if not exists "review_notes" text;
alter table "public"."ca_quiz_questions" add column if not exists "reviewed_by" text;
alter table "public"."ca_quiz_questions" add column if not exists "reviewed_at" timestamptz;

create index if not exists ca_quiz_questions_week_idx
  on "public"."ca_quiz_questions" (week_start, age_group) where status = 'published';

-- ── Student activity ────────────────────────────────────────────────────────
create table if not exists "public"."ca_digest_views" (
  "id"            uuid primary key default gen_random_uuid(),
  "student_email" text not null,
  "age_group"     text not null check (age_group in ('under-8','8-12','13+')),
  "view_date"     date not null,
  "story_count"   integer not null default 0,
  "created_at"    timestamptz not null default now(),
  unique (student_email, view_date)
);

create table if not exists "public"."ca_story_reads" (
  "id"               uuid primary key default gen_random_uuid(),
  "student_email"    text not null,
  "story_id"         uuid not null references "public"."ca_stories"(id) on delete cascade,
  "age_group"        text not null check (age_group in ('under-8','8-12','13+')),
  "read_date"        date not null default current_date,
  "duration_seconds" integer check (duration_seconds is null or duration_seconds >= 0),
  "created_at"       timestamptz not null default now(),
  unique (student_email, story_id)
);

create table if not exists "public"."ca_quiz_attempts" (
  "id"             uuid primary key default gen_random_uuid(),
  "student_email"  text not null,
  "age_group"      text not null check (age_group in ('under-8','8-12','13+')),
  "week_start"     date not null,
  "answers"        jsonb not null default '[]'::jsonb,
  "score"          integer not null default 0,
  "total"          integer not null default 0,
  "percentage"     integer not null default 0,
  "points_earned"  integer not null default 0,
  "points_awarded" boolean not null default false,
  "created_at"     timestamptz not null default now(),
  unique (student_email, age_group, week_start)
);

create table if not exists "public"."ca_progress" (
  "student_email"       text not null,
  "age_group"           text not null check (age_group in ('under-8','8-12','13+')),
  "points"              integer not null default 0,
  "current_streak"      integer not null default 0,
  "longest_streak"      integer not null default 0,
  "digests_completed"   integer not null default 0,
  "stories_read"        integer not null default 0,
  "quizzes_completed"   integer not null default 0,
  "best_quiz_score"     integer,
  "last_quiz_score"     integer,
  "badge_excellence"    boolean not null default false,
  "badge_weekly_streak" boolean not null default false,
  "badge_growth"        boolean not null default false,
  "last_digest_date"    date,
  "last_story_date"     date,
  "last_quiz_date"      date,
  "created_at"          timestamptz not null default now(),
  "updated_at"          timestamptz not null default now(),
  primary key (student_email, age_group)
);

-- Analytics read these by date.
create index if not exists ca_digest_views_date_idx on "public"."ca_digest_views" (view_date);
create index if not exists ca_story_reads_date_idx on "public"."ca_story_reads" (read_date);
create index if not exists ca_quiz_attempts_week_idx on "public"."ca_quiz_attempts" (week_start);

-- ── updated_at on stories ───────────────────────────────────────────────────
create or replace function "public"."ca_touch_updated_at"() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists ca_stories_touch on "public"."ca_stories";
create trigger ca_stories_touch before update on "public"."ca_stories"
  for each row execute function "public"."ca_touch_updated_at"();

-- ── Atomic progress update (called by the service via supabase.rpc) ─────────
create or replace function "public"."ca_apply_progress"(
  p_student_email       text,
  p_age_group           text,
  p_points              integer default 0,
  p_digests             integer default 0,
  p_stories             integer default 0,
  p_quizzes             integer default 0,
  p_current_streak      integer default null,
  p_last_digest_date    date    default null,
  p_last_story_date     date    default null,
  p_quiz_score          integer default null,
  p_last_quiz_date      date    default null,
  p_badge_excellence    boolean default false,
  p_badge_weekly_streak boolean default false,
  p_badge_growth        boolean default false
) returns "public"."ca_progress"
language sql
as $$
  insert into "public"."ca_progress" as p (
    student_email, age_group, points, digests_completed, stories_read, quizzes_completed,
    current_streak, longest_streak, last_digest_date, last_story_date,
    best_quiz_score, last_quiz_score, last_quiz_date,
    badge_excellence, badge_weekly_streak, badge_growth
  ) values (
    lower(trim(p_student_email)), p_age_group,
    greatest(coalesce(p_points, 0), 0), greatest(coalesce(p_digests, 0), 0),
    greatest(coalesce(p_stories, 0), 0), greatest(coalesce(p_quizzes, 0), 0),
    coalesce(p_current_streak, 0), coalesce(p_current_streak, 0),
    p_last_digest_date, p_last_story_date,
    p_quiz_score, p_quiz_score, p_last_quiz_date,
    coalesce(p_badge_excellence, false), coalesce(p_badge_weekly_streak, false), coalesce(p_badge_growth, false)
  )
  on conflict (student_email, age_group) do update set
    points              = p.points + excluded.points,
    digests_completed   = p.digests_completed + excluded.digests_completed,
    stories_read        = p.stories_read + excluded.stories_read,
    quizzes_completed   = p.quizzes_completed + excluded.quizzes_completed,
    current_streak      = coalesce(p_current_streak, p.current_streak),
    longest_streak      = greatest(p.longest_streak, coalesce(p_current_streak, 0)),
    last_digest_date    = greatest(p.last_digest_date, excluded.last_digest_date),
    last_story_date     = greatest(p.last_story_date, excluded.last_story_date),
    best_quiz_score     = greatest(p.best_quiz_score, excluded.best_quiz_score),
    last_quiz_score     = coalesce(p_quiz_score, p.last_quiz_score),
    last_quiz_date      = greatest(p.last_quiz_date, excluded.last_quiz_date),
    badge_excellence    = p.badge_excellence or excluded.badge_excellence,
    badge_weekly_streak = p.badge_weekly_streak or excluded.badge_weekly_streak,
    badge_growth        = p.badge_growth or excluded.badge_growth,
    updated_at          = now()
  returning *;
$$;

-- Only the service (service_role key) may call it.
revoke all on function "public"."ca_apply_progress"(text, text, integer, integer, integer, integer, integer, date, date, integer, date, boolean, boolean, boolean) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on function "public"."ca_apply_progress"(text, text, integer, integer, integer, integer, integer, date, date, integer, date, boolean, boolean, boolean) from anon, authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function "public"."ca_apply_progress"(text, text, integer, integer, integer, integer, integer, date, date, integer, date, boolean, boolean, boolean) to service_role;
  end if;
end $$;

-- ── Row Level Security ──────────────────────────────────────────────────────
-- The service uses the service_role key (bypasses RLS) and students sign in
-- with Firebase. These policies only matter for a client querying Supabase
-- directly with a Supabase JWT whose email claim is the student's. Points and
-- scores are never writable by students; quiz questions (with answers) have
-- no student policy at all.
alter table "public"."ca_stories"        enable row level security;
alter table "public"."ca_quiz_questions" enable row level security;
alter table "public"."ca_digest_views"   enable row level security;
alter table "public"."ca_story_reads"    enable row level security;
alter table "public"."ca_quiz_attempts"  enable row level security;
alter table "public"."ca_progress"       enable row level security;

drop policy if exists ca_stories_read_published on "public"."ca_stories";
create policy ca_stories_read_published on "public"."ca_stories"
  for select to anon, authenticated using (status = 'published');

drop policy if exists ca_progress_select_own on "public"."ca_progress";
create policy ca_progress_select_own on "public"."ca_progress"
  for select to authenticated using (student_email = lower(auth.jwt() ->> 'email'));

drop policy if exists ca_quiz_attempts_select_own on "public"."ca_quiz_attempts";
create policy ca_quiz_attempts_select_own on "public"."ca_quiz_attempts"
  for select to authenticated using (student_email = lower(auth.jwt() ->> 'email'));

drop policy if exists ca_digest_views_select_own on "public"."ca_digest_views";
create policy ca_digest_views_select_own on "public"."ca_digest_views"
  for select to authenticated using (student_email = lower(auth.jwt() ->> 'email'));

drop policy if exists ca_digest_views_insert_own on "public"."ca_digest_views";
create policy ca_digest_views_insert_own on "public"."ca_digest_views"
  for insert to authenticated with check (student_email = lower(auth.jwt() ->> 'email'));

drop policy if exists ca_story_reads_select_own on "public"."ca_story_reads";
create policy ca_story_reads_select_own on "public"."ca_story_reads"
  for select to authenticated using (student_email = lower(auth.jwt() ->> 'email'));

drop policy if exists ca_story_reads_insert_own on "public"."ca_story_reads";
create policy ca_story_reads_insert_own on "public"."ca_story_reads"
  for insert to authenticated with check (student_email = lower(auth.jwt() ->> 'email'));

-- Tell the Supabase API (PostgREST) about the tables and function right away.
notify pgrst, 'reload schema';
