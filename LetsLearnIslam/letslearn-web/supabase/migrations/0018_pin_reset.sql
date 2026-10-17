-- ============================================================
-- LetsLearn — "I forgot my PIN"
-- ------------------------------------------------------------
-- What existed (0002, 0005): set_pupil_pin (staff) and family_set_pin
-- (a parent) wrote a new bcrypt hash and cleared the lockout. Nothing
-- audited it, nothing refused 1234 or 0000, nothing ended the child's
-- other sessions, a lost tablet stayed signed in, and the database
-- accepted 4 to 8 digits while the sign-in pad can only type 4, so a
-- 5-digit PIN locked a child out for good. A child with a forgotten PIN
-- had no way to ask: the help said "tell your teacher" and no screen let
-- the teacher act on it.
--
-- This adds, and routes the old setters through:
--
--   * a request a child can raise, which reveals nothing: the answer is
--     identical whether or not the pupil exists, a request is already
--     open, or the child asked a minute ago;
--   * a reset an adult who is entitled to do it can perform, either by
--     typing a PIN or by generating a one-time temporary one;
--   * a temporary PIN that forces the child to choose their own at next
--     sign-in. The child never sets a PIN unprompted: the only door is
--     pin_choose_new(), which re-proves the temporary PIN first, so the
--     adult never learns the PIN the child keeps;
--   * a refusal of trivial PINs (all four digits the same, runs such as
--     1234 or 4321 or 7890, abab, aabb, and a short list of the usual);
--   * clearing of any lockout and ending of the child's other sessions;
--   * an append-only audit of who reset whom, never the PIN.
--
-- WHO MAY RESET: a teacher of a class the pupil is enrolled in; a parent
-- linked to that child; an admin of the pupil's school. Never a child,
-- never an unclaimed session, never another school, never yourself.
--
-- ENDING SESSIONS, honestly. The data policies all ask "who am I" from
-- profiles.auth_uid at query time, so setting auth_uid to null cuts the
-- old device off at once, whatever token it holds: that part is certain.
-- Deleting the rows in auth.sessions as well stops it refreshing; that is
-- best-effort (Supabase's privileges on the auth schema cannot be tested
-- from here) and its outcome is recorded in the audit row. An access
-- token already issued stays valid until it expires (default one hour),
-- but with no profile behind it, it reads nothing.
--
-- pgcrypto lives in the "extensions" schema on Supabase, so every
-- function here pins search_path to include it (see 0008).
-- ============================================================

alter table profiles add column if not exists pin_must_change     boolean not null default false;
alter table profiles add column if not exists pin_temp_expires_at timestamptz;
alter table profiles add column if not exists pin_changed_at      timestamptz;
-- profiles has column-level select grants (0001, 0005): none of these is in the list,
-- so no client can read them.

-- ---------- the rules for a PIN ----------
create or replace function ll_pin_trivial(p text) returns boolean
language plpgsql immutable as $$
declare a int; b int; c int; d int;
begin
  if p is null or p !~ '^[0-9]{4}$' then return false; end if;      -- the format is checked separately
  a := substr(p, 1, 1)::int; b := substr(p, 2, 1)::int; c := substr(p, 3, 1)::int; d := substr(p, 4, 1)::int;
  if a = b and b = c and c = d then return true; end if;                       -- 0000 .. 9999
  if (b - a + 10) % 10 = 1 and (c - b + 10) % 10 = 1 and (d - c + 10) % 10 = 1 then return true; end if;   -- 1234, 7890, 8901
  if (b - a + 10) % 10 = 9 and (c - b + 10) % 10 = 9 and (d - c + 10) % 10 = 9 then return true; end if;   -- 4321, 3210, 1098
  if a = c and b = d then return true; end if;                                 -- 1212, 1010
  if a = b and c = d then return true; end if;                                 -- 1122, 0011
  return p in ('2580', '0852', '1357', '2468', '1379', '1478', '3698', '1590', '6969', '1004', '5683', '4200');
end $$;

-- ---------- who may reset ----------
create or replace function ll_can_reset_pin(p_pupil uuid) returns boolean
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select coalesce(ll_adult_session(), false)
     and ll_role() in ('teacher', 'admin', 'parent')
     and exists (
       select 1 from profiles pu
       where pu.id = p_pupil and pu.role = 'student' and pu.id is distinct from ll_me()
         and (
           exists (select 1 from guardians g where g.pupil_id = pu.id and g.parent_id = ll_me())
           or exists (select 1 from enrolments e join class_teachers ct on ct.class_id = e.class_id
                      where e.pupil_id = pu.id and ct.teacher_id = ll_me())
           or (ll_role() = 'admin' and pu.school_id is not null and pu.school_id = ll_school())
         )
     );
$$;

-- ---------- the requests and the audit ----------
create table pin_reset_requests (
  id               uuid primary key default gen_random_uuid(),
  pupil_id         uuid not null references profiles(id) on delete cascade,
  school_id        uuid,
  family_id        uuid,
  requested_by_uid uuid,                       -- the child's anonymous session; no FK, it can be deleted
  requested_at     timestamptz not null default now(),
  state            text not null default 'open' check (state in ('open', 'done', 'dismissed')),
  resolved_by      uuid,
  resolved_at      timestamptz
);
create unique index pin_reset_one_open on pin_reset_requests (pupil_id) where state = 'open';   -- asking twice is not a queue
create index pin_reset_by_uid on pin_reset_requests (requested_by_uid, requested_at);
alter table pin_reset_requests enable row level security;
revoke all on pin_reset_requests from anon, authenticated;

create table pin_reset_audit (
  id               bigint generated always as identity primary key,
  at               timestamptz not null default now(),
  school_id        uuid,
  pupil_id         uuid not null,              -- plain ids, no FKs: an FK's ON DELETE would UPDATE this append-only table
  actor_id         uuid,
  actor_role       text not null,
  method           text not null check (method in ('typed', 'temporary', 'child_chose_new', 'dismissed')),
  request_id       uuid,
  sessions_cleared boolean
);
create index pin_reset_audit_school on pin_reset_audit (school_id, at desc);
alter table pin_reset_audit enable row level security;
revoke all on pin_reset_audit from anon, authenticated;
grant select on pin_reset_audit to authenticated;
create policy "admins read the PIN audit of their school" on pin_reset_audit
  for select using (ll_role() = 'admin' and school_id is not null and school_id = ll_school());

create or replace function ll_pin_audit_frozen() returns trigger
language plpgsql as $$
begin
  raise exception 'the PIN audit is append-only' using errcode = '42501';
end $$;
create trigger pin_reset_audit_no_change before update or delete on pin_reset_audit
  for each row execute function ll_pin_audit_frozen();
create trigger pin_reset_audit_no_truncate before truncate on pin_reset_audit
  for each statement execute function ll_pin_audit_frozen();

-- ---------- ending the old device's access ----------
create or replace function ll_end_child_sessions(p_pupil uuid) returns boolean
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare old uuid; cleared boolean := false;
begin
  select auth_uid into old from profiles where id = p_pupil;
  update profiles set auth_uid = null where id = p_pupil;       -- the part that must succeed: RLS asks auth_uid
  if old is null then return true; end if;
  begin                                                          -- best effort, and never an adult's session
    delete from auth.sessions s
     where s.user_id = old and exists (select 1 from auth.users u where u.id = old and coalesce(u.is_anonymous, false));
    cleared := true;
  exception when others then
    cleared := false;
  end;
  return cleared;
end $$;

-- ---------- the one place a reset is applied ----------
create or replace function ll_apply_pin(p_pupil uuid, p_pin text, p_temporary boolean, p_method text, p_actor uuid, p_actor_role text)
returns boolean
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare sch uuid; cleared boolean; rq uuid;
begin
  select school_id into sch from profiles where id = p_pupil for update;
  update profiles set
    pin_hash = crypt(p_pin, gen_salt('bf', 10)),
    pin_must_change = p_temporary,
    pin_temp_expires_at = case when p_temporary then now() + interval '7 days' end,
    pin_changed_at = now(), pin_attempts = 0, pin_locked_until = null
  where id = p_pupil;
  cleared := ll_end_child_sessions(p_pupil);
  update pin_reset_requests set state = 'done', resolved_by = p_actor, resolved_at = now()
   where pupil_id = p_pupil and state = 'open' returning id into rq;
  insert into pin_reset_audit (school_id, pupil_id, actor_id, actor_role, method, request_id, sessions_cleared)
  values (sch, p_pupil, p_actor, p_actor_role, p_method, rq, cleared);
  return cleared;
end $$;

-- ---------- the child's request: reveals nothing ----------
create or replace function pin_reset_request(p_pupil uuid, p_code text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare uid uuid := auth.uid(); rec profiles%rowtype; okgate boolean := false;
begin
  -- every path below returns the same thing. Nothing here tells the caller whether anything happened.
  if uid is null or p_pupil is null then return jsonb_build_object('ok', true); end if;
  select * into rec from profiles where id = p_pupil and role = 'student';
  if rec.id is null then return jsonb_build_object('ok', true); end if;
  -- the same gate as claim_pupil / claim_child, so this tells nobody more than class_roster() already does
  if p_code is not null then
    okgate := exists (select 1 from enrolments e join classes c on c.id = e.class_id
                      where e.pupil_id = rec.id and upper(c.join_code) = upper(trim(p_code)));
  else
    okgate := rec.family_id is not null;
  end if;
  if not okgate then return jsonb_build_object('ok', true); end if;
  -- ten minutes between asks for the same pupil, and ten asks an hour from one session
  if exists (select 1 from pin_reset_requests where pupil_id = rec.id and requested_at > now() - interval '10 minutes') then
    return jsonb_build_object('ok', true);
  end if;
  if (select count(*) from pin_reset_requests where requested_by_uid = uid and requested_at > now() - interval '1 hour') >= 10 then
    return jsonb_build_object('ok', true);
  end if;
  insert into pin_reset_requests (pupil_id, school_id, family_id, requested_by_uid)
  values (rec.id, rec.school_id, rec.family_id, uid) on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- what an adult sees ----------
create or replace function pin_reset_pending()
returns table (request_id uuid, pupil_id uuid, full_name text, avatar jsonb, class_names text[], requested_at timestamptz)
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select r.id, r.pupil_id, p.full_name, p.avatar,
         coalesce((select array_agg(c.name order by c.name) from enrolments e join classes c on c.id = e.class_id where e.pupil_id = r.pupil_id), '{}'),
         r.requested_at
  from pin_reset_requests r join profiles p on p.id = r.pupil_id
  where r.state = 'open' and ll_can_reset_pin(r.pupil_id)
  order by r.requested_at;
$$;

-- ---------- the adult types a PIN ----------
create or replace function pin_reset_set(p_pupil uuid, p_pin text)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare cleared boolean;
begin
  if not ll_can_reset_pin(p_pupil) then return jsonb_build_object('ok', false, 'error', 'not_allowed'); end if;
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then return jsonb_build_object('ok', false, 'error', 'bad_pin'); end if;
  if ll_pin_trivial(p_pin) then return jsonb_build_object('ok', false, 'error', 'trivial_pin'); end if;
  cleared := ll_apply_pin(p_pupil, p_pin, false, 'typed', ll_me(), ll_role()::text);
  return jsonb_build_object('ok', true, 'sessions_cleared', cleared);
end $$;

-- ---------- the adult generates a one-time PIN, shown once ----------
create or replace function pin_reset_temp(p_pupil uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare pin text; tries int := 0; cleared boolean;
begin
  if not ll_can_reset_pin(p_pupil) then return jsonb_build_object('ok', false, 'error', 'not_allowed'); end if;
  loop
    pin := lpad((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint % 10000)::text, 4, '0');
    exit when not ll_pin_trivial(pin);
    tries := tries + 1;
    if tries > 200 then return jsonb_build_object('ok', false, 'error', 'try_again'); end if;
  end loop;
  cleared := ll_apply_pin(p_pupil, pin, true, 'temporary', ll_me(), ll_role()::text);
  -- the PIN is returned once, here, and is stored only as a hash: it can never be fetched again
  return jsonb_build_object('ok', true, 'temp_pin', pin, 'expires_at', now() + interval '7 days', 'sessions_cleared', cleared);
end $$;

create or replace function pin_reset_dismiss(p_request uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare rec pin_reset_requests%rowtype;
begin
  select * into rec from pin_reset_requests where id = p_request and state = 'open' for update;
  if rec.id is null or not ll_can_reset_pin(rec.pupil_id) then return jsonb_build_object('ok', false, 'error', 'not_allowed'); end if;
  update pin_reset_requests set state = 'dismissed', resolved_by = ll_me(), resolved_at = now() where id = rec.id;
  insert into pin_reset_audit (school_id, pupil_id, actor_id, actor_role, method, request_id)
  values (rec.school_id, rec.pupil_id, ll_me(), ll_role()::text, 'dismissed', rec.id);
  return jsonb_build_object('ok', true);
end $$;

-- ---------- sign-in now understands a temporary PIN ----------
create or replace function ll_pin_ok(p_pupil uuid, p_pin text)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare rec profiles%rowtype;
begin
  select * into rec from profiles where id = p_pupil and role = 'student' for update;   -- FOR UPDATE: parallel guesses queue up
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_such_pupil');
  end if;
  if rec.pin_locked_until is not null and rec.pin_locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked', 'until', rec.pin_locked_until);
  end if;
  if rec.pin_hash is null or rec.pin_hash <> crypt(p_pin, rec.pin_hash) then
    update profiles set pin_attempts = pin_attempts + 1,
                        pin_locked_until = case when pin_attempts + 1 >= 5 then now() + interval '15 minutes' end
    where id = rec.id;
    return jsonb_build_object('ok', false, 'error', 'wrong_pin');
  end if;
  if rec.pin_must_change then
    -- the temporary PIN is right, but nobody is signed in until the child has chosen their own
    if rec.pin_temp_expires_at is not null and rec.pin_temp_expires_at < now() then
      return jsonb_build_object('ok', false, 'error', 'expired');
    end if;
    update profiles set pin_attempts = 0, pin_locked_until = null where id = rec.id;
    return jsonb_build_object('ok', false, 'error', 'must_change');
  end if;
  update profiles set auth_uid = auth.uid(), pin_attempts = 0, pin_locked_until = null where id = rec.id;
  return jsonb_build_object('ok', true, 'pupil_id', rec.id, 'full_name', rec.full_name,
                            'school_id', rec.school_id, 'family_id', rec.family_id);
end $$;

-- ---------- the one time a child sets their own PIN ----------
create or replace function pin_choose_new(p_pupil uuid, p_code text, p_old_pin text, p_new_pin text)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare rec profiles%rowtype; gate boolean;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'no_session'); end if;
  -- the same doors as claim_pupil / claim_child
  select * into rec from profiles where id = p_pupil and role = 'student' for update;
  if rec.id is null then return jsonb_build_object('ok', false, 'error', 'wrong_pin'); end if;
  if p_code is not null then
    gate := exists (select 1 from enrolments e join classes c on c.id = e.class_id
                    where e.pupil_id = rec.id and upper(c.join_code) = upper(trim(p_code)));
  else
    gate := rec.family_id is not null;
  end if;
  if not gate then return jsonb_build_object('ok', false, 'error', 'not_in_class'); end if;
  if rec.pin_locked_until is not null and rec.pin_locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked', 'until', rec.pin_locked_until);
  end if;
  -- prove the current (temporary) PIN, under the same counter and lockout as signing in
  if rec.pin_hash is null or p_old_pin is null or rec.pin_hash <> crypt(p_old_pin, rec.pin_hash) then
    update profiles set pin_attempts = pin_attempts + 1,
                        pin_locked_until = case when pin_attempts + 1 >= 5 then now() + interval '15 minutes' end
    where id = rec.id;
    return jsonb_build_object('ok', false, 'error', 'wrong_pin');
  end if;
  if not rec.pin_must_change then return jsonb_build_object('ok', false, 'error', 'not_needed'); end if;
  if rec.pin_temp_expires_at is not null and rec.pin_temp_expires_at < now() then
    return jsonb_build_object('ok', false, 'error', 'expired');
  end if;
  if p_new_pin is null or p_new_pin !~ '^[0-9]{4}$' then return jsonb_build_object('ok', false, 'error', 'bad_pin'); end if;
  if ll_pin_trivial(p_new_pin) then return jsonb_build_object('ok', false, 'error', 'trivial_pin'); end if;
  if p_new_pin = p_old_pin then return jsonb_build_object('ok', false, 'error', 'same_pin'); end if;
  update profiles set pin_hash = crypt(p_new_pin, gen_salt('bf', 10)), pin_must_change = false, pin_temp_expires_at = null,
                      pin_changed_at = now(), pin_attempts = 0, pin_locked_until = null, auth_uid = auth.uid()
  where id = rec.id;
  insert into pin_reset_audit (school_id, pupil_id, actor_id, actor_role, method)
  values (rec.school_id, rec.id, rec.id, 'student', 'child_chose_new');
  return jsonb_build_object('ok', true, 'pupil_id', rec.id, 'full_name', rec.full_name, 'school_id', rec.school_id, 'family_id', rec.family_id);
end $$;

-- ---------- the old setters now go through the same rules ----------
create or replace function family_set_pin(p_pupil uuid, p_pin text)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
begin
  if not exists (select 1 from guardians where pupil_id = p_pupil and parent_id = ll_me()) then
    return jsonb_build_object('ok', false, 'error', 'not_your_child');
  end if;
  return pin_reset_set(p_pupil, p_pin);
end $$;

create or replace function set_pupil_pin(p_pupil uuid, p_pin text)
returns boolean
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare r jsonb;
begin
  if auth.uid() is null then
    -- the owner, in the SQL editor. This always worked, but only by accident of how NULL behaves in the old checks.
    if p_pin is null or p_pin !~ '^[0-9]{4}$' or ll_pin_trivial(p_pin) then
      raise exception 'a PIN is exactly four digits and not an easy one such as 1234';
    end if;
    if not exists (select 1 from profiles where id = p_pupil and role = 'student') then return false; end if;
    perform ll_apply_pin(p_pupil, p_pin, false, 'typed', null, 'owner');
    return true;
  end if;
  r := pin_reset_set(p_pupil, p_pin);
  if r ->> 'ok' is distinct from 'true' then raise exception 'could not set the PIN: %', r ->> 'error'; end if;
  return true;
end $$;

create or replace function family_add_child(p_name text, p_pin text, p_avatar jsonb default '{}'::jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare me uuid; fam uuid; r user_role; kid uuid; n int;
begin
  me := ll_me();
  if me is null then return jsonb_build_object('ok', false, 'error', 'no_profile'); end if;
  select family_id, role into fam, r from profiles where id = me;
  if r = 'student' then return jsonb_build_object('ok', false, 'error', 'children_cannot_add_children'); end if;
  if fam is null then return jsonb_build_object('ok', false, 'error', 'no_family'); end if;
  if coalesce(trim(p_name), '') = '' then return jsonb_build_object('ok', false, 'error', 'no_name'); end if;
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then return jsonb_build_object('ok', false, 'error', 'bad_pin'); end if;
  if ll_pin_trivial(p_pin) then return jsonb_build_object('ok', false, 'error', 'trivial_pin'); end if;
  select count(*) into n from profiles where family_id = fam and role = 'student';
  if n >= 12 then return jsonb_build_object('ok', false, 'error', 'too_many_children'); end if;
  insert into profiles (school_id, family_id, role, full_name, avatar, pin_hash)
  values (null, fam, 'student', trim(p_name), coalesce(p_avatar, '{}'::jsonb), crypt(p_pin, gen_salt('bf', 10)))
  returning id into kid;
  insert into guardians (parent_id, pupil_id) values (me, kid) on conflict do nothing;
  insert into garden (pupil_id) values (kid) on conflict do nothing;
  return jsonb_build_object('ok', true, 'pupil', kid);
end $$;

-- ---------- who may call what ----------
revoke all on function ll_pin_trivial(text), ll_can_reset_pin(uuid), ll_end_child_sessions(uuid),
  ll_apply_pin(uuid, text, boolean, text, uuid, text), ll_pin_audit_frozen() from public, anon, authenticated;
revoke all on function pin_reset_request(uuid, text), pin_reset_pending(), pin_reset_set(uuid, text), pin_reset_temp(uuid),
  pin_reset_dismiss(uuid), pin_choose_new(uuid, text, text, text) from public, anon;
grant execute on function pin_reset_request(uuid, text), pin_choose_new(uuid, text, text, text) to anon, authenticated;
grant execute on function pin_reset_pending(), pin_reset_set(uuid, text), pin_reset_temp(uuid), pin_reset_dismiss(uuid) to authenticated;
revoke all on function ll_pin_ok(uuid, text) from public, anon, authenticated;
