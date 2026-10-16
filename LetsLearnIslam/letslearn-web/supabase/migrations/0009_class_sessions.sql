-- ============================================================
-- LetsLearn — class sessions with a meeting link
-- ------------------------------------------------------------
-- A teacher puts a dated session on a class and attaches the link
-- to an online meeting. The class's pupils, their parents, the
-- class's teachers and the school's admins can see it and join.
--
-- Three rules this file exists to enforce, in the database, because
-- a rule that lives only in the browser is a suggestion:
--
--   1. Only someone who runs the class writes a session. A pupil
--      and a parent never do, whatever they type into the console.
--   2. Only people connected to the class read one. The link is
--      the door into a room with children in it, so it is treated
--      like any other child data: another school, an unclaimed
--      anonymous session and a different class's pupils all get
--      nothing.
--   3. A link is a web address on a platform the school approved.
--      It is never javascript:, data:, file: or anything that is
--      not http(s), and it is never https://zoom.us@evil.example,
--      the classic trick of putting a trusted name where the
--      browser reads a username.
--
-- pgcrypto is not used here, but every function still pins
-- search_path to include `extensions` so that this file is correct
-- the moment somebody adds a hash to it (see 0008).
-- ============================================================

-- ---------- which meeting platforms a school trusts ----------

create table school_link_hosts (
  school_id  uuid not null references schools(id) on delete cascade,
  -- lower-case registrable host, e.g. zoom.us. A link may use it or
  -- any subdomain of it (us02web.zoom.us), never a lookalike
  -- (zoom.us.evil.example, notzoom.us).
  host       text not null
             check (host ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'),
  primary key (school_id, host)
);

alter table school_link_hosts enable row level security;
revoke all on school_link_hosts from anon;

-- the starting list. An admin can add to it or take from it.
create or replace function ll_default_link_hosts(p_school uuid) returns void
language sql volatile security definer set search_path = public, extensions, pg_temp as $$
  insert into school_link_hosts (school_id, host) values
    (p_school, 'zoom.us'),
    (p_school, 'meet.google.com'),
    (p_school, 'teams.microsoft.com'),
    (p_school, 'teams.live.com')
  on conflict do nothing;
$$;
revoke all on function ll_default_link_hosts(uuid) from public, anon, authenticated;

-- every school that exists now, and every school made later
select ll_default_link_hosts(id) from schools;

create or replace function ll_schools_default_hosts() returns trigger
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
begin
  perform ll_default_link_hosts(new.id);
  return new;
end $$;

create trigger schools_default_hosts after insert on schools
  for each row execute function ll_schools_default_hosts();

-- ---------- the sessions ----------

create table class_sessions (
  id          uuid primary key default gen_random_uuid(),
  -- copied from the class by a trigger, never taken from the client,
  -- so a policy can compare it without a join
  school_id   uuid not null references schools(id) on delete cascade,
  class_id    uuid not null references classes(id) on delete cascade,
  title       text not null check (length(btrim(title)) between 1 and 120),
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  -- null is allowed: the session can be on the calendar before the
  -- teacher has the link. When it is set it must be a plain web
  -- address: scheme, a host made only of letters, digits, dots and
  -- hyphens, an optional port, an optional path. No spaces, no
  -- userinfo (@), no backslash. The host is then checked against the
  -- school's list by the trigger below.
  link        text check (
                link is null or (
                  length(link) <= 500
                  and link ~* '^https?://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?([/?#][^[:space:]\\]*)?$'
                )
              ),
  created_by  uuid references profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  constraint session_ends_after_it_starts check (ends_at > starts_at),
  constraint session_is_not_a_marathon check (ends_at - starts_at <= interval '8 hours')
);
create index class_sessions_class  on class_sessions(class_id, starts_at);
create index class_sessions_school on class_sessions(school_id, starts_at);

alter table class_sessions enable row level security;
revoke all on class_sessions from anon;

-- ---------- who is asking, for this table ----------

-- Does the caller run this class: a teacher of it, or an admin of the
-- school it belongs to? ll_teaches() is not used on purpose. Its
-- "or ll_role() = 'admin'" is not scoped to a school, so an admin at
-- one madrasah would pass it for a class at another.
create or replace function ll_manages_class(p_class uuid) returns boolean
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select exists (
    select 1
    from classes c
    where c.id = p_class
      and (
        exists (select 1 from class_teachers ct
                where ct.class_id = c.id and ct.teacher_id = ll_me())
        or (ll_role() = 'admin' and c.school_id = ll_school())
      )
  );
$$;

-- Is the caller a pupil in this class, or a parent of one? Exactly the
-- class, not "a class my child is near": a parent of a Qaida 1 child
-- does not see Hifz sessions.
create or replace function ll_in_class(p_class uuid) returns boolean
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select exists (
    select 1
    from enrolments e
    where e.class_id = p_class
      and (
        e.pupil_id = ll_me()
        or exists (select 1 from guardians g
                   where g.pupil_id = e.pupil_id and g.parent_id = ll_me())
      )
  );
$$;

-- ---------- the rules a row must obey on the way in ----------

create or replace function ll_session_guard() returns trigger
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare
  cls_school uuid;
  h text;
begin
  select school_id into cls_school from classes where id = new.class_id;
  if cls_school is null then
    raise exception 'unknown class' using errcode = '23503';
  end if;

  -- the school is the class's school, whatever the client sent
  new.school_id := cls_school;

  if tg_op = 'INSERT' then
    new.created_by := ll_me();
  else
    new.created_by := old.created_by;
  end if;

  if new.link is not null then
    h := substring(lower(new.link) from '^https?://([a-z0-9.-]+)');
    if not exists (
      select 1 from school_link_hosts s
      where s.school_id = new.school_id
        and (h = s.host or h like '%.' || s.host)
    ) then
      raise exception 'that meeting platform is not approved by this school'
        using errcode = '23514',
              hint = 'An admin can add its address to the approved list.';
    end if;
  end if;

  return new;
end $$;

create trigger class_sessions_guard before insert or update on class_sessions
  for each row execute function ll_session_guard();

-- ---------- policies ----------

-- Read: anyone connected to the class. Staff who run it, an admin of
-- the school, an enrolled pupil, a parent of an enrolled pupil.
create policy "read the sessions of your classes" on class_sessions
  for select using (ll_manages_class(class_id) or ll_in_class(class_id));

-- Write: only people who run the class. Three policies rather than
-- `for all`, because `for all` also grants select and permissive
-- policies are OR'd together (the lesson of 0003).
create policy "run your own class sessions: add" on class_sessions
  for insert with check (ll_manages_class(class_id));
create policy "run your own class sessions: edit" on class_sessions
  for update using (ll_manages_class(class_id))
  with check (ll_manages_class(class_id));
create policy "run your own class sessions: remove" on class_sessions
  for delete using (ll_manages_class(class_id));

-- The approved list. Staff read their own school's, so the form can
-- say which platforms work. Only an admin changes it, in their own school.
create policy "staff read their school's approved platforms" on school_link_hosts
  for select using (ll_role() in ('teacher', 'admin') and school_id = ll_school());
create policy "admins add approved platforms" on school_link_hosts
  for insert with check (ll_role() = 'admin' and school_id = ll_school());
create policy "admins remove approved platforms" on school_link_hosts
  for delete using (ll_role() = 'admin' and school_id = ll_school());
