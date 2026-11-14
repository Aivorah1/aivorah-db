-- Student Report (Teacher Portal > Resources > Student Report, served by
-- aivorah-attendance-service /reports). One row per student, academic year and
-- subject: the marks a subject teacher uploads, out of 100. The report card
-- (all subjects, total, pass/fail, rating) is generated from these rows; it is
-- never typed by hand. Uploading again for the same subject replaces the mark.
-- grade/section record the class the student was in when the mark was given.
-- The service reads and writes with the service role, so anon/authenticated
-- get no access.

create table if not exists "public"."student_marks" (
  "id" uuid primary key default gen_random_uuid(),
  "school_id" uuid not null references "public"."schools"(id) on delete cascade,
  "student_id" uuid not null references "public"."users"(id) on delete cascade,
  "academic_year" text not null,
  "grade" text not null,
  "section" text not null default '',
  "subject" text not null check (length(btrim(subject)) > 0),
  "marks" numeric(5,2) not null check (marks >= 0 and marks <= 100),
  "uploaded_by" uuid references "public"."users"(id) on delete set null,
  "created_at" timestamptz not null default now(),
  "updated_at" timestamptz not null default now(),
  constraint student_marks_student_year_subject_key unique ("student_id", "academic_year", "subject")
);

create index if not exists student_marks_class_idx
  on "public"."student_marks" (school_id, academic_year, grade, section);

alter table "public"."student_marks" enable row level security;
revoke all on "public"."student_marks" from anon, authenticated;
