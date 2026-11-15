-- Prepare Worksheet (Teacher Portal > Assignments > + New > Prepare Worksheet,
-- served by aivorah-assignments-service /worksheets). A teacher writes a
-- worksheet in the in-app Word-style editor; it is saved here as HTML and
-- turned into a .docx on demand (Download, and the Assign flow).
-- Only the owner can open or change their own documents. A document can be
-- shared with fellow teachers of the same school (teacher_worksheet_shares);
-- they see it under Assignments > Library > Shared to you and can open,
-- download and assign it, but never change the owner's copy.
-- The service reads and writes with the service role, so anon/authenticated
-- get no access.

create table if not exists "public"."teacher_worksheets" (
  "id" uuid primary key default gen_random_uuid(),
  "owner_id" uuid not null references "public"."users"(id) on delete cascade,
  "school_id" uuid references "public"."schools"(id) on delete set null,
  "title" text not null check (length(btrim(title)) between 1 and 200),
  "content_html" text not null default '',
  "created_at" timestamptz not null default now(),
  "updated_at" timestamptz not null default now()
);

create index if not exists teacher_worksheets_owner_idx
  on "public"."teacher_worksheets" (owner_id, updated_at desc);

-- One row per document per recipient; sharing again just moves shared_at.
create table if not exists "public"."teacher_worksheet_shares" (
  "id" uuid primary key default gen_random_uuid(),
  "worksheet_id" uuid not null references "public"."teacher_worksheets"(id) on delete cascade,
  "shared_by" uuid not null references "public"."users"(id) on delete cascade,
  "shared_with" uuid not null references "public"."users"(id) on delete cascade,
  "shared_at" timestamptz not null default now(),
  constraint teacher_worksheet_shares_once unique ("worksheet_id", "shared_with"),
  constraint teacher_worksheet_shares_not_self check (shared_by <> shared_with)
);

create index if not exists teacher_worksheet_shares_recipient_idx
  on "public"."teacher_worksheet_shares" (shared_with, shared_at desc);

alter table "public"."teacher_worksheets" enable row level security;
alter table "public"."teacher_worksheet_shares" enable row level security;
revoke all on "public"."teacher_worksheets" from anon, authenticated;
revoke all on "public"."teacher_worksheet_shares" from anon, authenticated;
