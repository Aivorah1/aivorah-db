// Runs 0022 on PGlite: face-login passkeys (public keys only).
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { PGlite } = require('@electric-sql/pglite');

const MIGRATION = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'migrations', '0022_user_passkeys.sql'), 'utf8');
const U = '11111111-1111-1111-1111-111111111111';

async function freshDb() {
  const db = new PGlite();
  await db.exec(`create role anon; create role authenticated;
    create table users (id uuid primary key, email text);
    insert into users values ('${U}', 'asha@x.com');`);
  await db.exec(MIGRATION);
  return db;
}
const add = (db, cred) => db.query(`insert into user_passkeys (user_id, credential_id, public_key) values ($1, $2, 'AQID')`, [U, cred]);

test('a user can have a passkey per device; defaults filled in', async () => {
  const db = await freshDb();
  await add(db, 'laptop');
  await add(db, 'phone');
  const { rows } = await db.query('select credential_id, counter, transports from user_passkeys order by credential_id');
  assert.deepEqual(rows.map((r) => [r.credential_id, Number(r.counter), r.transports]), [['laptop', 0, []], ['phone', 0, []]]);
});

test('a device credential can belong to only one account', async () => {
  const db = await freshDb();
  await add(db, 'laptop');
  await assert.rejects(() => add(db, 'laptop'));
});

test('deleting the user deletes their passkeys', async () => {
  const db = await freshDb();
  await add(db, 'laptop');
  await db.query(`delete from users where id = '${U}'`);
  const { rows } = await db.query('select count(*)::int as n from user_passkeys');
  assert.equal(rows[0].n, 0);
});

test('retiring passkeys preserves the user and is safe to reapply', async (t) => {
  const db = await freshDb();
  t.after(() => db.close());
  await add(db, 'laptop');
  const removal = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'migrations', '0034_drop_user_passkeys.sql'), 'utf8');
  await db.exec(removal);
  await db.exec(removal);
  const { rows: tables } = await db.query("select to_regclass('public.user_passkeys') as passkeys");
  assert.equal(tables[0].passkeys, null);
  const { rows: users } = await db.query('select id, email from users');
  assert.deepEqual(users, [{ id: U, email: 'asha@x.com' }]);
});
