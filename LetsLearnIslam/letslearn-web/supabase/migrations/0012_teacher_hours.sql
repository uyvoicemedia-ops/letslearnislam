-- ============================================================
-- LetsLearn — teacher hours
-- ------------------------------------------------------------
-- The Teacher hours screen was a mock with a yellow note saying the
-- backend already had a half-built teaching-hours function. It did not:
-- there is nothing like it anywhere in the migrations. This is the real
-- thing.
--
-- Where the hours come from. The weekly timetable (0010) already says who
-- teaches what and when. An admin generates a week's hours from it, then
-- corrects them by hand: delete a lesson that did not run, add cover.
-- Hours are therefore a record of what was PAID FOR, which may differ from
-- what was scheduled, and that is why they are rows of their own rather
-- than a view of the timetable.
--
-- Who may see what. This is salary data.
--   * only an admin writes hours or sets a rate;
--   * a teacher sees their OWN hours and nobody else's, and never a rate
--     or a pay figure, not even their own (the screen says so);
--   * nobody at another school, no pupil, no parent, no anonymous caller
--     sees anything.
--
-- A rate is copied onto each hour row when it is made. Changing a
-- teacher's rate next month must not quietly change what last month's
-- payroll said, so a past week is frozen at the rate it was paid at. A row
-- made before a rate was set has none, is flagged, and is filled in the
-- moment an admin sets the rate.
--
-- Money is in pence, as everywhere else (0007).
-- ============================================================

create table teacher_rates (
  teacher_id  uuid primary key references profiles(id) on delete cascade,
  school_id   uuid not null references schools(id) on delete cascade,
  rate_pence  int  not null check (rate_pence between 0 and 20000),   -- up to £200 an hour
  updated_at  timestamptz not null default now()
);
alter table teacher_rates enable row level security;
revoke all on teacher_rates from anon;

create table hours_log (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references schools(id) on delete cascade,
  teacher_id  uuid not null references profiles(id) on delete cascade,
  class_id    uuid references classes(id) on delete set null,
  on_date     date not null,
  minutes     int  not null check (minutes between 1 and 720),
  source      text not null check (source in ('timetable', 'manual')),
  slot_id     uuid references timetable_slots(id) on delete set null,
  note        text check (note is null or length(note) <= 200),
  -- frozen when the row is made; null means "no rate had been set yet"
  rate_pence  int  check (rate_pence is null or rate_pence between 0 and 20000),
  created_by  uuid references profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index hours_log_week on hours_log(school_id, on_date);
create index hours_log_teacher on hours_log(teacher_id, on_date);
-- generating the same week twice must not pay for it twice
create unique index hours_log_once on hours_log(slot_id, on_date, teacher_id) where slot_id is not null;

alter table hours_log enable row level security;
revoke all on hours_log from anon;

-- Only an admin, in their own school, sees or changes any rate.
create policy "admins read rates" on teacher_rates
  for select using (ll_role() = 'admin' and school_id = ll_school());
create policy "admins add rates" on teacher_rates
  for insert with check (ll_role() = 'admin' and school_id = ll_school());
create policy "admins edit rates" on teacher_rates
  for update using (ll_role() = 'admin' and school_id = ll_school())
  with check (ll_role() = 'admin' and school_id = ll_school());
create policy "admins remove rates" on teacher_rates
  for delete using (ll_role() = 'admin' and school_id = ll_school());

-- Hours: an admin reads the school's, a teacher reads only their own.
-- hours_log carries rate_pence, so a teacher reading their own row would see
-- their rate; the column is therefore not granted to authenticated at all and
-- is only reachable through the functions below, which decide per caller.
create policy "admins read hours" on hours_log
  for select using (ll_role() = 'admin' and school_id = ll_school());
create policy "teachers read their own hours" on hours_log
  for select using (ll_role() = 'teacher' and teacher_id = ll_me());
create policy "admins record hours" on hours_log
  for insert with check (ll_role() = 'admin' and school_id = ll_school());
create policy "admins correct hours" on hours_log
  for update using (ll_role() = 'admin' and school_id = ll_school())
  with check (ll_role() = 'admin' and school_id = ll_school());
create policy "admins remove hours" on hours_log
  for delete using (ll_role() = 'admin' and school_id = ll_school());

revoke select on hours_log from authenticated;
grant select (id, school_id, teacher_id, class_id, on_date, minutes, source, slot_id, note, created_at)
  on hours_log to authenticated;
-- an admin needs the rate to correct a row, and gets it through the week function

-- ---------- generating a week from the timetable ----------

create or replace function hours_generate_week(p_week_start date)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare
  sch uuid := ll_admin_school();
  n int;
begin
  if sch is null then return jsonb_build_object('error', 'not_admin'); end if;
  if extract(isodow from p_week_start) <> 1 then
    return jsonb_build_object('error', 'not_a_monday');
  end if;

  -- Every teacher of every class with a lesson that week. A class with two
  -- teachers credits both: co-teaching is paid for both, and an admin deletes
  -- the row where that is not so. Lessons that have not happened yet are
  -- skipped; run it again after the week and they are picked up.
  insert into hours_log (school_id, teacher_id, class_id, on_date, minutes, source,
                         slot_id, rate_pence, created_by)
  select sch, ct.teacher_id, s.class_id, p_week_start + (s.weekday - 1),
         (extract(epoch from (s.ends_at - s.starts_at)) / 60)::int,
         'timetable', s.id, r.rate_pence, ll_me()
  from timetable_slots s
  join class_teachers ct on ct.class_id = s.class_id
  join profiles t on t.id = ct.teacher_id and t.school_id = sch
  left join teacher_rates r on r.teacher_id = ct.teacher_id
  where s.school_id = sch
    and p_week_start + (s.weekday - 1) <= current_date
  on conflict do nothing;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'inserted', n);
end $$;

-- A lesson that is not on the timetable: cover, a meeting, a trial lesson.
create or replace function hours_add(p_teacher uuid, p_class uuid, p_on date, p_minutes int, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare sch uuid := ll_admin_school(); rate int;
begin
  if sch is null then return jsonb_build_object('error', 'not_admin'); end if;
  if not exists (select 1 from profiles where id = p_teacher and school_id = sch
                 and role in ('teacher', 'admin')) then
    return jsonb_build_object('error', 'no_such_teacher');
  end if;
  if p_class is not null and not exists (select 1 from classes where id = p_class and school_id = sch) then
    return jsonb_build_object('error', 'no_such_class');
  end if;
  if p_minutes is null or p_minutes not between 1 and 720 then
    return jsonb_build_object('error', 'bad_minutes');
  end if;
  select rate_pence into rate from teacher_rates where teacher_id = p_teacher;
  insert into hours_log (school_id, teacher_id, class_id, on_date, minutes, source, note, rate_pence, created_by)
  values (sch, p_teacher, p_class, p_on, p_minutes, 'manual', nullif(btrim(coalesce(p_note, '')), ''), rate, ll_me());
  return jsonb_build_object('ok', true);
end $$;

-- Set a teacher's hourly rate. Fills in rows that were made before there was
-- one; never touches a row that already has a rate (that week was paid).
create or replace function hours_set_rate(p_teacher uuid, p_pence int)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare sch uuid := ll_admin_school(); filled int;
begin
  if sch is null then return jsonb_build_object('error', 'not_admin'); end if;
  if not exists (select 1 from profiles where id = p_teacher and school_id = sch
                 and role in ('teacher', 'admin')) then
    return jsonb_build_object('error', 'no_such_teacher');
  end if;
  if p_pence is null or p_pence not between 0 and 20000 then
    return jsonb_build_object('error', 'bad_rate');
  end if;
  insert into teacher_rates (teacher_id, school_id, rate_pence) values (p_teacher, sch, p_pence)
  on conflict (teacher_id) do update set rate_pence = excluded.rate_pence, updated_at = now();
  update hours_log set rate_pence = p_pence
   where teacher_id = p_teacher and school_id = sch and rate_pence is null;
  get diagnostics filled = row_count;
  return jsonb_build_object('ok', true, 'filled', filled);
end $$;

-- ---------- the week, as the screen shows it ----------
-- An admin gets every teacher in the school with rate and pay. A teacher gets
-- one row, their own, with the rate and the pay left null. Everyone else gets
-- nothing. The decision is made here, not in the page.
create or replace function hours_week(p_week_start date)
returns table (teacher_id uuid, teacher_name text, classes text, minutes int,
               rate_pence int, pay_pence bigint, rows_without_rate int)
language plpgsql stable security definer set search_path = public, extensions, pg_temp as $$
declare is_admin boolean := ll_role() = 'admin'; me uuid := ll_me(); sch uuid := ll_school();
begin
  if sch is null or ll_role() not in ('admin', 'teacher') then return; end if;
  return query
  select h.teacher_id, p.full_name,
         coalesce(string_agg(distinct c.name, ', ' order by c.name), '')::text,
         sum(h.minutes)::int,
         case when is_admin then
           (select tr.rate_pence from teacher_rates tr where tr.teacher_id = h.teacher_id) end,
         case when is_admin then
           round(sum(case when h.rate_pence is not null then h.minutes * h.rate_pence else 0 end) / 60.0)::bigint end,
         (count(*) filter (where h.rate_pence is null))::int
  from hours_log h
  join profiles p on p.id = h.teacher_id
  left join classes c on c.id = h.class_id
  where h.school_id = sch
    and h.on_date >= p_week_start and h.on_date < p_week_start + 7
    and (is_admin or h.teacher_id = me)
  group by h.teacher_id, p.full_name
  order by p.full_name;
end $$;

revoke all on function hours_generate_week(date), hours_add(uuid, uuid, date, int, text),
  hours_set_rate(uuid, int), hours_week(date) from public, anon;
grant execute on function hours_generate_week(date), hours_add(uuid, uuid, date, int, text),
  hours_set_rate(uuid, int), hours_week(date) to authenticated;
