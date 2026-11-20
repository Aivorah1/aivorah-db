// Runs 0033 on PGlite: AI Teacher practice questions.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { PGlite } = require('@electric-sql/pglite');

const MIGRATION = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'migrations', '0033_ai_teacher_questions.sql'), 'utf8');
const S = '11111111-1111-4111-8111-111111111111';

async function freshDb() {
  const db = new PGlite();
  await db.exec(`create role anon; create role authenticated;
    create table users (id uuid primary key, email text);
    insert into users values ('${S}', 'demo@x.com');`);
  await db.exec(MIGRATION);
  await db.exec(MIGRATION); // safe to re-run
  return db;
}
const add = (db, over = {}) => db.query(
  `insert into ai_teacher_questions (student_id, subject, topic_key, example_key, prompt, answer_format, answer, duration_seconds, source)
   values ($1, 'Mathematics', 'CBSE|6|Mathematics|5|Common Multiples', $2, 'Find the LCM of 8 and 12.', $3, '{"values":["24"]}', $4, $5) returning id, status`,
  [S, over.example || 'lcm:8,12', over.format || 'number', over.duration ?? 90, over.source || 'computed']);

test('a question is saved open, with its answer kept in the row', async () => {
  const db = await freshDb();
  const { rows } = await add(db);
  assert.equal(rows[0].status, 'open');
  const r = (await db.query('select answer from ai_teacher_questions where id = $1', [rows[0].id])).rows[0];
  assert.deepEqual(r.answer, { values: ['24'] });
});

test('only known formats, sources, statuses and sensible durations are accepted', async () => {
  const db = await freshDb();
  await assert.rejects(add(db, { format: 'essay' }));
  await assert.rejects(add(db, { source: 'internet' }));
  await assert.rejects(add(db, { duration: 5 }));
  await add(db, { duration: null });
  await assert.rejects(db.query(`update ai_teacher_questions set status = 'graded'`));
});

test('deleting the student removes their questions; RLS is on', async () => {
  const db = await freshDb();
  await add(db);
  await db.query(`delete from users where id = '${S}'`);
  assert.equal((await db.query('select count(*)::int n from ai_teacher_questions')).rows[0].n, 0);
  const { rows } = await db.query(`select relrowsecurity from pg_class where relname = 'ai_teacher_questions'`);
  assert.equal(rows[0].relrowsecurity, true);
});
