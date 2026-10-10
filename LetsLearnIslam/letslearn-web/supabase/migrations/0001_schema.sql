-- ============================================================
-- LetsLearn — schema
-- ------------------------------------------------------------
-- Run this first, in the Supabase SQL editor, on an empty project.
-- 0002_rls.sql must be run straight after: this file creates the
-- tables and turns row-level security ON, which means everything
-- is DENIED until the policies in 0002 exist. That order is
-- deliberate — there is no window where children's data sits in a
-- table that anyone with the anon key can read.
--
-- How people sign in
-- ------------------
-- Adults (admin, teacher, parent) use ordinary Supabase email +
-- password auth.
--
-- Children do not have email, and most are under 13, so they get a
-- class code and a 4-digit PIN instead. The browser signs in
-- ANONYMOUSLY, which yields a real JWT and a stable auth.uid(),
-- and then calls claim_pupil() with the class code, the pupil they
-- picked from the list, and the PIN. That function checks the PIN
-- and points the pupil's profile row at the anonymous uid. Every
-- policy from then on keys off auth.uid() exactly as it does for
-- an adult.
--
-- The point of the detour: verifying a PIN needs to happen where
-- the client cannot see the hashes, but minting a session needs
-- the service-role key. Anonymous auth mints the session on the
-- client, so the service-role key is never shipped to a device and
-- no edge function is needed to make this work.
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- who ----------

create table schools (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  created_at  timestamptz not null default now()
);

create type user_role as enum ('admin', 'teacher', 'parent', 'student');

create table profiles (
  id          uuid primary key default gen_random_uuid(),
  auth_uid    uuid unique references auth.users(id) on delete set null,
  school_id   uuid not null references schools(id) on delete cascade,
  role        user_role not null,
  full_name   text not null,
  -- adults only, and only so a new signup can be matched to the roster
  -- row the school already made for them. Children have no email.
  email       text unique,
  avatar      jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),

  -- children only: the PIN they sign in with, and the brute-force guard
  pin_hash      text,
  pin_attempts  int not null default 0,
  pin_locked_until timestamptz,

  constraint pupils_have_a_pin
    check (role <> 'student' or pin_hash is not null)
);
create index profiles_school on profiles(school_id);
create index profiles_role on profiles(school_id, role);

create table classes (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references schools(id) on delete cascade,
  name        text not null,
  room        text,
  -- what a child types to find their class. Short, unambiguous, and
  -- rotatable: it is a finder, not a secret, exactly like a Kahoot code.
  join_code   text not null unique,
  created_at  timestamptz not null default now()
);
create index classes_school on classes(school_id);

-- a teacher may take several classes and a class may be shared
create table class_teachers (
  class_id    uuid not null references classes(id) on delete cascade,
  teacher_id  uuid not null references profiles(id) on delete cascade,
  primary key (class_id, teacher_id)
);

create table enrolments (
  class_id    uuid not null references classes(id) on delete cascade,
  pupil_id    uuid not null references profiles(id) on delete cascade,
  primary key (class_id, pupil_id)
);
create index enrolments_pupil on enrolments(pupil_id);

create table guardians (
  parent_id   uuid not null references profiles(id) on delete cascade,
  pupil_id    uuid not null references profiles(id) on delete cascade,
  primary key (parent_id, pupil_id)
);
create index guardians_pupil on guardians(pupil_id);

-- ---------- what happens at the madrasah ----------

create type attendance_mark as enum ('present', 'late', 'absent', 'excused');

create table attendance (
  id          bigint generated always as identity primary key,
  pupil_id    uuid not null references profiles(id) on delete cascade,
  class_id    uuid not null references classes(id) on delete cascade,
  on_date     date not null,
  mark        attendance_mark not null,
  marked_by   uuid references profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  unique (pupil_id, on_date)
);
create index attendance_pupil on attendance(pupil_id, on_date desc);
create index attendance_class on attendance(class_id, on_date desc);

create table homework (
  id          uuid primary key default gen_random_uuid(),
  class_id    uuid not null references classes(id) on delete cascade,
  title       text not null,
  module_id   text,                     -- ties a piece to a practice module
  due_on      date,
  set_by      uuid references profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index homework_class on homework(class_id, due_on desc);

create table submissions (
  id            bigint generated always as identity primary key,
  homework_id   uuid not null references homework(id) on delete cascade,
  pupil_id      uuid not null references profiles(id) on delete cascade,
  score         int check (score between 0 and 100),
  submitted_at  timestamptz not null default now(),
  marked_at     timestamptz,
  marked_by     uuid references profiles(id) on delete set null,
  unique (homework_id, pupil_id)
);
create index submissions_pupil on submissions(pupil_id, submitted_at desc);

create table practice (
  id          bigint generated always as identity primary key,
  pupil_id    uuid not null references profiles(id) on delete cascade,
  module_id   text not null,
  label       text,
  score       int not null check (score between 0 and 100),
  stars       int not null default 0,
  letters     text[] not null default '{}',
  at          timestamptz not null default now()
);
create index practice_pupil on practice(pupil_id, at desc);

create table reading (
  pupil_id    uuid not null references profiles(id) on delete cascade,
  book_id     text not null,
  page        int not null default 0,
  finished_at timestamptz,
  updated_at  timestamptz not null default now(),
  primary key (pupil_id, book_id)
);

-- ---------- points and the garden ----------

-- Every coin a child has ever been given, and why. The garden reads a
-- balance from this rather than keeping its own counter, so a coin can
-- always be traced back to the thing that earned it — which is the
-- whole point of the "where your coins come from" card.
create type point_source as enum
  ('practice', 'streak', 'attendance', 'reading', 'homework',
   'dhikr', 'club', 'teacher_gift', 'parent_gift', 'quiz', 'adjustment');

create table points (
  id          bigint generated always as identity primary key,
  pupil_id    uuid not null references profiles(id) on delete cascade,
  source      point_source not null,
  amount      int not null,
  reason      text,
  given_by    uuid references profiles(id) on delete set null,
  at          timestamptz not null default now()
);
create index points_pupil on points(pupil_id, at desc);

-- The garden is a single opaque document. It is the child's own
-- creation and nothing else queries inside it, so there is no reason
-- to shred it across twenty tables — and one row means one write on
-- save, which matters when a class of thirty saves at once.
create table garden (
  pupil_id    uuid primary key references profiles(id) on delete cascade,
  state       jsonb not null default '{}'::jsonb,
  spent       int not null default 0,     -- coins spent, against the points balance
  updated_at  timestamptz not null default now()
);

-- ---------- the club ----------

create table club_posts (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references schools(id) on delete cascade,
  author_id   uuid not null references profiles(id) on delete cascade,
  topic       text not null default 'general',
  body        text not null check (length(body) between 1 and 2000),
  -- children's posts wait for a teacher; adults' appear at once
  approved    boolean not null default false,
  approved_by uuid references profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index club_posts_school on club_posts(school_id, created_at desc);

create table club_likes (
  post_id     uuid not null references club_posts(id) on delete cascade,
  liker_id    uuid not null references profiles(id) on delete cascade,
  primary key (post_id, liker_id)
);

-- ---------- the live quiz ----------

create table quiz_sets (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references schools(id) on delete cascade,
  owner_id    uuid not null references profiles(id) on delete cascade,
  title       text not null,
  created_at  timestamptz not null default now()
);

create table quiz_questions (
  id          uuid primary key default gen_random_uuid(),
  set_id      uuid not null references quiz_sets(id) on delete cascade,
  ord         int not null,
  prompt      text not null,
  choices     jsonb not null,            -- ["alif","ba","ta","tha"]
  answer      int not null,              -- index into choices
  seconds     int not null default 20,
  unique (set_id, ord)
);

create type room_state as enum ('lobby', 'asking', 'reveal', 'finished');

create table quiz_rooms (
  id            uuid primary key default gen_random_uuid(),
  set_id        uuid not null references quiz_sets(id) on delete cascade,
  host_id       uuid not null references profiles(id) on delete cascade,
  code          text not null unique,
  state         room_state not null default 'lobby',
  current_ord   int not null default 0,
  -- when the current question went up; every client scores against this
  -- rather than its own clock, so a slow phone is not punished
  asked_at      timestamptz,
  created_at    timestamptz not null default now()
);
create index quiz_rooms_code on quiz_rooms(code) where state <> 'finished';

create table quiz_players (
  id          uuid primary key default gen_random_uuid(),
  room_id     uuid not null references quiz_rooms(id) on delete cascade,
  pupil_id    uuid references profiles(id) on delete cascade,
  nickname    text not null,
  score       int not null default 0,
  joined_at   timestamptz not null default now(),
  unique (room_id, nickname)
);
create index quiz_players_room on quiz_players(room_id, score desc);

create table quiz_answers (
  id          bigint generated always as identity primary key,
  room_id     uuid not null references quiz_rooms(id) on delete cascade,
  question_id uuid not null references quiz_questions(id) on delete cascade,
  player_id   uuid not null references quiz_players(id) on delete cascade,
  choice      int not null,
  ms          int not null,              -- how long they took
  correct     boolean not null,
  points      int not null default 0,
  at          timestamptz not null default now(),
  unique (question_id, player_id)        -- one answer each, no second go
);

-- ---------- lock everything, before anything is in it ----------
-- Supabase grants anon and authenticated on new public tables, so a
-- table without RLS is a table the anon key can read. These go in the
-- same migration as the CREATEs on purpose: there is no moment when a
-- child's row exists in an unprotected table. 0003 then opens the
-- specific doors.

alter table schools        enable row level security;
alter table profiles       enable row level security;
alter table classes        enable row level security;
alter table class_teachers enable row level security;
alter table enrolments     enable row level security;
alter table guardians      enable row level security;
alter table attendance     enable row level security;
alter table homework       enable row level security;
alter table submissions    enable row level security;
alter table practice       enable row level security;
alter table reading        enable row level security;
alter table points         enable row level security;
alter table garden         enable row level security;
alter table club_posts     enable row level security;
alter table club_likes     enable row level security;
alter table quiz_sets      enable row level security;
alter table quiz_questions enable row level security;
alter table quiz_rooms     enable row level security;
alter table quiz_players   enable row level security;
alter table quiz_answers   enable row level security;

-- The PIN columns never leave the database. RLS decides which ROWS you
-- may read; it has nothing to say about columns, so this is the only
-- thing standing between a policy that grants a row and the bcrypt hash
-- inside it.
--
-- Revoking the column is not enough on its own: a table-level SELECT
-- covers every column, present and future, and a column-level revoke
-- does not chip away at it. The grant has to be replaced by an explicit
-- list — which also means a column added later is invisible until
-- somebody deliberately adds it here.
revoke select on profiles from anon, authenticated;
grant select (id, auth_uid, school_id, role, full_name, email, avatar, created_at)
  on profiles to anon, authenticated;
