-- ============================================================
-- LetsLearn — how a child EARNS coins, by rules the server applies
-- ------------------------------------------------------------
-- Part 3 of the coin ledger (0022 enum, 0023 ledger, 0024 enum). Every way
-- of earning is now a function that checks what it can check and pays only
-- through ll_mint(), so a child cannot write their own balance.
--
-- What the server can PROVE and what it cannot, said plainly:
--   * It can prove a register was marked by the teacher (attendance),
--     that homework was marked by the teacher, that a child joined a class.
--     Those pay without any claim from the child.
--   * It cannot prove a child really practised, read, said dhikr or prayed:
--     those are claims. So they are made hard to farm instead of impossible:
--     a practice reward must point at a practice row made in the last 15
--     minutes, once per row, at least 60 seconds apart; dhikr sets come in
--     order, at least a minute apart, three a day; a book pays once a day;
--     a prayer pays once a day. And all of them together, with sleep and club
--     gone, share ONE daily ceiling (40 coins, in reward_rates). The most a
--     child can get by lying about every one of them is that ceiling.
--   * Coins from the teacher (attendance, homework, gifts) are outside that
--     ceiling, each with its own bound.
--
-- Every function answers { ok, minted, capped, balance } or { error }.
-- ============================================================

insert into reward_rates (key, coins, per_day_cap, note) values
  ('salah_each',        6, null, 'each prayer ticked, once a day'),
  ('salah_bonus',      20, null, 'all five ticked in a day'),
  ('homework_good',    15, null, 'homework marked 80 or more'),
  ('homework_ok',      10, null, 'homework marked 50 to 79'),
  ('homework_any',      5, null, 'homework marked below 50'),
  ('homework_day_cap', 45, 45,   'most coins from marked homework in one London day')
  on conflict (key) do nothing;

create or replace function ll_rate(p_key text) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select coins from reward_rates where key = p_key), 0);
$$;

-- coins still earnable today from these kinds, under a ceiling
create or replace function ll_room(p_pupil uuid, p_sources point_source[], p_cap int) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select greatest(0, p_cap - coalesce((select sum(amount) from points
          where pupil_id = p_pupil and amount > 0 and source = any (p_sources)
            and (at at time zone 'Europe/London')::date = (now() at time zone 'Europe/London')::date), 0))::int;
$$;

create or replace function ll_activity_sources() returns point_source[]
language sql immutable set search_path = public, pg_temp as $$
  select array['practice', 'reading', 'dhikr', 'salah', 'mission', 'quiz', 'streak']::point_source[];
$$;

-- mint, but never past a daily ceiling; the lock is taken first so two quick requests cannot both fit
create or replace function ll_mint_within(p_pupil uuid, p_source point_source, p_amount int, p_ref text, p_reason text,
                                          p_sources point_source[], p_cap int) returns int
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare amt int;
begin
  perform ll_lock_pupil(p_pupil);
  amt := least(p_amount, ll_room(p_pupil, p_sources, p_cap));
  if amt <= 0 then return 0; end if;
  return ll_mint(p_pupil, p_source, amt, p_ref, p_reason);
end $$;

create or replace function ll_child() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select case when ll_role() = 'student' and ll_real_pupil(ll_me()) then ll_me() end;
$$;

create or replace function ll_today() returns date
language sql stable set search_path = public, pg_temp as $$ select (now() at time zone 'Europe/London')::date $$;

-- ---------- joining a class: a welcome, once, ever ----------
create or replace function ll_welcome() returns trigger
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform ll_mint(new.pupil_id, 'welcome', ll_rate('welcome'), 'welcome', 'Welcome to the class');
  return new;
exception when others then return new;
end $$;
drop trigger if exists ll_welcome on enrolments;
create trigger ll_welcome after insert on enrolments for each row execute function ll_welcome();

-- ---------- the register: paid by the teacher finishing it ----------
alter table attendance add column if not exists camera_on boolean not null default false;

create or replace function attendance_set_camera(p_class uuid, p_pupil uuid, p_date date, p_on boolean) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  if ll_role() not in ('teacher', 'admin') or not ll_manages_class(p_class) then return jsonb_build_object('error', 'not_allowed'); end if;
  if p_on is null or p_date is null then return jsonb_build_object('error', 'bad_value'); end if;
  if not exists (select 1 from enrolments where class_id = p_class and pupil_id = p_pupil) then return jsonb_build_object('error', 'not_in_class'); end if;
  update attendance set camera_on = p_on
   where class_id = p_class and pupil_id = p_pupil and on_date = p_date and mark in ('present', 'late');
  if not found then return jsonb_build_object('error', 'not_marked_here'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- Pays for the day's register: came to class, on time, camera on. Each is paid at most once per child per
-- class per day (the reference says so), so it can be pressed again after a late correction and only the
-- new part pays. Coins already paid are not taken back if a mark is changed later.
create or replace function register_finish(p_class uuid, p_date date) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare r record; kids int := 0; coins int := 0; got int; k text;
begin
  if ll_role() not in ('teacher', 'admin') or not ll_manages_class(p_class) then return jsonb_build_object('error', 'not_allowed'); end if;
  if p_date is null or p_date > ll_today() or p_date < ll_today() - 1 then return jsonb_build_object('error', 'bad_date'); end if;
  for r in select a.pupil_id, a.mark, a.camera_on from attendance a
             join enrolments e on e.pupil_id = a.pupil_id and e.class_id = p_class
            where a.class_id = p_class and a.on_date = p_date and a.mark in ('present', 'late') loop
    k := 'reg:' || p_class || ':' || p_date;
    got := ll_mint(r.pupil_id, 'attendance', ll_rate('attendance_present'), k || ':here', 'Came to class');
    if r.mark = 'present' then got := got + ll_mint(r.pupil_id, 'attendance', ll_rate('attendance_on_time'), k || ':ontime', 'On time'); end if;
    if r.camera_on then got := got + ll_mint(r.pupil_id, 'attendance', ll_rate('attendance_camera'), k || ':camera', 'Camera on'); end if;
    if got > 0 then kids := kids + 1; coins := coins + got; end if;
  end loop;
  return jsonb_build_object('ok', true, 'children', kids, 'coins', coins);
end $$;

-- ---------- marked homework pays the child ----------
create or replace function ll_homework_paid() returns trigger
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare amt int;
begin
  if new.marked_at is null or old.marked_at is not null then return new; end if;                  -- the first marking only
  amt := case when coalesce(new.score, 0) >= 80 then ll_rate('homework_good') when coalesce(new.score, 0) >= 50 then ll_rate('homework_ok') else ll_rate('homework_any') end;
  perform ll_mint_within(new.pupil_id, 'homework', amt, 'hw:' || new.homework_id, 'Homework marked', array['homework']::point_source[], ll_rate('homework_day_cap'));
  return new;
exception when others then return new;
end $$;
drop trigger if exists ll_homework_paid on submissions;
create trigger ll_homework_paid after update of marked_at on submissions for each row execute function ll_homework_paid();

-- ---------- claims a child makes: practice, dhikr, reading, prayer ----------
create or replace function earn_practice(p_id bigint) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare me uuid := ll_child(); p practice%rowtype; base int; coins int; got int;
begin
  if me is null then return jsonb_build_object('error', 'not_allowed'); end if;
  select * into p from practice where id = p_id and pupil_id = me;
  if not found then return jsonb_build_object('error', 'no_such_practice'); end if;
  if p.at < now() - interval '15 minutes' then return jsonb_build_object('error', 'too_old'); end if;
  if exists (select 1 from points where pupil_id = me and source = 'practice' and at > now() - interval '60 seconds') then
    return jsonb_build_object('error', 'too_fast', 'balance', ll_balance(me));
  end if;
  base := ll_rate('practice_session');
  coins := case when p.score >= 80 then base when p.score >= 50 then base * 6 / 10 else base * 3 / 10 end;
  got := ll_mint_within(me, 'practice', coins, 'practice:' || p_id, 'Practice', ll_activity_sources(), ll_rate('activity_day_cap'));
  return jsonb_build_object('ok', true, 'minted', got, 'capped', got < coins, 'balance', ll_balance(me));
end $$;

create or replace function earn_dhikr(p_set int) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare me uuid := ll_child(); d text := ll_today()::text; coins int := ll_rate('dhikr_set'); got int;
begin
  if me is null then return jsonb_build_object('error', 'not_allowed'); end if;
  if p_set is null or p_set not between 1 and 3 then return jsonb_build_object('error', 'bad_set'); end if;
  if exists (select 1 from points where pupil_id = me and source = 'dhikr' and source_ref = 'dhikr:' || d || ':' || p_set) then
    return jsonb_build_object('ok', true, 'minted', 0, 'already', true, 'balance', ll_balance(me));
  end if;
  if p_set > 1 and not exists (select 1 from points where pupil_id = me and source = 'dhikr' and source_ref = 'dhikr:' || d || ':' || (p_set - 1)) then
    return jsonb_build_object('error', 'out_of_order');
  end if;
  if exists (select 1 from points where pupil_id = me and source = 'dhikr' and at > now() - interval '60 seconds') then       -- thirty-three takes longer than that
    return jsonb_build_object('error', 'too_fast', 'balance', ll_balance(me));
  end if;
  got := ll_mint_within(me, 'dhikr', coins, 'dhikr:' || d || ':' || p_set, 'Dhikr', ll_activity_sources(), ll_rate('activity_day_cap'));
  return jsonb_build_object('ok', true, 'minted', got, 'capped', got < coins, 'balance', ll_balance(me));
end $$;

create or replace function earn_salah(p_prayer text) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare me uuid := ll_child(); d text := ll_today()::text; got int; bonus int := 0; n int;
begin
  if me is null then return jsonb_build_object('error', 'not_allowed'); end if;
  if p_prayer is null or p_prayer not in ('fajr', 'dhuhr', 'asr', 'maghrib', 'isha') then return jsonb_build_object('error', 'bad_prayer'); end if;
  got := ll_mint_within(me, 'salah', ll_rate('salah_each'), 'salah:' || d || ':' || p_prayer, 'Prayer', ll_activity_sources(), ll_rate('activity_day_cap'));
  select count(*) into n from points where pupil_id = me and source = 'salah' and source_ref like 'salah:' || d || ':%' and source_ref not like '%:bonus';
  if n >= 5 then
    bonus := ll_mint_within(me, 'salah', ll_rate('salah_bonus'), 'salah:' || d || ':bonus', 'All five prayers', ll_activity_sources(), ll_rate('activity_day_cap'));
  end if;
  return jsonb_build_object('ok', true, 'minted', got + bonus, 'bonus', bonus, 'capped', (got + bonus) < ll_rate('salah_each') and n < 5 and got = 0, 'balance', ll_balance(me));
end $$;

create or replace function earn_reading(p_book text) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare me uuid := ll_child(); r reading%rowtype; coins int := ll_rate('reading_session'); got int;
begin
  if me is null then return jsonb_build_object('error', 'not_allowed'); end if;
  if p_book is null or p_book !~ '^[A-Za-z0-9_-]{1,40}$' then return jsonb_build_object('error', 'bad_book'); end if;
  select * into r from reading where pupil_id = me and book_id = p_book;
  if not found or r.page < 3 then return jsonb_build_object('error', 'no_reading'); end if;
  if r.updated_at < now() - interval '15 minutes' then return jsonb_build_object('error', 'too_old'); end if;
  got := ll_mint_within(me, 'reading', coins, 'reading:' || p_book || ':' || ll_today(), 'Reading', ll_activity_sources(), ll_rate('activity_day_cap'));
  return jsonb_build_object('ok', true, 'minted', got, 'capped', got = 0 and not exists (select 1 from points where pupil_id = me and source_ref = 'reading:' || p_book || ':' || ll_today()), 'balance', ll_balance(me));
end $$;

-- ---------- who may call what ----------
revoke all on function ll_rate(text), ll_room(uuid, point_source[], int), ll_activity_sources(),
  ll_mint_within(uuid, point_source, int, text, text, point_source[], int), ll_child(), ll_today(),
  ll_welcome(), ll_homework_paid() from public, anon, authenticated;
revoke all on function attendance_set_camera(uuid, uuid, date, boolean), register_finish(uuid, date),
  earn_practice(bigint), earn_dhikr(int), earn_salah(text), earn_reading(text) from public, anon;
grant execute on function attendance_set_camera(uuid, uuid, date, boolean), register_finish(uuid, date),
  earn_practice(bigint), earn_dhikr(int), earn_salah(text), earn_reading(text) to authenticated;
