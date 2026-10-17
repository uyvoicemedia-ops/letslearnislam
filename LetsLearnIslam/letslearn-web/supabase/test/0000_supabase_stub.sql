-- ============================================================
-- Just enough Supabase to test the migrations on plain Postgres.
-- ------------------------------------------------------------
-- Not part of the deployment. Supabase provides all of this already;
-- it exists so tools/testdb.sh can run the real migration files
-- unaltered against a throwaway container and say whether they
-- actually apply — including whether the RLS policies recurse, which
-- is the one class of mistake that looks fine until a query hangs.
-- ============================================================

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on sequences to anon, authenticated, service_role;

-- Supabase installs extensions into their own schema, not public. Doing
-- the same here is what makes a security-definer function that pins
-- search_path = public, pg_temp fail on crypt() in the test, as it does
-- on a real project. 0001's "create extension if not exists" then no-ops.
-- The postgres role gets Supabase's default search_path (which includes
-- extensions) so unqualified calls from the SQL editor, like 0004's seed,
-- behave the same here. Applies to new sessions, i.e. every later file.
create schema if not exists extensions;
grant usage on schema extensions to anon, authenticated, service_role;
create extension if not exists pgcrypto schema extensions;
alter role postgres set search_path = "$user", public, extensions;

create schema if not exists auth;

create table auth.users (
  id           uuid primary key default gen_random_uuid(),
  email        text unique,
  -- Supabase adds this with anonymous auth. ll_adult_session() reads it
  -- to keep social sign-in away from children, so the stub needs it too.
  is_anonymous boolean not null default false
);

-- In Supabase this reads the JWT. Here it reads a session setting, so a
-- test can say "now I am this person" with set_config.
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

-- Supabase keeps one row per signed-in session here. The PIN reset deletes a child's.
create table auth.sessions (
  id      uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade
);

grant usage on schema auth to anon, authenticated, service_role;
grant select on auth.users to anon, authenticated, service_role;
