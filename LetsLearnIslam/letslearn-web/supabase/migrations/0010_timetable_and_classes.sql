-- ============================================================
-- LetsLearn — the weekly timetable, and running the classes
-- ------------------------------------------------------------
-- Two things the Classes and Timetable screens need that were
-- not here:
--
--   1. timetable_slots. The recurring week: "Qaida 1, Mondays
--      4:00 to 5:00, Room 1". Wall-clock times, because a
--      madrasah runs at 4pm whatever the clock did on Sunday; a
--      timestamp would drift an hour twice a year. Class sessions
--      (0009) are the dated one-offs with a meeting link; this is
--      the standing pattern. They are separate on purpose.
--
--   2. Admin functions to create a class, move a pupil between
--      classes and put a teacher on or off a class. They exist
--      because the policies that would let the app do those with
--      plain inserts are not school-scoped for admins:
--      ll_teaches() ends in "or ll_role() = 'admin'" with no school
--      test, and so does "admins assign teachers" in 0003. One
--      school hides that; two expose it. Fixing 0003 in place would
--      change a migration that already ran, so these are new
--      doors that check the school themselves, and the UI uses
--      them. Tightening the old policies is a separate decision.
--
-- Every function pins search_path to include `extensions`, as 0008
-- explains. class_create uses gen_random_bytes, which is pgcrypto.
-- ============================================================

-- ---------- the weekly timetable ----------

create table timetable_slots (
  id         uuid primary key default gen_random_uuid(),
  -- copied from the class by a trigger, never taken from the client
  school_id  uuid not null references schools(id) on delete cascade,
  class_id   uuid not null references classes(id) on delete cascade,
  weekday    smallint not null check (weekday between 1 and 7),   -- 1 = Monday
  starts_at  time not null,
  ends_at    time not null,
  -- null means "the class's own room"
  room       text check (room is null or length(btrim(room)) between 1 and 40),
  constraint slot_ends_after_it_starts check (ends_at > starts_at),
  constraint slot_is_not_a_marathon check (ends_at - starts_at <= interval '8 hours'),
  unique (class_id, weekday, starts_at)
);
create index timetable_school on timetable_slots(school_id, weekday, starts_at);
create index timetable_class  on timetable_slots(class_id);

alter table timetable_slots enable row level security;
revoke all on timetable_slots from anon;

-- A slot may not double-book a class, a room, or a teacher. Checked
-- in the table, not the screen, so a second admin on a second device
-- cannot book the same room by clicking at the same moment.
create or replace function ll_slot_guard() returns trigger
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare
  cls classes%rowtype;
  eff_room text;
  clash text;
begin
  select * into cls from classes where id = new.class_id;
  if cls.id is null then
    raise exception 'unknown class' using errcode = '23503';
  end if;
  new.school_id := cls.school_id;
  if new.room is not null then new.room := btrim(new.room); end if;
  eff_room := nullif(btrim(coalesce(new.room, cls.room, '')), '');
  -- the placeholder the demo uses for "no room"
  if eff_room = '—' then eff_room := null; end if;

  -- the same class twice at once
  select c.name into clash
  from timetable_slots s join classes c on c.id = s.class_id
  where s.class_id = new.class_id and s.weekday = new.weekday
    and s.id is distinct from new.id
    and s.starts_at < new.ends_at and new.starts_at < s.ends_at
  limit 1;
  if clash is not null then
    raise exception 'that class already has a lesson at that time'
      using errcode = '23P01', hint = clash;
  end if;

  -- the same room twice at once
  if eff_room is not null then
    select c.name into clash
    from timetable_slots s join classes c on c.id = s.class_id
    where s.school_id = new.school_id and s.weekday = new.weekday
      and s.id is distinct from new.id
      and lower(nullif(btrim(coalesce(s.room, c.room, '')), '')) = lower(eff_room)
      and s.starts_at < new.ends_at and new.starts_at < s.ends_at
    limit 1;
    if clash is not null then
      raise exception 'that room is already in use at that time'
        using errcode = '23P01', hint = clash;
    end if;
  end if;

  -- the same teacher in two places at once
  select p.full_name into clash
  from class_teachers mine
  join class_teachers theirs on theirs.teacher_id = mine.teacher_id
                            and theirs.class_id <> mine.class_id
  join timetable_slots s on s.class_id = theirs.class_id
  join profiles p on p.id = mine.teacher_id
  where mine.class_id = new.class_id and s.weekday = new.weekday
    and s.id is distinct from new.id
    and s.starts_at < new.ends_at and new.starts_at < s.ends_at
  limit 1;
  if clash is not null then
    raise exception 'a teacher of that class is teaching another class at that time'
      using errcode = '23P01', hint = clash;
  end if;

  return new;
end $$;

create trigger timetable_slots_guard before insert or update on timetable_slots
  for each row execute function ll_slot_guard();

-- Read: any teacher or admin sees their whole school's week, because a
-- teacher choosing a room needs to see who has it. A pupil or parent
-- sees only the classes they are in (ll_in_class, from 0009).
create policy "staff read their school's timetable" on timetable_slots
  for select using (ll_role() in ('teacher', 'admin') and school_id = ll_school());
create policy "read the timetable of your classes" on timetable_slots
  for select using (ll_in_class(class_id));

-- Write: an admin, in their own school. Three policies, not `for all`.
create policy "admins add timetable slots" on timetable_slots
  for insert with check (ll_role() = 'admin' and school_id = ll_school());
create policy "admins edit timetable slots" on timetable_slots
  for update using (ll_role() = 'admin' and school_id = ll_school())
  with check (ll_role() = 'admin' and school_id = ll_school());
create policy "admins remove timetable slots" on timetable_slots
  for delete using (ll_role() = 'admin' and school_id = ll_school());

-- ---------- running the classes ----------

-- Is the caller an admin, and of which school? One answer, used below.
create or replace function ll_admin_school() returns uuid
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select school_id from profiles where auth_uid = auth.uid() and role = 'admin';
$$;

-- A new class with a fresh join code. The alphabet leaves out 0/O and
-- 1/I/L so a code read off a classroom wall cannot be mistyped. The code
-- is a finder, not a secret (see 0001), but it should still be unique.
create or replace function class_create(p_name text, p_room text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare
  sch uuid := ll_admin_school();
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  bytes bytea; code text; i int; new_id uuid; tries int := 0;
begin
  if sch is null then return jsonb_build_object('error', 'not_admin'); end if;
  if p_name is null or length(btrim(p_name)) not between 1 and 60 then
    return jsonb_build_object('error', 'bad_name');
  end if;
  loop
    tries := tries + 1;
    bytes := gen_random_bytes(6);
    code := '';
    for i in 0..5 loop
      code := code || substr(alphabet, 1 + (get_byte(bytes, i) % length(alphabet)), 1);
    end loop;
    exit when not exists (select 1 from classes where join_code = code);
    if tries > 20 then return jsonb_build_object('error', 'no_code'); end if;
  end loop;
  insert into classes (school_id, name, room, join_code)
  values (sch, btrim(p_name), nullif(btrim(coalesce(p_room, '')), ''), code)
  returning id into new_id;
  return jsonb_build_object('ok', true, 'id', new_id, 'join_code', code);
end $$;

-- Put a pupil in exactly one class: takes them out of every other class
-- in the school and into this one. Both must belong to the admin's school.
create or replace function class_move_pupil(p_pupil uuid, p_class uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare sch uuid := ll_admin_school();
begin
  if sch is null then return jsonb_build_object('error', 'not_admin'); end if;
  if not exists (select 1 from profiles where id = p_pupil and role = 'student'
                 and school_id = sch) then
    return jsonb_build_object('error', 'no_such_pupil');
  end if;
  if not exists (select 1 from classes where id = p_class and school_id = sch) then
    return jsonb_build_object('error', 'no_such_class');
  end if;
  delete from enrolments e using classes c
    where e.pupil_id = p_pupil and c.id = e.class_id and c.school_id = sch
      and e.class_id <> p_class;
  insert into enrolments (class_id, pupil_id) values (p_class, p_pupil)
    on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;

-- Put a teacher on a class, or take them off. Teacher and class must be
-- in the admin's school, and the person must really be staff.
create or replace function class_set_teacher(p_class uuid, p_teacher uuid, p_on boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare sch uuid := ll_admin_school();
begin
  if sch is null then return jsonb_build_object('error', 'not_admin'); end if;
  if not exists (select 1 from classes where id = p_class and school_id = sch) then
    return jsonb_build_object('error', 'no_such_class');
  end if;
  if not exists (select 1 from profiles where id = p_teacher and school_id = sch
                 and role in ('teacher', 'admin')) then
    return jsonb_build_object('error', 'no_such_teacher');
  end if;
  if p_on then
    insert into class_teachers (class_id, teacher_id) values (p_class, p_teacher)
      on conflict do nothing;
  else
    delete from class_teachers where class_id = p_class and teacher_id = p_teacher;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- The app calls these as a signed-in user; anonymous callers cannot.
revoke all on function class_create(text, text), class_move_pupil(uuid, uuid),
  class_set_teacher(uuid, uuid, boolean), ll_admin_school() from public, anon;
grant execute on function class_create(text, text), class_move_pupil(uuid, uuid),
  class_set_teacher(uuid, uuid, boolean), ll_admin_school() to authenticated;
