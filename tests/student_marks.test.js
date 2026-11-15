// Runs 0024 on PGlite: per-subject marks behind the teacher Student Report.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { PGlite } = require('@electric-sql/pglite');

const MIGRATION = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'migrations', '0024_student_marks.sql'), 'utf8');
const SCHOOL = '00000000-0000-0000-0000-000000000001';
const S1 = '11111111-1111-1111-1111-111111111111';
const T1 = '22222222-2222-2222-2222-222222222222';

async function freshDb() {
  const db = new PGlite();
  await db.exec(`
    create role anon; create role authenticated;
    create table schools (id uuid primary key, name text);
    create table users (id uuid primary key, email text);
    insert into schools values ('${SCHOOL}', 'Test School');
    insert into users values ('${S1}', 's1@x.com'), ('${T1}', 't1@x.com');
  `);
  await db.exec(MIGRATION);
  return db;
}

const add = (db, { subject = 'Maths', marks = 72, year = '2026-27', uploadedBy = T1 } = {}) => db.query(
  `insert into student_marks (school_id, student_id, academic_year, grade, section, subject, marks, uploaded_by)
   values ($1, $2, $3, 'Grade 8', 'A', $4, $5, $6)`,
  [SCHOOL, S1, year, subject, marks, uploadedBy]);

test('one mark per subject per year; defaults are filled in', async () => {
  const db = await freshDb();
  await add(db);
  await add(db, { subject: 'Science', marks: 88.5 });
  await add(db, { year: '2025-26' }); // same subject, another year is fine
  const { rows } = await db.query(`select subject, marks::float as marks, created_at is not null as dated from student_marks where academic_year = '2026-27' order by subject`);
  assert.deepEqual(rows.map((r) => [r.subject, r.marks, r.dated]), [['Maths', 72, true], ['Science', 88.5, true]]);
  await assert.rejects(() => add(db, { marks: 50 }), /student_marks_student_year_subject_key/);
});

test('marks must be between 0 and 100 and the subject not blank', async () => {
  const db = await freshDb();
  await add(db, { marks: 0 });
  await add(db, { subject: 'English', marks: 100 });
  await assert.rejects(() => add(db, { subject: 'Hindi', marks: -1 }));
  await assert.rejects(() => add(db, { subject: 'Art', marks: 100.5 }));
  await assert.rejects(() => add(db, { subject: '   ' }));
});

test('deleting the student removes their marks; deleting the teacher keeps them', async () => {
  const db = await freshDb();
  await add(db);
  await db.query(`delete from users where id = '${T1}'`);
  let { rows } = await db.query('select uploaded_by from student_marks');
  assert.deepEqual(rows, [{ uploaded_by: null }]);
  await db.query(`delete from users where id = '${S1}'`);
  ({ rows } = await db.query('select count(*)::int as n from student_marks'));
  assert.equal(rows[0].n, 0);
});
