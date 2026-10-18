-- ============================================================
-- LetsLearn — the coin ledger, held by the server (part 2)
-- ------------------------------------------------------------
-- THE RULE: a child must never be able to give themselves coins.
--
-- Until now a child's balance lived on their device (the garden's
-- "deeds" counter, saved inside the garden document), so anyone who could
-- open the browser's developer tools could type any number. This file is
-- the foundation of the fix: the `points` table becomes the one true
-- ledger, and the only ways to change it are functions that apply rules.
--
--   * Earning goes through ll_mint(): internal, callable by nobody signed
--     in or out. Later migrations (practice, attendance, missions...) are
--     the only callers. It is idempotent on (child, kind, reference), so
--     a retried request cannot pay twice; it refuses test students (their
--     coins are the fake ones on the device); it refuses anything not
--     positive.
--   * Spending is a NEGATIVE entry: coins_spend() lets a child pay, never
--     below nothing, under a lock so two fast taps cannot both succeed on
--     one balance. coins_refund() gives back HALF of a spend the child
--     really made, once. A child can lose coins this way; they cannot gain.
--   * Adults give coins through points_give(): 1 to 100 a time, to a child
--     they may see, with a daily ceiling per giver per child and per giver
--     overall, so one stolen adult login cannot mint without limit.
--   * Nobody signed in can insert, change or delete a points row directly
--     any more. The old "adults give points" policy is gone.
--   * garden.spent, which the client writes, used to be subtracted from
--     the balance. Lowering it would have INCREASED it. The balance is now
--     the ledger alone, and the column can only ever go up from the client.
--
-- The garden's own state is still on the device; moving the app's earning
-- and spending onto these functions is the next step (the cut-over).
-- Until then nothing about how the app behaves changes.
-- ============================================================

-- ---------- the ledger ----------
alter table points add column if not exists source_ref text;
create unique index if not exists points_once_per_ref on points (pupil_id, source, source_ref) where source_ref is not null;

alter table points drop constraint if exists points_sign;
alter table points add constraint points_sign check (
  (source = 'spend' and amount < 0) or (source = 'adjustment' and amount <> 0) or (source not in ('spend', 'adjustment') and amount > 0)
) not valid;
alter table points drop constraint if exists points_reason_short;
alter table points add constraint points_reason_short check (reason is null or length(reason) <= 120) not valid;

-- the amounts the rules use, in one place, readable by nobody signed in (a child has no business
-- knowing the sums that decide what is worth doing; the app is told what it earned)
create table if not exists reward_rates (
  key         text primary key,
  coins       int  not null check (coins >= 0),
  per_day_cap int,
  note        text
);
alter table reward_rates enable row level security;
revoke all on reward_rates from anon, authenticated;
insert into reward_rates (key, coins, per_day_cap, note) values
  ('welcome',            100, null, 'once, on joining a class'),
  ('attendance_present',   5, null, 'a register mark of present or late, once a class day'),
  ('attendance_on_time',  10, null, 'on time: present, not late'),
  ('attendance_camera',    5, null, 'camera on, as ticked by the teacher'),
  ('dhikr_set',           10, 30,   'a set of 33; three sets a day pay'),
  ('reading_session',     15, null, 'a reading session of at least ten minutes'),
  ('practice_session',    10, null, 'ten minutes of practice'),
  ('activity_day_cap',    40, 40,   'most coins a child can earn from practice, reading, dhikr and missions in one London day')
  on conflict (key) do nothing;

-- ---------- who is a child with real coins ----------
create or replace function ll_real_pupil(p_pupil uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from profiles p where p.id = p_pupil and p.role = 'student' and coalesce(p.is_test, false) = false);
$$;

create or replace function ll_balance(p_pupil uuid) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(amount), 0)::int from points where pupil_id = p_pupil;
$$;

-- the old function subtracted garden.spent, which a child writes; it now reads the ledger alone
create or replace function points_balance(p_pupil uuid) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select case when ll_can_see_pupil(p_pupil) then ll_balance(p_pupil) end;
$$;

create or replace function ll_lock_pupil(p_pupil uuid) returns void
language sql volatile security definer set search_path = public, pg_temp as $$
  select pg_advisory_xact_lock(hashtextextended('coins:' || p_pupil::text, 0));
$$;

-- ---------- earning: internal ----------
create or replace function ll_mint(p_pupil uuid, p_source point_source, p_amount int, p_ref text,
                                   p_reason text default null, p_given_by uuid default null) returns int
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare n int;
begin
  if p_source in ('spend', 'refund') or p_amount is null or p_amount <= 0 or p_amount > 100000 then return 0; end if;
  if p_ref is null or length(p_ref) not between 1 and 120 then return 0; end if;
  if not ll_real_pupil(p_pupil) then return 0; end if;              -- test students and adults never get server coins
  perform ll_lock_pupil(p_pupil);
  insert into points (pupil_id, source, amount, reason, given_by, source_ref)
    values (p_pupil, p_source, p_amount, left(p_reason, 120), p_given_by, p_ref)
    on conflict (pupil_id, source, source_ref) where source_ref is not null do nothing;
  get diagnostics n = row_count;
  return case when n = 1 then p_amount else 0 end;
end $$;

-- ---------- the child's wallet, spending and taking back ----------
create or replace function coins_wallet() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare me uuid := ll_me();
begin
  if me is null or ll_role() <> 'student' then return jsonb_build_object('error', 'not_allowed'); end if;
  if not ll_real_pupil(me) then return jsonb_build_object('error', 'test_student'); end if;
  return jsonb_build_object('balance', ll_balance(me),
    'earned', (select coalesce(sum(amount), 0) from points where pupil_id = me and amount > 0 and source <> 'refund'),
    'spent',  (select coalesce(-sum(amount), 0) from points where pupil_id = me and source = 'spend'),
    'refunded', (select coalesce(sum(amount), 0) from points where pupil_id = me and source = 'refund'));
end $$;

create or replace function coins_spend(p_amount int, p_ref text, p_what text) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare me uuid := ll_me(); bal int; existing int;
begin
  if me is null or ll_role() <> 'student' then return jsonb_build_object('error', 'not_allowed'); end if;
  if not ll_real_pupil(me) then return jsonb_build_object('error', 'test_student'); end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then return jsonb_build_object('error', 'bad_amount'); end if;
  if p_ref is null or p_ref !~ '^[A-Za-z0-9:_-]{8,64}$' then return jsonb_build_object('error', 'bad_ref'); end if;
  perform ll_lock_pupil(me);
  select -amount into existing from points where pupil_id = me and source = 'spend' and source_ref = p_ref;
  if found then return jsonb_build_object('ok', true, 'balance', ll_balance(me), 'already', true); end if;   -- a retry never charges twice
  bal := ll_balance(me);
  if bal < p_amount then return jsonb_build_object('error', 'not_enough', 'balance', bal); end if;
  insert into points (pupil_id, source, amount, reason, source_ref)
    values (me, 'spend', -p_amount, left(btrim(regexp_replace(coalesce(p_what, ''), '(https?://|www\.)\S+', '<link>', 'gi')), 60), p_ref);
  return jsonb_build_object('ok', true, 'balance', bal - p_amount);
end $$;

-- half of a spend the child really made, once. The most this can ever do is return less than was paid.
create or replace function coins_refund(p_ref text) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare me uuid := ll_me(); paid int; back int; n int;
begin
  if me is null or ll_role() <> 'student' then return jsonb_build_object('error', 'not_allowed'); end if;
  if not ll_real_pupil(me) then return jsonb_build_object('error', 'test_student'); end if;
  if p_ref is null or p_ref !~ '^[A-Za-z0-9:_-]{8,64}$' then return jsonb_build_object('error', 'bad_ref'); end if;
  perform ll_lock_pupil(me);
  select -amount into paid from points where pupil_id = me and source = 'spend' and source_ref = p_ref;
  if not found then return jsonb_build_object('error', 'no_such_spend'); end if;
  back := paid / 2;                                                  -- half, rounded down
  if back < 1 then return jsonb_build_object('ok', true, 'refunded', 0, 'balance', ll_balance(me)); end if;
  insert into points (pupil_id, source, amount, reason, source_ref)
    values (me, 'refund', back, 'half back', 'refund:' || p_ref)
    on conflict (pupil_id, source, source_ref) where source_ref is not null do nothing;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'refunded', case when n = 1 then back else 0 end, 'already', n = 0, 'balance', ll_balance(me));
end $$;

-- ---------- an adult giving coins ----------
create or replace function points_give(p_pupil uuid, p_amount int, p_reason text) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare me uuid := ll_me(); r user_role := ll_role(); today_pupil int; today_all int; src point_source; why text;
begin
  if me is null or r not in ('teacher', 'admin', 'parent') or not coalesce(ll_adult_session(), false) then return jsonb_build_object('error', 'not_allowed'); end if;
  if not ll_can_see_pupil(p_pupil) then return jsonb_build_object('error', 'not_allowed'); end if;
  if not ll_real_pupil(p_pupil) then return jsonb_build_object('error', 'not_allowed'); end if;
  if p_amount is null or p_amount < 1 or p_amount > 100 then return jsonb_build_object('error', 'bad_amount'); end if;
  select coalesce(sum(amount), 0) into today_pupil from points
   where given_by = me and pupil_id = p_pupil and source in ('teacher_gift', 'parent_gift') and (at at time zone 'Europe/London')::date = (now() at time zone 'Europe/London')::date;
  select coalesce(sum(amount), 0) into today_all from points
   where given_by = me and source in ('teacher_gift', 'parent_gift') and (at at time zone 'Europe/London')::date = (now() at time zone 'Europe/London')::date;
  if today_pupil + p_amount > 200 then return jsonb_build_object('error', 'daily_limit_child'); end if;
  if today_all + p_amount > 1000 then return jsonb_build_object('error', 'daily_limit_total'); end if;
  src := case when r = 'parent' then 'parent_gift' else 'teacher_gift' end;
  why := nullif(left(btrim(regexp_replace(coalesce(p_reason, ''), '(https?://|www\.)\S+', '<link>', 'gi')), 120), '');
  perform ll_lock_pupil(p_pupil);
  insert into points (pupil_id, source, amount, reason, given_by, source_ref)
    values (p_pupil, src, p_amount, why, me, 'gift:' || gen_random_uuid()::text);
  return jsonb_build_object('ok', true, 'amount', p_amount);
end $$;

-- ---------- nobody writes the ledger directly ----------
drop policy if exists "adults give points" on points;
revoke insert, update, delete, truncate on points from anon, authenticated;

-- ---------- the garden's own 'spent' can only go up ----------
create or replace function ll_garden_spent_guard() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if current_user in ('anon', 'authenticated') then new.spent := greatest(coalesce(new.spent, 0), coalesce(old.spent, 0)); end if;
  return new;
end $$;
drop trigger if exists ll_garden_spent_guard on garden;
create trigger ll_garden_spent_guard before update on garden for each row execute function ll_garden_spent_guard();

-- ---------- the report counts coins EARNED, not coins spent ----------
do $$
declare def text;
begin
  select pg_get_functiondef('pupil_report(uuid,date,date)'::regprocedure) into def;
  def := replace(def, 'from points where pupil_id = p_pupil and (at at time zone ''Europe/London'')::date between p_from and p_to;',
                      'from points where pupil_id = p_pupil and amount > 0 and source not in (''spend'', ''refund'') and (at at time zone ''Europe/London'')::date between p_from and p_to;');
  def := replace(def, 'from (select source, sum(amount) as amt from points
                               where pupil_id = p_pupil and (at at time zone ''Europe/London'')::date between p_from and p_to',
                      'from (select source, sum(amount) as amt from points
                               where pupil_id = p_pupil and amount > 0 and source not in (''spend'', ''refund'') and (at at time zone ''Europe/London'')::date between p_from and p_to');
  execute def;
end $$;

-- ---------- who may call what ----------
revoke all on function ll_real_pupil(uuid), ll_balance(uuid), ll_lock_pupil(uuid),
  ll_mint(uuid, point_source, int, text, text, uuid), ll_garden_spent_guard() from public, anon, authenticated;
revoke all on function coins_wallet(), coins_spend(int, text, text), coins_refund(text), points_give(uuid, int, text) from public, anon;
grant execute on function coins_wallet(), coins_spend(int, text, text), coins_refund(text), points_give(uuid, int, text) to authenticated;
