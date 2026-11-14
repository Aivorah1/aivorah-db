// Runs 0023 on PGlite: the Current Affairs tables (aivorah-current-affairs-service).
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { PGlite } = require('@electric-sql/pglite');

const MIGRATION = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'migrations', '0023_current_affairs.sql'), 'utf8');

// Supabase's roles and auth.jwt(), which the policies use.
const SUPABASE_STUBS = `
  create role anon; create role authenticated; create role service_role;
  create schema auth;
  create function auth.jwt() returns jsonb language sql stable
    as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
  grant usage on schema auth to anon, authenticated;
`;

async function freshDb(before = '') {
  const db = new PGlite();
  await db.exec(SUPABASE_STUBS);
  if (before) await db.exec(before);
  await db.exec(MIGRATION);
  return db;
}

const story = (db, { status = 'published', title = 'Moon landing', hash = null } = {}) => db.query(
  `insert into ca_stories (category, status, title_young, title_kid, title_teen, summary_young, summary_kid, summary_teen,
     what_happened_young, what_happened_kid, what_happened_teen, why_important_young, why_important_kid, why_important_teen,
     source, source_url_hash)
   values ('india', $1, $2, $2, $2, 's', 's', 's', 'w', 'w', 'w', 'y', 'y', 'y', 'ISRO', $3) returning id`,
  [status, title, hash]);

test('creates the 6 tables on an empty database', async () => {
  const db = await freshDb();
  const { rows } = await db.query(`select table_name from information_schema.tables where table_name like 'ca\\_%' order by 1`);
  assert.deepEqual(rows.map((r) => r.table_name),
    ['ca_digest_views', 'ca_progress', 'ca_quiz_attempts', 'ca_quiz_questions', 'ca_stories', 'ca_story_reads']);
});

test('is safe to run again (the tables already exist in the live database)', async () => {
  const db = await freshDb();
  await story(db);
  await db.exec(MIGRATION);
  const { rows } = await db.query('select count(*)::int as n from ca_stories');
  assert.equal(rows[0].n, 1);
});

test('adds the newer columns to tables made from an older schema.sql', async () => {
  const db = await freshDb(`
    create table ca_stories (id uuid primary key default gen_random_uuid(), category text not null, publish_date date not null default current_date,
      status text not null default 'review', priority integer not null default 0,
      title_young text not null, title_kid text not null, title_teen text not null,
      summary_young text not null, summary_kid text not null, summary_teen text not null,
      what_happened_young text not null, what_happened_kid text not null, what_happened_teen text not null,
      why_important_young text not null, why_important_kid text not null, why_important_teen text not null,
      did_you_know text, new_word_1 text, def_1 text, new_word_2 text, def_2 text, think_about_it text, image_url text,
      source text not null, source_url text, is_true_fact boolean not null default false, review_notes text,
      created_at timestamptz not null default now(), updated_at timestamptz not null default now());
  `);
  const { rows } = await db.query(`select column_name from information_schema.columns where table_name = 'ca_stories'
    and column_name in ('new_word_3','def_3','age_extras','source_url_hash','reviewed_by','reviewed_at') order by 1`);
  assert.deepEqual(rows.map((r) => r.column_name), ['age_extras', 'def_3', 'new_word_3', 'reviewed_at', 'reviewed_by', 'source_url_hash']);
});

test('the same source article cannot be saved twice', async () => {
  const db = await freshDb();
  await story(db, { hash: 'abc' });
  await assert.rejects(() => story(db, { hash: 'abc' }));
  await story(db, { hash: null });
  await story(db, { hash: null });
});

test('a quiz answer must point at one of its options', async () => {
  const db = await freshDb();
  const insert = (idx) => db.query(`insert into ca_quiz_questions (week_start, age_group, category, question, options, correct_index, explanation)
    values ('2026-11-08', '8-12', 'india', 'Q?', '["True","False"]', $1, 'because')`, [idx]);
  await insert(1);
  await assert.rejects(() => insert(2));
});

test('ca_apply_progress adds points and keeps the best values', async () => {
  const db = await freshDb();
  await db.query(`select ca_apply_progress('Kid@X.com', '8-12', p_points => 10, p_digests => 1, p_current_streak => 1, p_quiz_score => 60)`);
  await db.query(`select ca_apply_progress('kid@x.com', '8-12', p_points => 5, p_stories => 1, p_current_streak => 2, p_quiz_score => 40, p_badge_growth => true)`);
  const { rows } = await db.query('select * from ca_progress');
  assert.equal(rows.length, 1);
  assert.equal(rows[0].student_email, 'kid@x.com');
  assert.equal(rows[0].points, 15);
  assert.equal(rows[0].longest_streak, 2);
  assert.equal(rows[0].best_quiz_score, 60);
  assert.equal(rows[0].last_quiz_score, 40);
  assert.equal(rows[0].badge_growth, true);
});

test('students see only published stories, only their own progress, and never quiz answers', async () => {
  const db = await freshDb();
  await story(db, { status: 'published', title: 'Shown' });
  await story(db, { status: 'review', title: 'Hidden' });
  await db.query(`select ca_apply_progress('a@x.com', '8-12', p_points => 10)`);
  await db.query(`select ca_apply_progress('b@x.com', '8-12', p_points => 20)`);
  await db.query(`insert into ca_quiz_questions (week_start, age_group, category, question, options, correct_index, explanation, status)
    values ('2026-11-08', '8-12', 'india', 'Q?', '["True","False"]', 0, 'because', 'published')`);
  await db.exec(`grant select on all tables in schema public to authenticated;`);
  await db.exec(`set role authenticated; select set_config('request.jwt.claims', '{"email":"A@x.com"}', false);`);
  const stories = await db.query('select title_kid from ca_stories');
  const progress = await db.query('select student_email from ca_progress');
  const quiz = await db.query('select id from ca_quiz_questions');
  await db.exec('reset role');
  assert.deepEqual(stories.rows.map((r) => r.title_kid), ['Shown']);
  assert.deepEqual(progress.rows.map((r) => r.student_email), ['a@x.com']);
  assert.equal(quiz.rows.length, 0);
});

test('students cannot call the points function', async () => {
  const db = await freshDb();
  await db.exec('set role authenticated');
  await assert.rejects(() => db.query(`select ca_apply_progress('a@x.com', '8-12', p_points => 1000)`));
  await db.exec('reset role');
});
