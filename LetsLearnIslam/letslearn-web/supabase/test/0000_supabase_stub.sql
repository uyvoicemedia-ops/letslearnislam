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

grant usage on schema auth to anon, authenticated, service_role;
grant select on auth.users to anon, authenticated, service_role;
