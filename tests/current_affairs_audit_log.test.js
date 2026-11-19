// Runs 0023 then 0029 on PGlite: the Current Affairs approval history table.
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

async function freshDb() {
  const db = new PGlite();
  await db.exec(SUPABASE_STUBS);
  await db.exec(migration('0023_current_affairs.sql'));
  await db.exec(migration('0029_current_affairs_audit_log.sql'));
  return db;
}

test('records who did what to which story, with before/after and a time', async () => {
  const db = await freshDb();
  await db.query(`insert into ca_audit_log (actor, action, entity_type, entity_id, before, after, detail)
    values ('editor@aivorah.ai', 'story.publish', 'story', '11111111-1111-4111-8111-111111111111',
            '{"status":"review"}', '{"status":"published","publish_date":"2026-11-20"}', 'Approved for 2026-11-20')`);
  const { rows } = await db.query('select * from ca_audit_log');
  assert.equal(rows.length, 1);
  assert.equal(rows[0].actor, 'editor@aivorah.ai');
  assert.deepEqual(rows[0].after, { status: 'published', publish_date: '2026-11-20' });
  assert.ok(rows[0].created_at instanceof Date);
});

test('actor, action and entity type are required', async () => {
  const db = await freshDb();
  await assert.rejects(db.query(`insert into ca_audit_log (action, entity_type) values ('story.edit', 'story')`));
  await assert.rejects(db.query(`insert into ca_audit_log (actor, entity_type) values ('a@b.in', 'story')`));
});

test('running it twice is safe and keeps existing rows (same design as the earlier proposal)', async () => {
  const db = await freshDb();
  await db.query(`insert into ca_audit_log (actor, action, entity_type) values ('pipeline', 'story.create', 'story')`);
  await db.exec(migration('0029_current_affairs_audit_log.sql'));
  assert.equal((await db.query('select count(*)::int as n from ca_audit_log')).rows[0].n, 1);
});

test('row level security is on with no policies (students cannot read it)', async () => {
  const db = await freshDb();
  const rls = await db.query(`select relrowsecurity from pg_class where relname = 'ca_audit_log'`);
  assert.equal(rls.rows[0].relrowsecurity, true);
  const policies = await db.query(`select count(*)::int as n from pg_policies where tablename = 'ca_audit_log'`);
  assert.equal(policies.rows[0].n, 0);
});
