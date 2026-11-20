// Runs 0030 on PGlite: Practise This Skill follow-up tables.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { PGlite } = require('@electric-sql/pglite');

const MIGRATION = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'migrations', '0030_practice_followups.sql'), 'utf8');
const MIGRATION_0031 = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'migrations', '0031_practice_followup_skill_pack.sql'), 'utf8');
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

test('0031 adds a nullable skill_pack column and is safe to re-run', async () => {
  const db = await freshDb();
  await db.exec(MIGRATION_0031);
  await db.exec(MIGRATION_0031);
  const { rows } = await addFollowup(db, 'topic:quality');
  await db.query(`update practice_followups set skill_pack = '{"label":"Understanding Quality","questions":[]}' where id = $1`, [rows[0].id]);
  const r = (await db.query('select skill_pack from practice_followups where id = $1', [rows[0].id])).rows[0];
  assert.equal(r.skill_pack.label, 'Understanding Quality');
  const other = (await addFollowup(db, 'en.figurative.pun-vs-alliteration')).rows[0];
  const o = (await db.query('select skill_pack from practice_followups where id = $1', [other.id])).rows[0];
  assert.equal(o.skill_pack, null);
});

const MIGRATION_0032 = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'migrations', '0032_explain_and_practise.sql'), 'utf8');
async function db32() {
  const db = await freshDb();
  await db.exec(MIGRATION_0031);
  await db.exec(MIGRATION_0032);
  await db.exec(MIGRATION_0032); // safe to re-run
  return db;
}

test('0032: explanations are kept per test question; generated questions cannot repeat by id or text', async () => {
  const db = await db32();
  const f = (await addFollowup(db, 'topic:quality')).rows[0].id;
  await db.query(`insert into practice_explanations (followup_id, student_id, attempt_id, question_index, method, payload) values ($1, $2, $3, 3, 'rule', '{"title":"t","body":"b"}')`, [f, S, A]);
  await db.query(`insert into practice_explanations (followup_id, student_id, attempt_id, question_index, method, variant, payload) values ($1, $2, $3, 3, 'steps', 'another_way', '{"title":"t","body":"b"}')`, [f, S, A]);
  await assert.rejects(db.query(`insert into practice_explanations (followup_id, student_id, attempt_id, question_index, method, variant, payload) values ($1, $2, $3, 3, 'rule', 'louder', '{}')`, [f, S, A]));
  const gq = (id, fp, level = 2) => db.query(`insert into practice_generated_questions (followup_id, question_id, origin_question_index, level, payload, fingerprint) values ($1, $2, 3, $4, '{"type":"mcq"}', $3)`, [f, id, fp, level]);
  await gq('gq-1', 'which firm advertised');
  await assert.rejects(gq('gq-1', 'other text'));
  await assert.rejects(gq('gq-2', 'which firm advertised'));
  await assert.rejects(gq('gq-3', 'new text', 4));
  await gq('gq-2', 'new text');
  const { rows } = await db.query('select count(*)::int n from practice_generated_questions');
  assert.equal(rows[0].n, 2);
});

test('0032: new answer columns default safely so first-version rows stay valid', async () => {
  const db = await db32();
  const f = (await addFollowup(db)).rows[0].id;
  await addResponse(db, f, 'pa-mcq-01', 1);
  const r = (await db.query('select origin_question_index, is_memory_check, skipped, mistake_tag, question_level from practice_followup_responses')).rows[0];
  assert.deepEqual(r, { origin_question_index: null, is_memory_check: false, skipped: false, mistake_tag: null, question_level: null });
  const fu = (await db.query('select current_focus_index, current_is_memory_check from practice_followups where id = $1', [f])).rows[0];
  assert.deepEqual(fu, { current_focus_index: null, current_is_memory_check: false });
});

test('0032: deleting the original test removes its explanations and generated questions', async () => {
  const db = await db32();
  const f = (await addFollowup(db, 'topic:quality')).rows[0].id;
  await db.query(`insert into practice_explanations (followup_id, student_id, attempt_id, question_index, method, payload) values ($1, $2, $3, 1, 'rule', '{}')`, [f, S, A]);
  await db.query(`insert into practice_generated_questions (followup_id, question_id, payload, fingerprint) values ($1, 'gq-1', '{}', 'x')`, [f]);
  await db.query(`delete from topic_attempts where id = '${A}'`);
  const n = async (t) => (await db.query(`select count(*)::int n from ${t}`)).rows[0].n;
  assert.equal(await n('practice_explanations'), 0);
  assert.equal(await n('practice_generated_questions'), 0);
});
