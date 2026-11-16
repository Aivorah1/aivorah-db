-- Current Affairs — Phase 2: richer data model (per-age workflow, digest, quiz
-- lifecycle, sources, newsroom, fact-checks, audit log, settings).
--
-- Backward compatible: every existing column and CHECK value is kept. New
-- columns are nullable or have defaults; new tables are independent. Existing
-- service code and tests that use status='published'/'review'/'draft'/'rejected'
--/'archived' on ca_stories and ca_quiz_questions keep working — those values
-- remain valid. The new workflow statuses are additive.
--
-- Students still only ever see Published content for today or earlier, in
-- their own age version.

-- ── ca_stories: per-age workflow status ─────────────────────────────────────
-- Workflow per age version:
--   collected → selected → generated → in_review → approved → ready → scheduled
--   → published → archived / rejected
-- Ready = both age versions approved. Editing an approved version resets it to
-- needing re-approval (service sets status_<age> back to 'generated'/'in_review').
-- Old single `status` column is kept for backward compatibility; status_kid /
-- status_teen are the source of truth going forward.
alter table "public"."ca_stories"
  add column if not exists "status_kid"  text check (status_kid in
    ('collected','selected','generated','in_review','approved','ready','scheduled','published','archived','rejected'));
alter table "public"."ca_stories"
  add column if not exists "status_teen" text check (status_teen in
    ('collected','selected','generated','in_review','approved','ready','scheduled','published','archived','rejected'));

-- Per-age content overrides. Shared columns (title_kid/teen, summary_*,
-- what_happened_*, why_important_*, did_you_know, new_word_1..3, def_1..3,
-- think_about_it, image_url) remain the default. age_content overrides them
-- per age group when present. Shape:
--   { "7-12": { image_url, did_you_know, new_words: [{word,definition}],
--               think_about_it },
--     "13-15": { image_url, did_you_know, new_words: [...], think_about_it,
--                impact } }
alter table "public"."ca_stories"
  add column if not exists "age_content" jsonb not null default '{}'::jsonb;

-- Fact-check report reference (one report per story, written by pipeline/verify.js).
alter table "public"."ca_stories"
  add column if not exists "fact_check_id" uuid references "public"."ca_fact_check_reports"(id) on delete set null;

-- ── ca_digest: one digest per calendar day ──────────────────────────────────
-- Statuses: not_started → in_review → approved → live → archived / missed
create table if not exists "public"."ca_digest" (
  "id"            uuid primary key default gen_random_uuid(),
  "date"          date not null unique,
  "status"        text not null default 'not_started'
                  check (status in ('not_started','in_review','approved','live','archived','missed')),
  "story_ids"     uuid[] not null default '{}'::uuid[],   -- ordered list, 5-7 stories
  "age_group"     text not null default '7-12'
                  check (age_group in ('7-12','13-15')),  -- digest is per age group today
  "final_approved_by"  text,
  "final_approved_at"  timestamptz,
  "live_at"       timestamptz,                            -- when it went live (auto at 00:00 IST)
  "archived_at"   timestamptz,
  "unpublished_by" text,                                   -- emergency unpublish
  "unpublished_at" timestamptz,
  "unpublish_reason" text,
  "notes"         text,
  "created_at"    timestamptz not null default now(),
  "updated_at"    timestamptz not null default now()
);
create index if not exists ca_digest_date_idx on "public"."ca_digest" (date desc);
alter table "public"."ca_digest" enable row level security;

-- ── ca_sources: approved news sources the pipeline reads ────────────────────
create table if not exists "public"."ca_sources" (
  "id"            uuid primary key default gen_random_uuid(),
  "name"          text not null,
  "category"      text not null
                  check (category in ('india','world','economy','science','environment','sports','society','general')),
  "url"           text not null,                          -- RSS or API endpoint
  "kind"          text not null default 'rss' check (kind in ('rss','api')),
  "enabled"       boolean not null default true,
  "last_fetched"  timestamptz,
  "last_status"   text,                                   -- 'ok' / 'error: …'
  "created_at"    timestamptz not null default now(),
  "updated_at"    timestamptz not null default now()
);
alter table "public"."ca_sources" enable row level security;

-- Seed with the approved sources named in the spec.
insert into "public"."ca_sources" (name, category, url, kind, enabled) values
  ('PIB',               'india',      'https://pib.gov.in/newsite/PrintRelease.aspx?relid=', 'rss', true),
  ('The Hindu',         'india',      'https://www.thehindu.com/',                            'rss', true),
  ('Indian Express',    'india',      'https://indianexpress.com/',                           'rss', true),
  ('Reuters',           'world',      'https://www.reuters.com/',                             'rss', true),
  ('AP News',           'world',      'https://apnews.com/',                                  'rss', true),
  ('BBC',               'world',      'https://www.bbc.com/news',                             'rss', true),
  ('RBI',               'economy',    'https://www.rbi.org.in/',                              'rss', true),
  ('IMF',               'economy',    'https://www.imf.org/',                                 'rss', true),
  ('ISRO',              'science',    'https://www.isro.gov.in/',                             'rss', true),
  ('NASA',              'science',    'https://www.nasa.gov/',                                'rss', true),
  ('WHO',               'world',      'https://www.who.int/',                                 'rss', true),
  ('UNICEF',            'world',      'https://www.unicef.org/',                              'rss', true)
on conflict (url) do nothing;

-- ── ca_newsroom_items: collected headlines before selection ─────────────────
create table if not exists "public"."ca_newsroom_items" (
  "id"            uuid primary key default gen_random_uuid(),
  "headline"      text not null,
  "source_id"     uuid references "public"."ca_sources"(id) on delete set null,
  "source_name"   text,
  "source_url"    text,
  "category"      text
                  check (category in ('india','world','economy','science','environment','sports','society','general')),
  "scope"         text check (scope in ('india','international')),
  "credibility"   integer check (credibility between 0 and 100),
  "is_duplicate"  boolean not null default false,
  "duplicate_of"  uuid references "public"."ca_newsroom_items"(id) on delete set null,
  "fetched_at"    timestamptz not null default now(),
  "rejected"      boolean not null default false,
  "reject_reason" text,
  "created_at"    timestamptz not null default now()
);
create index if not exists ca_newsroom_source_url_idx on "public"."ca_newsroom_items" (source_url) where source_url is not null;
alter table "public"."ca_newsroom_items" enable row level security;

-- ── ca_fact_check_reports: one per story ────────────────────────────────────
create table if not exists "public"."ca_fact_check_reports" (
  "id"            uuid primary key default gen_random_uuid(),
  "story_id"      uuid references "public"."ca_stories"(id) on delete cascade,
  "claim"         text not null,
  "verdict"       text not null check (verdict in ('verified','unclear','contradicted')),
  "source_ref"    text,                                   -- link / note backing the verdict
  "checked_by"    text,                                   -- 'pipeline' or editor email
  "checked_at"    timestamptz not null default now(),
  "notes"         text,
  "created_at"    timestamptz not null default now(),
  "updated_at"    timestamptz not null default now()
);
alter table "public"."ca_fact_check_reports" enable row level security;

-- ── ca_audit_log: every admin edit / approve / publish / unpublish ──────────
create table if not exists "public"."ca_audit_log" (
  "id"            bigserial primary key,
  "actor"         text not null,                          -- editor email or 'pipeline'
  "action"        text not null,                          -- e.g. 'story.publish', 'quiz.approve', 'digest.unpublish'
  "entity_type"   text not null,                          -- 'story' / 'quiz_question' / 'digest' / 'settings'
  "entity_id"     uuid,
  "before"        jsonb,                                  -- snapshot before change (when available)
  "after"         jsonb,                                  -- snapshot after change (when available)
  "detail"        text,                                   -- human-readable note
  "created_at"    timestamptz not null default now()
);
create index if not exists ca_audit_entity_idx on "public"."ca_audit_log" (entity_type, entity_id, created_at desc);
create index if not exists ca_audit_actor_idx on "public"."ca_audit_log" (actor, created_at desc);
alter table "public"."ca_audit_log" enable row level security;

-- ── ca_settings: platform-wide config ───────────────────────────────────────
-- Rewards read from here; changes apply to new activity only (old activity keeps
-- the points it was awarded).
create table if not exists "public"."ca_settings" (
  "id"            uuid primary key default gen_random_uuid(),
  "key"           text not null unique,
  "value"         jsonb not null,
  "updated_by"    text,
  "updated_at"    timestamptz not null default now()
);
alter table "public"."ca_settings" enable row level security;

-- Seed default settings (timezone IST, points, badge rules, reminder time,
-- alert channels, quiz window, fallback message).
insert into "public"."ca_settings" (key, value) values
  ('timezone',                jsonb_build_object('value', 'Asia/Kolkata')),
  ('points', jsonb_build_object(
    'digest', 10,
    'daily_question', 5,
    'quiz', 20,
    'quiz_excellence_bonus', 10
  )),
  ('badges', jsonb_build_object(
    'excellence_percent', 80,
    'improvement', true,
    'weekly_streak_days', 7
  )),
  ('reminder_time',           jsonb_build_object('hour', 18, 'minute', 0)),  -- 6 PM IST
  ('alert_channels',          jsonb_build_array('admin_ui')),
  ('quiz_window',             jsonb_build_object(
    'opens', 'sunday_00:00',
    'closes', 'saturday_23:59'
  )),
  ('fallback_message',        jsonb_build_object(
    'enabled', true,
    'text', 'Today''s digest is being prepared. Check back a little later.'
  ))
on conflict (key) do nothing;

-- ── ca_quiz_questions: extend status CHECK with new lifecycle values ────────
-- Existing values (draft, review, published, rejected, archived) are kept for
-- backward compatibility. New values: in_review, approved, scheduled, live,
-- missed. The service treats 'published' as 'live' and 'review' as 'in_review'
-- when reading; writes use the new names.
alter table "public"."ca_quiz_questions" drop constraint if exists ca_quiz_questions_status_check;
alter table "public"."ca_quiz_questions"
  add constraint ca_quiz_questions_status_check check (status in
    ('draft','in_review','review','approved','scheduled','live','published','archived','missed','rejected'));

-- ── updated_at triggers for new tables ──────────────────────────────────────
create or replace function "public"."ca_touch_updated_at"() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists ca_digest_touch on "public"."ca_digest";
create trigger ca_digest_touch before update on "public"."ca_digest"
  for each row execute function "public"."ca_touch_updated_at"();

drop trigger if exists ca_sources_touch on "public"."ca_sources";
create trigger ca_sources_touch before update on "public"."ca_sources"
  for each row execute function "public"."ca_touch_updated_at"();

drop trigger if exists ca_fact_check_reports_touch on "public"."ca_fact_check_reports";
create trigger ca_fact_check_reports_touch before update on "public"."ca_fact_check_reports"
  for each row execute function "public"."ca_touch_updated_at"();

-- ── Row Level Security policies (service_role only; no student policies) ────
-- These tables are never queried by students directly with a Supabase JWT.
-- Grant service_role full access; leave anon/authenticated with nothing.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on "public"."ca_digest", "public"."ca_sources",
      "public"."ca_newsroom_items", "public"."ca_fact_check_reports",
      "public"."ca_audit_log", "public"."ca_settings" to service_role';
    execute 'grant usage on sequence "public"."ca_audit_log_id_seq" to service_role';
  end if;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on "public"."ca_digest", "public"."ca_sources",
      "public"."ca_newsroom_items", "public"."ca_fact_check_reports",
      "public"."ca_audit_log", "public"."ca_settings" from anon, authenticated';
  end if;
end $$;

notify pgrst, 'reload schema';
