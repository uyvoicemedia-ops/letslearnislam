-- ============================================================
-- LetsLearn — families, self sign-up, and social sign-in
-- ------------------------------------------------------------
-- Run after 0004. Everything before this assumed the school enters
-- every person first and hands out the logins. That is still true for
-- a madrasah, but it means a parent who hears about the app on a
-- Sunday can do nothing until Monday. This file adds the other door.
--
-- The shape
-- ---------
-- A FAMILY is a household. A parent who signs in with Google, Facebook
-- or an email and is on nobody's roster gets a family and a parent
-- profile, and may add their own children to it. Those children have
-- a family and no school: they can read, practise, pray and garden at
-- home from the first minute.
--
-- A child joins a CLASS only when the school says so. The parent asks
-- with the class code; a teacher of that class approves; the approval
-- is what writes the enrolment and stamps the school onto the child.
-- So a roster stays something staff control, and a parent never waits
-- to get started.
--
-- Social sign-in is for ADULTS ONLY, and that is a rule about children
-- rather than about plumbing: an under-13 should not be made to have a
-- Google or Facebook account to read Qaida. Children keep the PIN.
-- ll_adult_session() is what enforces it — an anonymous session (which
-- is what a child has) can never start a family or add a child.
--
-- A stranger who signs in with Google and is on no roster becomes a
-- PARENT of an empty family. Not a teacher, not an admin, and attached
-- to no school. That is the safe direction: the worst case is somebody
-- using the app at home by themselves, which is not a breach.
-- ============================================================

-- ---------- households ----------

create table families (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  created_at  timestamptz not null default now()
);
alter table families enable row level security;

alter table profiles alter column school_id drop not null;
alter table profiles add column family_id uuid references families(id) on delete set null;
create index profiles_family on profiles(family_id);

-- nobody floats free: a person is in a school, a family, or both
alter table profiles add constraint profile_belongs_somewhere
  check (school_id is not null or family_id is not null);

-- 0001 replaced the table-wide select grant with an explicit column
-- list precisely so that a column added later is invisible until
-- somebody decides otherwise. This is that decision.
revoke select on profiles from anon, authenticated;
grant select (id, auth_uid, school_id, family_id, role, full_name, email, avatar, created_at)
  on profiles to anon, authenticated;

-- ---------- asking to join a class ----------

create type class_request_state as enum ('pending', 'approved', 'declined');

create table class_requests (
  id          uuid primary key default gen_random_uuid(),
  pupil_id    uuid not null references profiles(id) on delete cascade,
  class_id    uuid not null references classes(id) on delete cascade,
  asked_by    uuid references profiles(id) on delete set null,
  state       class_request_state not null default 'pending',
  decided_by  uuid references profiles(id) on delete set null,
  decided_at  timestamptz,
  created_at  timestamptz not null default now()
);
-- one open request per child per class; asking twice is not a queue
create unique index class_requests_open
  on class_requests(pupil_id, class_id) where state = 'pending';
create index class_requests_class on class_requests(class_id, state);
alter table class_requests enable row level security;

-- ============================================================
-- who is asking
-- ============================================================

create or replace function ll_family() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select family_id from profiles where auth_uid = auth.uid();
$$;

-- Is this a grown-up who signed in properly — email, Google or
-- Facebook — as opposed to the anonymous session a child gets before
-- typing their PIN? Supabase stamps auth.users.is_anonymous, so this
-- is one column read and cannot be faked from a device.
--
-- Deliberately NOT "does this session have an email": Facebook lets a
-- user withhold it, and that person is still an adult.
create or replace function ll_adult_session() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from auth.users u
    where u.id = auth.uid() and coalesce(u.is_anonymous, false) = false
  );
$$;

-- A teacher must be able to see the NAME of a child being offered to
-- their class, before they have approved anything — otherwise they are
-- deciding blind. This is the only way a staff member sees a child
-- they do not yet teach, it is scoped to one pending request on one of
-- their own classes, and it disappears the moment they decide.
--
-- It is security definer so that the profiles policy can call it
-- without reading class_requests through class_requests' own policy,
-- which would recurse.
create or replace function ll_offered_to_me(p_pupil uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from class_requests r
    where r.pupil_id = p_pupil and r.state = 'pending' and ll_teaches(r.class_id)
  );
$$;

-- ============================================================
-- checking a PIN, in one place
-- ============================================================

-- 0002 wrote this inline inside claim_pupil. There are two ways in
-- now — a class code, or a family — and a brute-force guard that only
-- covers one of them is not a guard. Both doors call this.
--
-- Five wrong goes and the account rests for fifteen minutes: long
-- enough to make walking 10,000 PINs pointless, short enough that a
-- child who genuinely forgot is not out of the lesson.
create or replace function ll_pin_ok(p_pupil uuid, p_pin text)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  rec profiles%rowtype;
begin
  select * into rec from profiles where id = p_pupil and role = 'student';
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_such_pupil');
  end if;

  if rec.pin_locked_until is not null and rec.pin_locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked', 'until', rec.pin_locked_until);
  end if;

  if rec.pin_hash is null or rec.pin_hash <> crypt(p_pin, rec.pin_hash) then
    update profiles set
      pin_attempts = pin_attempts + 1,
      pin_locked_until = case when pin_attempts + 1 >= 5
                              then now() + interval '15 minutes' end
    where id = rec.id;
    return jsonb_build_object('ok', false, 'error', 'wrong_pin');
  end if;

  update profiles set auth_uid = auth.uid(), pin_attempts = 0, pin_locked_until = null
  where id = rec.id;

  return jsonb_build_object('ok', true, 'pupil_id', rec.id,
                            'full_name', rec.full_name,
                            'school_id', rec.school_id,
                            'family_id', rec.family_id);
end;
$$;

-- Same signature and same answers as 0002; the body now defers to
-- ll_pin_ok so there is one brute-force guard rather than two.
create or replace function claim_pupil(p_code text, p_pupil uuid, p_pin text)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'no_session');
  end if;
  if not exists (
    select 1 from enrolments e join classes c on c.id = e.class_id
    where e.pupil_id = p_pupil and upper(c.join_code) = upper(trim(p_code))
  ) then
    return jsonb_build_object('ok', false, 'error', 'not_in_class');
  end if;
  return ll_pin_ok(p_pupil, p_pin);
end;
$$;

-- The home door. A child in a family taps their face on the picker and
-- types their PIN; the browser has already made an anonymous session,
-- exactly as it does for the class-code route.
--
-- Restricted to children who HAVE a family, so this can never be used
-- to sidestep the class code for a school-only pupil.
create or replace function claim_child(p_pupil uuid, p_pin text)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'no_session');
  end if;
  if not exists (select 1 from profiles
                 where id = p_pupil and role = 'student' and family_id is not null) then
    return jsonb_build_object('ok', false, 'error', 'not_a_family_child');
  end if;
  return ll_pin_ok(p_pupil, p_pin);
end;
$$;

-- ============================================================
-- a grown-up arriving on their own
-- ============================================================

-- Called once, straight after any adult sign-in. Idempotent, and it
-- has three jobs rolled into one so the client never has to work out
-- which case it is in:
--
--   * the school already put them on the roster  -> nothing to do
--   * on the roster but no household yet          -> give them one
--   * on nobody's roster                          -> parent + family
--
-- p_name is only used in the third case, and only if the provider gave
-- no name of its own.
create or replace function family_open(p_name text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  me uuid; fam uuid; r user_role; nm text; mail text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'no_session');
  end if;
  if not ll_adult_session() then
    return jsonb_build_object('ok', false, 'error', 'not_an_adult_session');
  end if;

  select id, family_id, role into me, fam, r from profiles where auth_uid = auth.uid();
  select email into mail from auth.users where id = auth.uid();

  if me is null then
    nm := coalesce(nullif(trim(p_name), ''), nullif(split_part(coalesce(mail, ''), '@', 1), ''), 'Parent');
    insert into families (name) values (nm || '''s family') returning id into fam;
    begin
      insert into profiles (auth_uid, school_id, family_id, role, full_name, email)
      values (auth.uid(), null, fam, 'parent', nm, mail)
      returning id into me;
    exception when unique_violation then
      -- the roster row for this email landed between the select and the
      -- insert, or two tabs signed in at once. Take what is there.
      delete from families where id = fam;
      select id, family_id into me, fam from profiles where lower(email) = lower(mail);
      update profiles set auth_uid = auth.uid() where id = me and auth_uid is null;
    end;
    r := 'parent';
  elsif fam is null then
    insert into families (name)
      values ((select full_name from profiles where id = me) || '''s family')
      returning id into fam;
    update profiles set family_id = fam where id = me;
  end if;

  return jsonb_build_object('ok', true, 'profile', me, 'family', fam, 'role', r);
end;
$$;

-- A parent adding their own child. Staff use the roster screens and the
-- ordinary insert policy; this exists for the kitchen table.
--
-- The child gets a family and NO school. Nothing about a school is
-- reachable from a profile made here until a teacher approves a class
-- request, which is the whole point.
create or replace function family_add_child(p_name text, p_pin text, p_avatar jsonb default '{}'::jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  me uuid; fam uuid; r user_role; kid uuid; n int;
begin
  me := ll_me();
  if me is null then
    return jsonb_build_object('ok', false, 'error', 'no_profile');
  end if;
  select family_id, role into fam, r from profiles where id = me;
  if r = 'student' then
    return jsonb_build_object('ok', false, 'error', 'children_cannot_add_children');
  end if;
  if fam is null then
    return jsonb_build_object('ok', false, 'error', 'no_family');
  end if;
  if coalesce(trim(p_name), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'no_name');
  end if;
  if p_pin !~ '^[0-9]{4,8}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_pin');
  end if;

  -- a household, not a school. A stuck client loop should not be able
  -- to fill the table with children.
  select count(*) into n from profiles where family_id = fam and role = 'student';
  if n >= 12 then
    return jsonb_build_object('ok', false, 'error', 'too_many_children');
  end if;

  insert into profiles (school_id, family_id, role, full_name, avatar, pin_hash)
  values (null, fam, 'student', trim(p_name), coalesce(p_avatar, '{}'::jsonb),
          crypt(p_pin, gen_salt('bf', 10)))
  returning id into kid;

  insert into guardians (parent_id, pupil_id) values (me, kid)
    on conflict do nothing;
  insert into garden (pupil_id) values (kid) on conflict do nothing;

  return jsonb_build_object('ok', true, 'pupil', kid);
end;
$$;

-- A parent may change their own child's PIN. 0002 restricted this to
-- staff, which was right when staff made every account.
create or replace function family_set_pin(p_pupil uuid, p_pin text)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from guardians
                 where pupil_id = p_pupil and parent_id = ll_me()) then
    return jsonb_build_object('ok', false, 'error', 'not_your_child');
  end if;
  if p_pin !~ '^[0-9]{4,8}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_pin');
  end if;
  update profiles set pin_hash = crypt(p_pin, gen_salt('bf', 10)),
                      pin_attempts = 0, pin_locked_until = null
  where id = p_pupil and role = 'student';
  return jsonb_build_object('ok', found);
end;
$$;

-- ============================================================
-- asking a school for a place, and the school answering
-- ============================================================

-- The parent has the class code off a letter or a wall. Asking is not
-- joining: this only raises a hand.
create or replace function family_request_class(p_pupil uuid, p_code text)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  cls uuid; req uuid;
begin
  if not exists (select 1 from guardians
                 where pupil_id = p_pupil and parent_id = ll_me()) then
    return jsonb_build_object('ok', false, 'error', 'not_your_child');
  end if;

  select id into cls from classes where upper(join_code) = upper(trim(coalesce(p_code, '')));
  if cls is null then
    return jsonb_build_object('ok', false, 'error', 'no_such_class');
  end if;
  if exists (select 1 from enrolments where pupil_id = p_pupil and class_id = cls) then
    return jsonb_build_object('ok', false, 'error', 'already_in_it');
  end if;

  insert into class_requests (pupil_id, class_id, asked_by)
  values (p_pupil, cls, ll_me())
  on conflict do nothing
  returning id into req;

  if req is null then
    return jsonb_build_object('ok', true, 'already_asked', true);
  end if;
  return jsonb_build_object('ok', true, 'request', req);
end;
$$;

-- The teacher's answer. Approving is the ONLY thing that writes an
-- enrolment for a family child and the only thing that stamps a school
-- onto them, which is what keeps a roster the school's own.
--
-- A child who already belongs to a school keeps that school; a family
-- child adopted by a second school would be a mess, so it is refused
-- rather than quietly re-homed.
create or replace function class_request_decide(p_request uuid, p_approve boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  rec class_requests%rowtype; sch uuid; had uuid;
begin
  select * into rec from class_requests where id = p_request;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_such_request');
  end if;
  if rec.state <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'already_decided');
  end if;
  if not ll_teaches(rec.class_id) then
    return jsonb_build_object('ok', false, 'error', 'not_your_class');
  end if;

  if not p_approve then
    update class_requests set state = 'declined', decided_by = ll_me(), decided_at = now()
    where id = p_request;
    return jsonb_build_object('ok', true, 'state', 'declined');
  end if;

  select school_id into sch from classes where id = rec.class_id;
  select school_id into had from profiles where id = rec.pupil_id;
  if had is not null and had <> sch then
    return jsonb_build_object('ok', false, 'error', 'child_belongs_to_another_school');
  end if;

  insert into enrolments (class_id, pupil_id) values (rec.class_id, rec.pupil_id)
    on conflict do nothing;
  update profiles set school_id = sch where id = rec.pupil_id and school_id is null;
  update class_requests set state = 'approved', decided_by = ll_me(), decided_at = now()
  where id = p_request;

  return jsonb_build_object('ok', true, 'state', 'approved');
end;
$$;

-- ============================================================
-- who may call what
-- ============================================================

revoke all on function ll_family() from public;
revoke all on function ll_adult_session() from public;
revoke all on function ll_offered_to_me(uuid) from public;
revoke all on function ll_pin_ok(uuid, text) from public;
revoke all on function claim_child(uuid, text) from public;
revoke all on function family_open(text) from public;
revoke all on function family_add_child(text, text, jsonb) from public;
revoke all on function family_set_pin(uuid, text) from public;
revoke all on function family_request_class(uuid, text) from public;
revoke all on function class_request_decide(uuid, boolean) from public;

-- ll_pin_ok is NOT granted to anybody. It is the raw PIN check with no
-- question about which door was used, and the two doors are the doors.
grant execute on function claim_child(uuid, text) to anon, authenticated;
grant execute on function family_open(text) to authenticated;
grant execute on function family_add_child(text, text, jsonb) to authenticated;
grant execute on function family_set_pin(uuid, text) to authenticated;
grant execute on function family_request_class(uuid, text) to authenticated;
grant execute on function class_request_decide(uuid, boolean) to authenticated;

-- ============================================================
-- row-level security
-- ============================================================

create policy "see your own household" on families
  for select using (id = ll_family());
create policy "rename your own household" on families
  for update using (id = ll_family()) with check (id = ll_family());
-- households are only ever created by family_open(), which is definer

-- The people in your household, on top of the school rules in 0003.
-- Permissive policies are OR'd, so this widens rather than replaces.
--
-- This is names and avatars only, because that is all the picker needs
-- and all the column grant above allows. It does NOT let one child read
-- a sibling's points, register or work: those tables all go through
-- ll_can_see_pupil(), which knows about parents and teachers and has
-- never known about siblings.
create policy "see your household" on profiles
  for select using (
    (family_id is not null and family_id = ll_family())
    or ll_offered_to_me(id)
  );

-- Deliberately no insert or update policy for parents. Adding a child
-- goes through family_add_child(), so a parent cannot hand-write a row
-- with role 'admin', somebody else's school_id, or a null PIN.

create policy "see requests about your own children" on class_requests
  for select using (asked_by = ll_me() or ll_can_see_pupil(pupil_id));
create policy "see requests aimed at your classes" on class_requests
  for select using (ll_teaches(class_id));
-- raising and answering both go through the functions above
