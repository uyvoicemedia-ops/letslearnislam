-- ============================================================
-- LetsLearn — a parent can take a few coins away; and a fuller family day
--
-- Two changes to what a parent may do with their own child's coins.
--
-- 1. points_take(pupil, reason): a parent takes away exactly 5 coins, with
--    a reason the child can see. This is for ordinary home discipline, so it
--    is small and bounded:
--      * parents only, and only their own children (a teacher or admin
--        cannot take coins; the school cannot fine a child);
--      * always 5, nothing else, so it can never be a big punishment;
--      * a reason is required;
--      * never below nothing: a child with fewer than 5 coins cannot be
--        charged;
--      * at most 2 times to one child in a day, and 6 in all in a day.
--    It is recorded as an 'adjustment' (the ledger already allows a negative
--    one: see the points_sign check in 0023), with who did it. Nothing is
--    deleted or edited; a parent who takes by mistake simply gives back with
--    points_give.
--
-- 2. points_give, parent limits only: 0027 allowed a parent 30 coins to one
--    child in a day and 120 in all. A real family day (teeth morning and
--    evening, the prayers, helping, tidying) is more than six small
--    thank-yous, so a parent may now give 40 to one child in a day and 160
--    in all (one gift is still at most 20). Teachers and admins are unchanged.
-- ============================================================

create or replace function points_give(p_pupil uuid, p_amount int, p_reason text) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare me uuid := ll_me(); r user_role := ll_role(); today_pupil int; today_all int; src point_source; why text;
        max_one int; max_child int; max_all int;
begin
  if me is null or r not in ('teacher', 'admin', 'parent') or not coalesce(ll_adult_session(), false) then return jsonb_build_object('error', 'not_allowed'); end if;
  if not ll_can_see_pupil(p_pupil) then return jsonb_build_object('error', 'not_allowed'); end if;
  if not ll_real_pupil(p_pupil) then return jsonb_build_object('error', 'not_allowed'); end if;
  if r = 'parent' then max_one := 20; max_child := 40; max_all := 160;
  else max_one := 30; max_child := 40; max_all := 400; end if;
  if p_amount is null or p_amount < 1 or p_amount > max_one then return jsonb_build_object('error', 'bad_amount', 'max', max_one); end if;
  select coalesce(sum(amount), 0) into today_pupil from points
   where given_by = me and pupil_id = p_pupil and source in ('teacher_gift', 'parent_gift') and (at at time zone 'Europe/London')::date = (now() at time zone 'Europe/London')::date;
  select coalesce(sum(amount), 0) into today_all from points
   where given_by = me and source in ('teacher_gift', 'parent_gift') and (at at time zone 'Europe/London')::date = (now() at time zone 'Europe/London')::date;
  if today_pupil + p_amount > max_child then return jsonb_build_object('error', 'daily_limit_child', 'left', greatest(0, max_child - today_pupil)); end if;
  if today_all + p_amount > max_all then return jsonb_build_object('error', 'daily_limit_total', 'left', greatest(0, max_all - today_all)); end if;
  src := case when r = 'parent' then 'parent_gift' else 'teacher_gift' end;
  why := nullif(left(btrim(regexp_replace(coalesce(p_reason, ''), '(https?://|www\.)\S+', '<link>', 'gi')), 120), '');
  perform ll_lock_pupil(p_pupil);
  insert into points (pupil_id, source, amount, reason, given_by, source_ref)
    values (p_pupil, src, p_amount, why, me, 'gift:' || gen_random_uuid()::text);
  return jsonb_build_object('ok', true, 'amount', p_amount);
end $$;

create or replace function points_take(p_pupil uuid, p_reason text) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare me uuid := ll_me(); why text; bal int; n_pupil int; n_all int;
        amt constant int := 5; max_child constant int := 2; max_all constant int := 6;
begin
  if me is null or ll_role() <> 'parent' or not coalesce(ll_adult_session(), false) then return jsonb_build_object('error', 'not_allowed'); end if;
  if not ll_can_see_pupil(p_pupil) or not ll_real_pupil(p_pupil) then return jsonb_build_object('error', 'not_allowed'); end if;
  why := nullif(left(btrim(regexp_replace(coalesce(p_reason, ''), '(https?://|www\.)\S+', '<link>', 'gi')), 120), '');
  if why is null then return jsonb_build_object('error', 'no_reason'); end if;
  perform ll_lock_pupil(p_pupil);
  select count(*) into n_pupil from points
   where given_by = me and pupil_id = p_pupil and source = 'adjustment' and amount < 0 and (at at time zone 'Europe/London')::date = (now() at time zone 'Europe/London')::date;
  select count(*) into n_all from points
   where given_by = me and source = 'adjustment' and amount < 0 and (at at time zone 'Europe/London')::date = (now() at time zone 'Europe/London')::date;
  if n_pupil >= max_child then return jsonb_build_object('error', 'daily_limit_child'); end if;
  if n_all >= max_all then return jsonb_build_object('error', 'daily_limit_total'); end if;
  bal := ll_balance(p_pupil);
  if bal < amt then return jsonb_build_object('error', 'not_enough', 'balance', bal); end if;
  insert into points (pupil_id, source, amount, reason, given_by, source_ref)
    values (p_pupil, 'adjustment', -amt, why, me, 'take:' || gen_random_uuid()::text);
  return jsonb_build_object('ok', true, 'amount', amt, 'balance', bal - amt);
end $$;

revoke all on function points_take(uuid, text) from public, anon;
grant execute on function points_take(uuid, text) to authenticated;
