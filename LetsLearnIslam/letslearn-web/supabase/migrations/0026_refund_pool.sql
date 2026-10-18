-- ============================================================
-- LetsLearn — selling for half, without tracking what each coin bought
-- ------------------------------------------------------------
-- 0023's coins_refund(ref) gives back half of ONE named spend. The garden
-- sells many kinds of thing (items, buildings, upgrades, land, rooms, styles)
-- through two dozen different code paths, and none of them remembers which
-- purchase paid for what. Rather than rewrite them all, the app asks for a
-- refund of an AMOUNT, and the server enforces the one rule that matters:
--
--     the total ever refunded can never exceed half the total ever spent.
--
-- So selling can only ever return less than was paid, in total, however the
-- child orders their buying and selling. A child who claims a refund for
-- something they still own simply loses the other half of its price.
--
-- coins_refund(ref) is tightened to the same rule, so the two can be used
-- together without ever giving back more than half in total.
-- ============================================================

create or replace function ll_refund_room(p_pupil uuid) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select greatest(0,
    (coalesce((select -sum(amount) from points where pupil_id = p_pupil and source = 'spend'), 0) / 2)::int
    - coalesce((select sum(amount) from points where pupil_id = p_pupil and source = 'refund'), 0)::int);
$$;

create or replace function coins_refund_pool(p_amount int, p_ref text) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare me uuid := ll_me(); amt int;
begin
  if me is null or ll_role() <> 'student' then return jsonb_build_object('error', 'not_allowed'); end if;
  if not ll_real_pupil(me) then return jsonb_build_object('error', 'test_student'); end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then return jsonb_build_object('error', 'bad_amount'); end if;
  if p_ref is null or p_ref !~ '^[A-Za-z0-9:_-]{8,64}$' then return jsonb_build_object('error', 'bad_ref'); end if;
  perform ll_lock_pupil(me);
  if exists (select 1 from points where pupil_id = me and source = 'refund' and source_ref = 'pool:' || p_ref) then
    return jsonb_build_object('ok', true, 'refunded', 0, 'already', true, 'balance', ll_balance(me));
  end if;
  amt := least(p_amount, ll_refund_room(me));
  if amt < 1 then return jsonb_build_object('ok', true, 'refunded', 0, 'balance', ll_balance(me)); end if;
  insert into points (pupil_id, source, amount, reason, source_ref) values (me, 'refund', amt, 'sold', 'pool:' || p_ref);
  return jsonb_build_object('ok', true, 'refunded', amt, 'balance', ll_balance(me));
end $$;

-- the per-spend refund obeys the same total
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
  if exists (select 1 from points where pupil_id = me and source = 'refund' and source_ref = 'refund:' || p_ref) then
    return jsonb_build_object('ok', true, 'refunded', 0, 'already', true, 'balance', ll_balance(me));
  end if;
  back := least(paid / 2, ll_refund_room(me));                       -- half, rounded down, and never past half of everything spent
  if back < 1 then return jsonb_build_object('ok', true, 'refunded', 0, 'balance', ll_balance(me)); end if;
  insert into points (pupil_id, source, amount, reason, source_ref) values (me, 'refund', back, 'half back', 'refund:' || p_ref);
  return jsonb_build_object('ok', true, 'refunded', back, 'balance', ll_balance(me));
end $$;

revoke all on function ll_refund_room(uuid) from public, anon, authenticated;
revoke all on function coins_refund_pool(int, text) from public, anon;
grant execute on function coins_refund_pool(int, text) to authenticated;
