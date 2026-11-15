// Runs 0025 on PGlite: Prepare Worksheet documents and teacher-to-teacher shares.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { PGlite } = require('@electric-sql/pglite');

const MIGRATION = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'migrations', '0025_teacher_worksheets.sql'), 'utf8');
const SCHOOL = '00000000-0000-0000-0000-000000000001';
const T1 = '11111111-1111-1111-1111-111111111111';
const T2 = '22222222-2222-2222-2222-222222222222';

async function freshDb() {
  const db = new PGlite();
  await db.exec(`
    create role anon; create role authenticated;
    create table schools (id uuid primary key, name text);
    create table users (id uuid primary key, email text);
    insert into schools values ('${SCHOOL}', 'Test School');
    insert into users values ('${T1}', 't1@x.com'), ('${T2}', 't2@x.com');
  `);
  await db.exec(MIGRATION);
  return db;
}

async function addDoc(db, { owner = T1, title = 'Fractions practice', html = '<p>Hi</p>' } = {}) {
  const { rows } = await db.query(
    'insert into teacher_worksheets (owner_id, school_id, title, content_html) values ($1, $2, $3, $4) returning id',
    [owner, SCHOOL, title, html]);
  return rows[0].id;
}

test('a document needs a title and gets its dates filled in', async () => {
  const db = await freshDb();
  await addDoc(db);
  const { rows } = await db.query('select title, created_at is not null and updated_at is not null as dated from teacher_worksheets');
  assert.deepEqual(rows, [{ title: 'Fractions practice', dated: true }]);
  await assert.rejects(() => addDoc(db, { title: '   ' }));
  await assert.rejects(() => addDoc(db, { title: 'x'.repeat(201) }));
});

test('a document is shared once per teacher, never with its sharer', async () => {
  const db = await freshDb();
  const id = await addDoc(db);
  const share = (by, to) => db.query('insert into teacher_worksheet_shares (worksheet_id, shared_by, shared_with) values ($1, $2, $3)', [id, by, to]);
  await share(T1, T2);
  await assert.rejects(() => share(T1, T2), /teacher_worksheet_shares_once/);
  await assert.rejects(() => share(T1, T1), /teacher_worksheet_shares_not_self/);
});

test('deleting a document or its owner removes the document and its shares', async () => {
  const db = await freshDb();
  const id = await addDoc(db);
  await db.query('insert into teacher_worksheet_shares (worksheet_id, shared_by, shared_with) values ($1, $2, $3)', [id, T1, T2]);
  await db.query(`delete from users where id = '${T1}'`);
  const { rows } = await db.query('select (select count(*)::int from teacher_worksheets) as docs, (select count(*)::int from teacher_worksheet_shares) as shares');
  assert.deepEqual(rows, [{ docs: 0, shares: 0 }]);
});

test('deleting the school keeps the documents', async () => {
  const db = await freshDb();
  await addDoc(db);
  await db.query(`delete from schools where id = '${SCHOOL}'`);
  const { rows } = await db.query('select school_id from teacher_worksheets');
  assert.deepEqual(rows, [{ school_id: null }]);
});
