// Runs 0030 on PGlite: Practise This Skill follow-up tables.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { PGlite } = require('@electric-sql/pglite');

const MIGRATION = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'migrations', '0030_practice_followups.sql'), 'utf8');
const S = '11111111-1111-4111-8111-111111111111';
const A = '22222222-2222-4222-8222-222222222222';

async function freshDb() {
  const db = new PGlite();
  await db.exec(`create role anon; create role authenticated;
    create table users (id uuid primary key, email text);
    create table topic_attempts (id uuid primary key, student_id uuid references users(id) on delete cascade);
    insert into users values ('${S}', 'riya@x.com');
    insert into topic_attempts values ('${A}', '${S}');`);
  await db.exec(MIGRATION);
  return db;
}

const addFollowup = (db, skill = 'en.figurative.pun-vs-alliteration') => db.query(
  `insert into practice_followups (student_id, attempt_id, skill_id, topic, subject, grade)
   values ($1, $2, $3, 'A Concrete Example', 'English', 'Grade 8') returning id`, [S, A, skill]);

const addResponse = (db, followupId, questionId, seq, extra = {}) => db.query(
  `insert into practice_followup_responses (followup_id, student_id, skill_id, question_id, question_type, question_text, seq,
     grading_outcome, reasoning_outcome, credit, help_shown)
   values ($1, $2, 'en.figurative.pun-vs-alliteration', $3, 'mcq', 'Which sentence contains a pun?', $4, $5, $6, $7, $8)`,
  [followupId, S, questionId, seq, extra.grading || 'correct', extra.reasoning || 'supported', extra.credit || 'independent', extra.help || 'none']);

test('one follow-up per original attempt and skill, with safe defaults', async () => {
  const db = await freshDb();
  const { rows } = await addFollowup(db);
  await assert.rejects(addFollowup(db));
  await addFollowup(db, 'math.fractions.equivalent');
  const r = (await db.query('select * from practice_followups where id = $1', [rows[0].id])).rows[0];
  assert.equal(r.status, 'available');
  assert.equal(r.independent_streak, 0);
  assert.equal(r.current_help, 'none');
  assert.deepEqual(r.teaching_methods_used, []);
});

test('a question can be answered only once per follow-up (duplicate submits add no evidence)', async () => {
  const db = await freshDb();
  const { rows } = await addFollowup(db);
  await addResponse(db, rows[0].id, 'pa-q01', 1);
  await assert.rejects(addResponse(db, rows[0].id, 'pa-q01', 2));
  await assert.rejects(addResponse(db, rows[0].id, 'pa-q02', 1)); // same order slot
  await addResponse(db, rows[0].id, 'pa-q02', 2, { credit: 'assisted', help: 'hint' });
  const { rows: n } = await db.query('select count(*)::int as n from practice_followup_responses');
  assert.equal(n[0].n, 2);
});

test('outcome columns only accept known values', async () => {
  const db = await freshDb();
  const { rows } = await addFollowup(db);
  await assert.rejects(addResponse(db, rows[0].id, 'q', 1, { credit: 'mastered' }));
  await assert.rejects(addResponse(db, rows[0].id, 'q', 1, { reasoning: 'great' }));
  await assert.rejects(addResponse(db, rows[0].id, 'q', 1, { help: 'answer' }));
  await assert.rejects(db.query(`update practice_followups set status = 'passed'`));
});

test('deleting the original attempt or the student removes its follow-up and answers', async () => {
  const db = await freshDb();
  const { rows } = await addFollowup(db);
  await addResponse(db, rows[0].id, 'pa-q01', 1);
  await db.query(`delete from topic_attempts where id = '${A}'`);
  const { rows: f } = await db.query('select count(*)::int as n from practice_followups');
  const { rows: r } = await db.query('select count(*)::int as n from practice_followup_responses');
  assert.equal(f[0].n, 0);
  assert.equal(r[0].n, 0);
});

test('RLS is on for both tables', async () => {
  const db = await freshDb();
  const { rows } = await db.query(`select relname, relrowsecurity from pg_class where relname in ('practice_followups', 'practice_followup_responses') order by relname`);
  assert.deepEqual(rows.map((r) => [r.relname, r.relrowsecurity]), [['practice_followup_responses', true], ['practice_followups', true]]);
});
