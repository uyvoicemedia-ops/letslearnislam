-- ============================================================
-- LetsLearn — sensible limits on gifts from adults
--
-- 0023 let a teacher or parent give 1 to 100 coins at a time, 200 a day to
-- one child. Against the rest of the economy that is far too much: a whole
-- day of honest practice pays at most 40, a day in class 20, and the first
-- house costs 60. One 100-coin gift would buy a child half their garden.
--
-- A gift is meant to say "well done", not to be a second income. New bounds,
-- by who is giving (the scope is unchanged: a teacher gives to children in
-- their classes, a parent to their own children, an admin within the school):
--
--                       one gift   to one child, a day   in all, a day
--   teacher / admin        30            40                  400
--   parent                 20            30                  120
--
-- A teacher with a class of twenty can thank every child with 20 coins. A
-- parent with four children can thank each of them with 30. Nothing else
-- about points_give changes: same name and signature (so the grants stay),
-- same checks, same recording, links still removed from the reason.
-- ============================================================

create or replace function points_give(p_pupil uuid, p_amount int, p_reason text) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare me uuid := ll_me(); r user_role := ll_role(); today_pupil int; today_all int; src point_source; why text;
        max_one int; max_child int; max_all int;
begin
  if me is null or r not in ('teacher', 'admin', 'parent') or not coalesce(ll_adult_session(), false) then return jsonb_build_object('error', 'not_allowed'); end if;
  if not ll_can_see_pupil(p_pupil) then return jsonb_build_object('error', 'not_allowed'); end if;
  if not ll_real_pupil(p_pupil) then return jsonb_build_object('error', 'not_allowed'); end if;
  if r = 'parent' then max_one := 20; max_child := 30; max_all := 120;
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
