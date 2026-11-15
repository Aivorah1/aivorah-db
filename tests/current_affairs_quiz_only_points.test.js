// Runs 0023 then 0026 on PGlite: Current Affairs points only from the weekly quiz.
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

async function freshDb({ before26 = '' } = {}) {
  const db = new PGlite();
  await db.exec(SUPABASE_STUBS);
  await db.exec(migration('0023_current_affairs.sql'));
  if (before26) await db.exec(before26);
  await db.exec(migration('0026_current_affairs_quiz_only_points.sql'));
  return db;
}

const progress = async (db, email = 'kid@x.com') => (await db.query('select * from ca_progress where student_email = $1', [email])).rows[0];

test('reading the digest or a story adds no points, even if a caller still sends them', async () => {
  const db = await freshDb();
  await db.query(`select ca_apply_progress('kid@x.com', '8-12', p_points => 10, p_digests => 1, p_current_streak => 1, p_last_digest_date => '2026-11-09')`);
  await db.query(`select ca_apply_progress('kid@x.com', '8-12', p_points => 5, p_stories => 1, p_last_story_date => '2026-11-09')`);
  const row = await progress(db);
  assert.equal(row.points, 0);
  assert.equal(row.digests_completed, 1);
  assert.equal(row.stories_read, 1);
  assert.equal(row.current_streak, 1);
});

test('the quiz gives +20, and +20 +10 at 80% or above', async () => {
  const db = await freshDb();
  await db.query(`select ca_apply_progress('kid@x.com', '8-12', p_points => 20, p_quizzes => 1, p_quiz_score => 70)`);
  assert.equal((await progress(db)).points, 20);
  await db.query(`select ca_apply_progress('kid@x.com', '8-12', p_points => 30, p_quizzes => 1, p_quiz_score => 80, p_badge_excellence => true)`);
  const row = await progress(db);
  assert.equal(row.points, 50);
  assert.equal(row.quizzes_completed, 2);
  assert.equal(row.badge_excellence, true);
});

test('the 7-day streak badge is still saved, with no points', async () => {
  const db = await freshDb();
  await db.query(`select ca_apply_progress('kid@x.com', '8-12', p_points => 10, p_digests => 1, p_current_streak => 7, p_badge_weekly_streak => true)`);
  const row = await progress(db);
  assert.equal(row.badge_weekly_streak, true);
  assert.equal(row.current_streak, 7);
  assert.equal(row.points, 0);
});

test('points already earned stay as they are', async () => {
  // Earned under the old rules (0023): 10 for a digest + 5 for a story.
  const db = await freshDb({
    before26: `select ca_apply_progress('kid@x.com', '8-12', p_points => 10, p_digests => 1);
               select ca_apply_progress('kid@x.com', '8-12', p_points => 5, p_stories => 1);`,
  });
  assert.equal((await progress(db)).points, 15);
  await db.query(`select ca_apply_progress('kid@x.com', '8-12', p_points => 10, p_digests => 1)`);
  assert.equal((await progress(db)).points, 15);
  await db.query(`select ca_apply_progress('kid@x.com', '8-12', p_points => 20, p_quizzes => 1, p_quiz_score => 60)`);
  assert.equal((await progress(db)).points, 35);
});

test('negative points are never applied', async () => {
  const db = await freshDb();
  await db.query(`select ca_apply_progress('kid@x.com', '8-12', p_points => -50, p_quizzes => 1)`);
  assert.equal((await progress(db)).points, 0);
});

test('students still cannot call the points function', async () => {
  const db = await freshDb();
  await db.exec('set role authenticated');
  await assert.rejects(() => db.query(`select ca_apply_progress('a@x.com', '8-12', p_points => 1000, p_quizzes => 1)`));
  await db.exec('reset role');
});
