// Runs 0023, 0026, then 0027 on PGlite: Current Affairs age groups
// under-8 / 8-12 / 13+ become 7-12 / 13-15, with nothing lost.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { PGlite } = require('@electric-sql/pglite');

const migration = (name) => fs.readFileSync(path.join(__dirname, '..', 'supabase', 'migrations', name), 'utf8');

const SUPABASE_STUBS = `
  create role anon; create role authenticated; create role service_role;
  create schema auth;
  create function auth.jwt() returns jsonb language sql stable
    as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
`;

// Data as the live database has it before 0027 (old values).
const OLD_DATA = `
  insert into ca_stories (id, category, status, title_young, title_kid, title_teen, summary_young, summary_kid, summary_teen,
    what_happened_young, what_happened_kid, what_happened_teen, why_important_young, why_important_kid, why_important_teen, source)
  values ('11111111-1111-4111-8111-111111111111', 'india', 'published', 'Y', 'K', 'T', 's', 's', 's', 'w', 'w', 'w', 'y', 'y', 'y', 'ISRO');

  -- Week 1 has all three quizzes (as the pipeline writes them); week 2 only an under-8 one.
  insert into ca_quiz_questions (week_start, age_group, category, question, options, correct_index, explanation, status) values
    ('2026-11-01', 'under-8', 'india', 'U1', '["a","b"]', 0, 'e', 'published'),
    ('2026-11-01', 'under-8', 'world', 'U2', '["a","b"]', 0, 'e', 'published'),
    ('2026-11-01', '8-12',    'india', 'K1', '["a","b"]', 0, 'e', 'published'),
    ('2026-11-01', '13+',     'india', 'T1', '["a","b"]', 0, 'e', 'published'),
    ('2026-11-08', 'under-8', 'india', 'U3', '["a","b"]', 0, 'e', 'review');

  -- a@x: under-8 and 8-12 attempts in the same week; b@x: under-8 only.
  insert into ca_quiz_attempts (student_email, age_group, week_start, percentage, points_earned, points_awarded) values
    ('a@x.com', 'under-8', '2026-11-01', 40, 20, true),
    ('a@x.com', '8-12',    '2026-11-01', 90, 30, true),
    ('b@x.com', 'under-8', '2026-11-01', 70, 20, true),
    ('c@x.com', '13+',     '2026-11-01', 80, 30, true);

  -- a@x has an under-8 and an 8-12 progress row (their grade changed).
  insert into ca_progress (student_email, age_group, points, digests_completed, stories_read, quizzes_completed,
      current_streak, longest_streak, best_quiz_score, last_quiz_score, badge_excellence, badge_weekly_streak, badge_growth,
      last_digest_date, last_quiz_date) values
    ('a@x.com', 'under-8', 25, 2, 1, 1, 2, 2, 40, 40, false, false, true,  '2026-11-03', '2026-11-02'),
    ('a@x.com', '8-12',    45, 3, 2, 1, 1, 5, 90, 90, true,  true,  false, '2026-11-05', '2026-11-04'),
    ('b@x.com', 'under-8', 20, 1, 0, 1, 1, 1, 70, 70, false, false, false, '2026-11-02', '2026-11-02'),
    ('c@x.com', '13+',     30, 0, 0, 1, 0, 0, 80, 80, true,  false, false, null,         '2026-11-02');

  insert into ca_digest_views (student_email, age_group, view_date) values
    ('a@x.com', 'under-8', '2026-11-03'), ('a@x.com', '8-12', '2026-11-05'), ('c@x.com', '13+', '2026-11-05');
  insert into ca_story_reads (student_email, story_id, age_group) values
    ('b@x.com', '11111111-1111-4111-8111-111111111111', 'under-8'),
    ('c@x.com', '11111111-1111-4111-8111-111111111111', '13+');
`;

async function migratedDb() {
  const db = new PGlite();
  await db.exec(SUPABASE_STUBS);
  await db.exec(migration('0023_current_affairs.sql'));
  await db.exec(migration('0026_current_affairs_quiz_only_points.sql'));
  await db.exec(OLD_DATA);
  const notices = [];
  await db.exec(migration('0027_current_affairs_two_age_groups.sql'), { onNotice: (n) => notices.push(n.message) });
  return { db, notices };
}

const rows = async (db, sql, params) => (await db.query(sql, params)).rows;

test('every table holds only 7-12 and 13-15 afterwards', async () => {
  const { db } = await migratedDb();
  for (const t of ['ca_quiz_questions', 'ca_quiz_attempts', 'ca_progress', 'ca_digest_views', 'ca_story_reads']) {
    const values = (await rows(db, `select distinct age_group from ${t} order by 1`)).map((r) => r.age_group);
    assert.ok(values.every((v) => ['7-12', '13-15'].includes(v)), `${t}: ${values}`);
  }
});

test('quiz questions: an under-8 duplicate of an 8-12 week is archived; a week with only under-8 is relabelled', async () => {
  const { db } = await migratedDb();
  const qs = await rows(db, 'select question, age_group, status from ca_quiz_questions order by question');
  assert.deepEqual(qs.map((q) => [q.question, q.age_group, q.status]), [
    ['K1', '7-12', 'published'],
    ['T1', '13-15', 'published'],
    ['U1', '7-12', 'archived'],
    ['U2', '7-12', 'archived'],
    ['U3', '7-12', 'review'],
  ]);
  // The 7-12 quiz of week 1 is exactly the old 8-12 one.
  const live = await rows(db, `select question from ca_quiz_questions where week_start = '2026-11-01' and age_group = '7-12' and status = 'published'`);
  assert.deepEqual(live.map((q) => q.question), ['K1']);
});

test('quiz attempts: the 8-12 attempt is kept, the duplicate under-8 one is backed up', async () => {
  const { db } = await migratedDb();
  const attempts = await rows(db, 'select student_email, age_group, percentage from ca_quiz_attempts order by 1');
  assert.deepEqual(attempts.map((a) => [a.student_email, a.age_group, a.percentage]), [
    ['a@x.com', '7-12', 90], ['b@x.com', '7-12', 70], ['c@x.com', '13-15', 80],
  ]);
  const backup = await rows(db, `select row_data from ca_age_group_backup where table_name = 'ca_quiz_attempts' and action = 'removed_duplicate'`);
  assert.equal(backup.length, 1);
  assert.equal(backup[0].row_data.percentage, 40);
  assert.equal(backup[0].row_data.age_group, 'under-8');
});

test('progress: under-8 and 8-12 rows of one student are merged, nothing lost', async () => {
  const { db } = await migratedDb();
  const [a] = await rows(db, `select * from ca_progress where student_email = 'a@x.com'`);
  assert.equal((await rows(db, `select 1 from ca_progress where student_email = 'a@x.com'`)).length, 1);
  assert.equal(a.age_group, '7-12');
  assert.equal(a.points, 70);
  assert.equal(a.digests_completed, 5);
  assert.equal(a.stories_read, 3);
  assert.equal(a.quizzes_completed, 2);
  assert.equal(a.longest_streak, 5);
  assert.equal(a.current_streak, 1); // from the row with the latest digest (8-12, 5 Nov)
  assert.equal(a.best_quiz_score, 90);
  assert.equal(a.last_quiz_score, 90); // the 8-12 quiz was the later one
  assert.deepEqual([a.badge_excellence, a.badge_weekly_streak, a.badge_growth], [true, true, true]);
  const [b] = await rows(db, `select age_group, points from ca_progress where student_email = 'b@x.com'`);
  assert.deepEqual(b, { age_group: '7-12', points: 20 });
  const [c] = await rows(db, `select age_group, points from ca_progress where student_email = 'c@x.com'`);
  assert.deepEqual(c, { age_group: '13-15', points: 30 });
  const merged = await rows(db, `select action, row_data->>'age_group' as age from ca_age_group_backup where table_name = 'ca_progress' and action like 'merged%' order by 1`);
  assert.deepEqual(merged.map((m) => [m.action, m.age]), [['merged_from_under_8', '8-12'], ['merged_into_7_12', 'under-8']]);
});

test('digest views and story reads are relabelled', async () => {
  const { db } = await migratedDb();
  const views = await rows(db, 'select age_group from ca_digest_views order by view_date, student_email');
  assert.deepEqual(views.map((v) => v.age_group), ['7-12', '7-12', '13-15']);
  const reads = await rows(db, 'select student_email, age_group from ca_story_reads order by 1');
  assert.deepEqual(reads.map((r) => r.age_group), ['7-12', '13-15']);
});

test('every changed row is in the backup, and the counts are reported', async () => {
  const { db, notices } = await migratedDb();
  const counts = await rows(db, `select table_name, action, count(*)::int as n from ca_age_group_backup group by 1, 2 order by 1, 2`);
  assert.deepEqual(counts.map((c) => [c.table_name, c.action, c.n]), [
    ['ca_digest_views', 'relabelled', 3],
    ['ca_progress', 'merged_from_under_8', 1],
    ['ca_progress', 'merged_into_7_12', 1],
    ['ca_progress', 'relabelled', 3],
    ['ca_quiz_attempts', 'relabelled', 3],
    ['ca_quiz_attempts', 'removed_duplicate', 1],
    ['ca_quiz_questions', 'archived', 2],
    ['ca_quiz_questions', 'relabelled', 3],
    ['ca_story_reads', 'relabelled', 2],
  ]);
  for (const line of [
    'ca_quiz_questions: 2 under-8 duplicates archived', 'ca_quiz_questions: 3 relabelled',
    'ca_quiz_attempts: 1 under-8 duplicates moved to ca_age_group_backup', 'ca_quiz_attempts: 3 relabelled',
    'ca_progress: 1 students had under-8 and 8-12 rows, merged into one', 'ca_progress: 3 relabelled',
    'ca_digest_views: 3 relabelled', 'ca_story_reads: 2 relabelled',
  ]) assert.ok(notices.includes(line), `missing notice: ${line} (got ${notices.join(' / ')})`);
});

test('only the two new values are accepted directly; old values are converted on write', async () => {
  const { db } = await migratedDb();
  // The content pipeline still writes all three quizzes.
  await db.exec(`insert into ca_quiz_questions (week_start, age_group, category, question, options, correct_index, explanation, status) values
    ('2026-11-15', 'under-8', 'india', 'P-U', '["a","b"]', 0, 'e', 'published'),
    ('2026-11-15', '8-12',    'india', 'P-K', '["a","b"]', 0, 'e', 'published'),
    ('2026-11-15', '13+',     'india', 'P-T', '["a","b"]', 0, 'e', 'published')`);
  const pipeline = await rows(db, `select question, age_group, status from ca_quiz_questions where week_start = '2026-11-15' order by question`);
  assert.deepEqual(pipeline.map((q) => [q.question, q.age_group, q.status]), [
    ['P-K', '7-12', 'published'], ['P-T', '13-15', 'published'], ['P-U', '7-12', 'archived'],
  ]);
  // An old service version: progress for 8-12 lands on the student's 7-12 row.
  await db.query(`select ca_apply_progress('b@x.com', '8-12', p_points => 20, p_quizzes => 1, p_quiz_score => 60)`);
  const b = await rows(db, `select age_group, points, quizzes_completed from ca_progress where student_email = 'b@x.com'`);
  assert.deepEqual(b, [{ age_group: '7-12', points: 40, quizzes_completed: 2 }]);
  await db.exec(`insert into ca_digest_views (student_email, age_group, view_date) values ('z@x.com', '13+', '2026-11-06')`);
  assert.equal((await rows(db, `select age_group from ca_digest_views where student_email = 'z@x.com'`))[0].age_group, '13-15');
  // Anything else is still rejected.
  await assert.rejects(() => db.exec(`insert into ca_digest_views (student_email, age_group, view_date) values ('y@x.com', 'adult', '2026-11-06')`));
});

test('a story can be written with only the 7-12 and 13-15 versions', async () => {
  const { db } = await migratedDb();
  await db.exec(`insert into ca_stories (category, title_kid, title_teen, summary_kid, summary_teen, what_happened_kid, what_happened_teen,
    why_important_kid, why_important_teen, source) values ('world', 'K', 'T', 's', 's', 'w', 'w', 'y', 'y', 'BBC')`);
  assert.equal((await rows(db, `select count(*)::int as n from ca_stories where title_young is null`))[0].n, 1);
});

test('runs on an empty database (dev / test without data)', async () => {
  const db = new PGlite();
  await db.exec(SUPABASE_STUBS);
  await db.exec(migration('0023_current_affairs.sql'));
  await db.exec(migration('0026_current_affairs_quiz_only_points.sql'));
  await db.exec(migration('0027_current_affairs_two_age_groups.sql'));
  assert.equal((await rows(db, 'select count(*)::int as n from ca_age_group_backup'))[0].n, 0);
});
