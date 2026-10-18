-- ============================================================
-- LetsLearn — a log of what goes wrong in the app, without the children
-- ------------------------------------------------------------
-- When the app breaks on a child's tablet today, nobody ever finds out:
-- the error is in a browser console nobody opens. This collects JavaScript
-- errors so an admin can see "something is broken on the homework page",
-- and so the person fixing it has a stack trace.
--
-- It is built to hold as little as it can:
--
--   * Only these fields are kept: when, the school (if known), the role
--     (admin / teacher / parent / student, never who), a message, where it
--     came from, a stack, the page, a version and a coarse browser name.
--     No user id, no IP, no device id, no cookies.
--   * Every text field is SCRUBBED here in the database, whatever the app
--     sent: emails, sign-in tokens and API keys, passwords and PINs given as
--     key=value, URL query strings and fragments (a password-reset link
--     carries its token there), UUIDs (they identify a child), and any run of
--     four or more digits (PINs, phone numbers). The app scrubs too, but the
--     database never relies on that.
--   * Text is truncated hard: message 300 characters, stack 1200.
--   * The same error on the same day is ONE row with a count.
--   * Rows older than 30 days are deleted.
--
-- It is a public door by necessity, because an error can happen before
-- anyone has signed in. So it is bounded: 30 reports an hour per signed-in
-- person, 60 for everyone signed-out together, 1,000 an hour for the whole
-- project, and at most 500 different errors per school per day. Past a limit
-- a report is dropped SILENTLY and the call still answers { ok: true }, so
-- nothing can be learned from it and a broken app cannot start a loop.
--
-- Only an admin reads it, and only their own school's rows. Reports from
-- before sign-in have no school and are read by the project owner in the
-- SQL editor. Nobody signed in or signed out can insert, change or delete a
-- row directly: the only way in is log_client_error().
-- ============================================================

create table if not exists client_errors (
  id          bigint generated always as identity primary key,
  school_id   uuid references schools(id) on delete cascade,     -- null = reported before sign-in
  role        user_role,
  day         date not null,                                      -- London day, for "same error today"
  fingerprint text not null,
  message     text not null,
  source      text,
  stack       text,
  page        text,
  version     text,
  browser     text,
  count       int  not null default 1,
  first_at    timestamptz not null default now(),
  last_at     timestamptz not null default now()
);
create unique index if not exists client_errors_dedupe
  on client_errors (fingerprint, (coalesce(school_id, '00000000-0000-0000-0000-000000000000'::uuid)), day);
create index if not exists client_errors_school_recent on client_errors (school_id, last_at desc);

create table if not exists client_error_limits (
  key  text not null,
  hour timestamptz not null,
  n    int  not null default 0,
  primary key (key, hour)
);

alter table client_errors enable row level security;
alter table client_error_limits enable row level security;
revoke all on client_errors, client_error_limits from anon, authenticated;
grant select on client_errors to authenticated;

drop policy if exists "admins read their school's errors" on client_errors;
create policy "admins read their school's errors" on client_errors
  for select using (ll_role() = 'admin' and school_id = ll_school());

-- ---------- scrubbing ----------
create or replace function ll_scrub(p text, p_max int) returns text
language plpgsql immutable set search_path = public, pg_temp as $$
declare t text := coalesce(p, '');
begin
  -- sign-in tokens (JWTs) and the project's API keys
  t := regexp_replace(t, 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*', '<token>', 'g');
  t := regexp_replace(t, 'sb_(publishable|secret)_[A-Za-z0-9_-]{6,}|sbp_[A-Za-z0-9]{16,}', '<key>', 'g');
  -- "Bearer xyz", then secrets given as name=value or name: value (a bare space is not a separator:
  -- "token expired" is an ordinary sentence)
  t := regexp_replace(t, '(bearer)\s+[A-Za-z0-9._~+/=-]+', '\1 <redacted>', 'gi');
  t := regexp_replace(t, '(access_token|refresh_token|id_token|apikey|api_key|token|password|passwd|pwd|pin|secret|authorization)([" '']*[:=][" '']*)[^\s&"'',;)]+', '\1\2<redacted>', 'gi');
  -- a URL's query and fragment (a password-reset link keeps its token there)
  t := regexp_replace(t, '((https?://|file://)[^\s"''?#)]*)[?#][^\s"'')]*', '\1?<redacted>', 'g');
  t := regexp_replace(t, '([A-Za-z0-9_./-]+\.(html|js))[?#][^\s"'')]*', '\1?<redacted>', 'g');
  -- email addresses
  t := regexp_replace(t, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<email>', 'g');
  -- UUIDs: a child's id
  t := regexp_replace(t, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<id>', 'g');
  -- four or more digits (PINs, phone numbers); line and column numbers after a colon survive
  t := regexp_replace(t, '(?<![:0-9])[0-9]{4,}', '<n>', 'g');
  -- control characters, then runs of spaces
  t := regexp_replace(t, '[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]', ' ', 'g');
  t := regexp_replace(t, '[ \t]+', ' ', 'g');
  return left(btrim(t), p_max);
end $$;

create or replace function client_errors_purge() returns void
language sql volatile security definer set search_path = public, pg_temp as $$
  delete from client_errors where last_at < now() - interval '30 days';
  delete from client_error_limits where hour < now() - interval '2 days';
$$;

-- ---------- the one way in ----------
create or replace function log_client_error(p_message text, p_source text, p_stack text, p_page text, p_version text, p_browser text)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  uid uuid := auth.uid(); sch uuid; rl user_role;
  msg text := ll_scrub(p_message, 300);
  src text := nullif(ll_scrub(p_source, 80), '');
  stk text := nullif(ll_scrub(p_stack, 1200), '');
  pg  text := nullif(left(regexp_replace(lower(coalesce(p_page, '')), '[^a-z0-9_-]', '', 'g'), 40), '');
  ver text := nullif(ll_scrub(p_version, 40), '');
  brw text := nullif(ll_scrub(p_browser, 60), '');
  fp text; hr timestamptz := date_trunc('hour', now()); today date := (now() at time zone 'Europe/London')::date;
  k text; lim int; n int; seen int;
begin
  if msg is null or msg = '' then return jsonb_build_object('ok', true); end if;
  select school_id, role into sch, rl from profiles where auth_uid = uid;

  -- how many reports this caller, the signed-out crowd, and the whole project may send an hour
  k := case when uid is null then 'anon' else 'u:' || uid::text end;
  lim := case when uid is null then 60 else 30 end;
  insert into client_error_limits as l (key, hour, n) values (k, hr, 1)
    on conflict (key, hour) do update set n = l.n + 1 returning l.n into n;
  if n > lim then return jsonb_build_object('ok', true); end if;
  insert into client_error_limits as l (key, hour, n) values ('all', hr, 1)
    on conflict (key, hour) do update set n = l.n + 1 returning l.n into n;
  if n > 1000 then return jsonb_build_object('ok', true); end if;

  fp := md5(msg || '|' || coalesce(src, ''));

  -- a school may log at most 500 different errors a day; a known one only counts up
  select count(*) into seen from client_errors where day = today and school_id is not distinct from sch;
  if seen >= 500 and not exists (select 1 from client_errors
        where day = today and school_id is not distinct from sch and fingerprint = fp) then
    return jsonb_build_object('ok', true);
  end if;

  insert into client_errors (school_id, role, day, fingerprint, message, source, stack, page, version, browser)
    values (sch, rl, today, fp, msg, src, stk, pg, ver, brw)
    on conflict (fingerprint, (coalesce(school_id, '00000000-0000-0000-0000-000000000000'::uuid)), day)
    do update set count = least(client_errors.count + 1, 100000), last_at = now(),
                  stack = coalesce(client_errors.stack, excluded.stack);

  if random() < 0.02 then perform client_errors_purge(); end if;
  return jsonb_build_object('ok', true);
end $$;

-- the door is open to everyone (errors happen before sign-in); the rest is shut
revoke all on function log_client_error(text, text, text, text, text, text) from public;
grant execute on function log_client_error(text, text, text, text, text, text) to anon, authenticated;
revoke all on function client_errors_purge() from public, anon, authenticated;
revoke all on function ll_scrub(text, int) from public, anon, authenticated;
