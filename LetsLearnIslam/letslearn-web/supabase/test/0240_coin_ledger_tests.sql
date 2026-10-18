-- ============================================================
-- The coin ledger (0022, 0023): a child must never be able to give themselves coins.
-- Runs after 0230; reuses t_assert, t_be, t_count, t_say.
-- ============================================================
do $$
declare
  sch uuid; schb uuid; c_q1 uuid;
  aisha uuid; bilal uuid; hamza uuid; fatima uuid; mauluda uuid; abdur uuid; yusuf uuid; adminb uuid;
  fatima_uid uuid; mauluda_uid uuid; abdur_uid uuid; yusuf_uid uuid; ab_uid uuid; kid uuid; kid2 uuid;
  b0 int; b1 int; j jsonb; n int; r record; i int; ref text;
begin
  select id into sch from schools where name = 'Al-Noor Madrasah';
  select id into c_q1 from classes where join_code = 'QAIDA1';
  select id into aisha from profiles where full_name = 'Aisha Khan';
  select id into bilal from profiles where full_name = 'Bilal Ahmed';
  select id into hamza from profiles where full_name = 'Hamza Malik';
  select id, auth_uid into fatima, fatima_uid from profiles where full_name = 'Fatima Khan';
  select id, auth_uid into mauluda, mauluda_uid from profiles where full_name = 'Mauluda Begum';
  select id, auth_uid into abdur, abdur_uid from profiles where full_name = 'Abdur Rahman';
  select id, auth_uid into yusuf, yusuf_uid from profiles where full_name = 'Yusuf Ibrahim';
  select id, auth_uid into adminb, ab_uid from profiles where full_name = 'Admin B';
  insert into auth.users (is_anonymous) values (true) returning id into kid;
  insert into auth.users (is_anonymous) values (true) returning id into kid2;
  update profiles set auth_uid = kid where id = aisha;
  update profiles set auth_uid = kid2 where id = hamza;
  b0 := ll_balance(aisha);

  raise notice 'the existing coins still satisfy the new rules';
  perform t_assert((select count(*) from points where not ((source = 'spend' and amount < 0) or (source = 'adjustment' and amount <> 0) or (source not in ('spend', 'adjustment') and amount > 0))) = 0, 'every row already in the ledger obeys the sign rule');

  raise notice 'the minting door is shut to everyone signed in or out';
  set local role authenticated; perform t_be(kid);
  perform t_assert(t_say($q$select ll_mint(gen_random_uuid(), 'practice', 10, 'x')$q$) like '42501%', 'a child cannot call ll_mint');
  reset role; perform t_be(mauluda_uid); set local role authenticated;
  perform t_assert(t_say($q$select ll_mint(gen_random_uuid(), 'practice', 10, 'x')$q$) like '42501%', 'nor can a teacher');
  reset role; perform t_be(null); set local role anon;
  perform t_assert(t_say($q$select ll_mint(gen_random_uuid(), 'practice', 10, 'x')$q$) like '42501%', 'nor a signed-out visitor');
  reset role;

  raise notice 'll_mint: the rules, as the server itself would use it';
  n := ll_mint(aisha, 'practice', 10, 'mint-1');                       -- (a function's effects are not visible to a query in the same statement)
  perform t_assert(n = 10 and ll_balance(aisha) = b0 + 10, 'it mints once');
  n := ll_mint(aisha, 'practice', 10, 'mint-1');
  perform t_assert(n = 0 and ll_balance(aisha) = b0 + 10, 'the same reference again pays nothing (a retried request cannot pay twice)');
  perform t_assert(ll_mint(aisha, 'practice', 10, 'mint-2') = 10, 'a different reference pays');
  perform t_assert(ll_mint(aisha, 'reading', 10, 'mint-1') = 10, 'the same reference under another kind is its own entry');
  perform t_assert(ll_mint(aisha, 'practice', 0, 'z') = 0 and ll_mint(aisha, 'practice', -5, 'z') = 0 and ll_mint(aisha, 'practice', null, 'z') = 0 and ll_mint(aisha, 'practice', 100001, 'z') = 0, 'zero, negative, null and absurd amounts mint nothing');
  perform t_assert(ll_mint(aisha, 'spend', 10, 'z') = 0 and ll_mint(aisha, 'refund', 10, 'z') = 0, 'spend and refund cannot be minted');
  perform t_assert(ll_mint(aisha, 'practice', 10, null) = 0 and ll_mint(aisha, 'practice', 10, '') = 0 and ll_mint(aisha, 'practice', 10, repeat('x', 121)) = 0, 'a missing or silly reference mints nothing');
  perform t_assert(ll_mint(mauluda, 'practice', 10, 'adult') = 0 and ll_mint(gen_random_uuid(), 'practice', 10, 'ghost') = 0, 'an adult, or somebody who does not exist, gets nothing');
  perform t_be(null); update profiles set is_test = true where id = bilal;
  perform t_assert(ll_mint(bilal, 'practice', 10, 'test-kid') = 0 and ll_balance(bilal) = coalesce((select sum(amount) from points where pupil_id = bilal), 0), 'a test student never gets server coins (theirs are the fake ones on the device)');
  perform t_be(null); update profiles set is_test = false where id = bilal;
  perform t_assert((select count(*) from points where pupil_id = aisha and source_ref like 'mint-%') = 3, 'exactly three real entries were written');
  delete from points where source_ref like 'mint-%'; b0 := ll_balance(aisha);

  raise notice 'nobody writes the ledger directly';
  set local role authenticated; perform t_be(kid);
  perform t_assert(t_say($q$insert into points (pupil_id, source, amount) values (current_setting('request.jwt.claim.sub')::uuid, 'practice', 999)$q$) like '42501%', 'a child cannot insert a coin');
  perform t_assert(t_say($q$insert into points (pupil_id, source, amount) select id, 'practice', 999 from profiles where auth_uid = current_setting('request.jwt.claim.sub')::uuid$q$) like '42501%', 'not even for themselves by a back door');
  perform t_assert(t_say('update points set amount = 999999') like '42501%', 'cannot raise one');
  perform t_assert(t_say('delete from points') like '42501%', 'cannot delete one (a spend could otherwise be erased)');
  perform t_assert(t_say('truncate points') like '42501%', 'cannot empty the table');
  reset role;
  perform t_be(fatima_uid); set local role authenticated;
  perform t_assert(t_say($q$insert into points (pupil_id, source, amount, given_by) select pupil_id, 'parent_gift', 10, ll_me() from guardians where parent_id = ll_me() limit 1$q$) like '42501%', 'a parent cannot insert directly either: the old "adults give points" rule is gone');
  reset role; perform t_be(yusuf_uid); set local role authenticated;
  perform t_assert(t_say($q$insert into points (pupil_id, source, amount) values (gen_random_uuid(), 'adjustment', 5)$q$) like '42501%' and t_say('delete from points') like '42501%', 'nor an admin');
  reset role; perform t_be(null); set local role anon;
  perform t_assert(t_say($q$insert into points (pupil_id, source, amount) values (gen_random_uuid(), 'practice', 5)$q$) like '42501%', 'nor a visitor');
  reset role;
  perform t_assert((select count(*) from pg_policies where tablename = 'points' and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')) = 0, 'there is no write policy on points at all');
  begin insert into points (pupil_id, source, amount) values (aisha, 'spend', 10); perform t_assert(false, 'a positive spend'); exception when check_violation then perform t_assert(true, 'a "spend" must be negative (even the owner cannot write it wrong)'); end;
  begin insert into points (pupil_id, source, amount) values (aisha, 'practice', -10); perform t_assert(false, 'a negative earning'); exception when check_violation then perform t_assert(true, 'an earning must be positive'); end;
  begin insert into points (pupil_id, source, amount, reason) values (aisha, 'practice', 10, repeat('x', 121)); perform t_assert(false, 'long reason'); exception when check_violation then perform t_assert(true, 'a reason is at most 120 characters'); end;

  raise notice 'reading it';
  set local role authenticated; perform t_be(kid);
  perform t_assert(t_count(format('select 1 from points where pupil_id = %L', aisha)) >= 1, 'a child still reads their own ledger');
  perform t_assert(t_count(format('select 1 from points where pupil_id = %L', hamza)) = 0, 'but not a classmate''s');
  reset role;

  raise notice 'the wallet';
  perform t_be(kid); set local role authenticated;
  j := coins_wallet();
  reset role;
  perform t_assert((j ->> 'balance')::int = b0, 'a child sees their balance, which is the ledger summed');
  perform t_be(mauluda_uid); set local role authenticated;
  perform t_assert((coins_wallet() ->> 'error') = 'not_allowed', 'an adult has no wallet');
  reset role; perform t_be(null); set local role anon;
  perform t_assert(t_say('select coins_wallet()') like '42501%', 'a visitor cannot ask');
  reset role;
  perform t_be(null); update profiles set is_test = true where id = aisha; perform t_be(kid); set local role authenticated;
  perform t_assert((coins_wallet() ->> 'error') = 'test_student' and (coins_spend(10, 'testkid-spend-1', 'x') ->> 'error') = 'test_student' and (coins_refund('testkid-spend-1') ->> 'error') = 'test_student', 'a test student is told to use their on-device coins');
  reset role; perform t_be(null); update profiles set is_test = false where id = aisha;

  raise notice 'spending';
  perform ll_mint(aisha, 'practice', 100, 'seed-spend');
  b0 := ll_balance(aisha);
  perform t_be(kid); set local role authenticated;
  j := coins_spend(30, 'spend-a-0001', 'Date palm');
  perform t_assert((j ->> 'ok')::boolean and (j ->> 'balance')::int = b0 - 30, 'a child can spend what they have');
  perform t_assert((coins_spend(30, 'spend-a-0001', 'Date palm') ->> 'already')::boolean and (coins_spend(30, 'spend-a-0001', 'Date palm') ->> 'balance')::int = b0 - 30, 'repeating the same reference does not charge again');
  j := coins_spend(b0 + 1, 'spend-b-0001', 'too much');
  perform t_assert((j ->> 'error') = 'not_enough' and (j ->> 'balance')::int = b0 - 30, 'spending more than they have is refused, and tells them the balance');
  reset role;
  perform t_assert((select count(*) from points where source_ref = 'spend-b-0001') = 0, 'and wrote nothing');
  perform t_be(kid); set local role authenticated;
  perform t_assert((coins_spend(0, 'spend-c-0001', 'x') ->> 'error') = 'bad_amount' and (coins_spend(-5, 'spend-c-0002', 'x') ->> 'error') = 'bad_amount'
                   and (coins_spend(null, 'spend-c-0003', 'x') ->> 'error') = 'bad_amount' and (coins_spend(1000001, 'spend-c-0004', 'x') ->> 'error') = 'bad_amount', 'zero, negative, null and enormous spends are refused (a negative spend would be a mint)');
  perform t_assert((coins_spend(1, 'short', 'x') ->> 'error') = 'bad_ref' and (coins_spend(1, null, 'x') ->> 'error') = 'bad_ref' and (coins_spend(1, 'has spaces in it!', 'x') ->> 'error') = 'bad_ref'
                   and (coins_spend(1, repeat('a', 65), 'x') ->> 'error') = 'bad_ref', 'a missing, short, odd or long reference is refused');
  j := coins_spend(5, 'spend-d-0001', 'a link http://evil.example/x here and ' || repeat('y', 100));
  reset role;
  perform t_assert((select reason from points where source_ref = 'spend-d-0001') not like '%evil.example%' and length((select reason from points where source_ref = 'spend-d-0001')) <= 60, 'the note is cleaned and cut to 60');
  perform t_assert(ll_balance(aisha) >= 0, 'the balance is never negative');
  b1 := ll_balance(aisha);
  perform t_be(kid); set local role authenticated;
  j := coins_spend(b1, 'spend-e-0001', 'everything');
  reset role;
  perform t_assert((j ->> 'balance')::int = 0 and ll_balance(aisha) = 0, 'a child can spend down to exactly nothing');
  perform t_be(kid); set local role authenticated;
  perform t_assert((coins_spend(1, 'spend-f-0001', 'x') ->> 'error') = 'not_enough', 'and no further');
  reset role;
  perform t_be(mauluda_uid); set local role authenticated;
  perform t_assert((coins_spend(1, 'spend-g-0001', 'x') ->> 'error') = 'not_allowed', 'an adult cannot spend a child''s coins');
  reset role; perform t_be(null); set local role anon;
  perform t_assert(t_say($q$select coins_spend(1, 'spend-h-0001', 'x')$q$) like '42501%', 'nor a visitor');
  reset role;
  b1 := ll_balance(hamza);                                              -- (joining a class pays a welcome now, so a classmate may have coins)
  perform t_be(kid2); set local role authenticated;
  j := coins_spend(b1 + 1, 'spend-a-0001', 'x');
  reset role;
  perform t_assert((j ->> 'error') = 'not_enough' and (j ->> 'balance')::int = b1, 'a classmate is not affected by a reference somebody else used: they are asked for the money like anyone');

  raise notice 'taking half back';
  delete from points where pupil_id = aisha and source in ('spend', 'refund'); perform ll_mint(aisha, 'practice', 500, 'seed-refund');
  b0 := ll_balance(aisha);
  perform t_be(kid); set local role authenticated;
  perform coins_spend(101, 'refund-a-0001', 'Fountain');
  j := coins_refund('refund-a-0001');
  reset role;
  perform t_assert((j ->> 'refunded')::int = 50 and ll_balance(aisha) = b0 - 101 + 50, 'selling gives back half of what was paid, rounded down (101 -> 50)');
  perform t_be(kid); set local role authenticated;
  j := coins_refund('refund-a-0001');
  reset role;
  perform t_assert((j ->> 'refunded')::int = 0 and (j ->> 'already')::boolean and ll_balance(aisha) = b0 - 101 + 50, 'and only once');
  perform t_be(kid); set local role authenticated;
  perform t_assert((coins_refund('refund-zzzzzzzz') ->> 'error') = 'no_such_spend', 'a reference that was never a spend refunds nothing');
  perform t_assert((coins_refund('refund:refund-a-0001') ->> 'error') = 'no_such_spend', 'a refund cannot itself be refunded');
  perform t_assert((coins_refund('x') ->> 'error') = 'bad_ref', 'a bad reference is refused');
  reset role;
  perform t_be(kid2); set local role authenticated;
  perform t_assert((coins_refund('refund-a-0001') ->> 'error') = 'no_such_spend', 'a classmate cannot claim half back for somebody else''s spend');
  reset role;
  perform t_be(kid); set local role authenticated;
  perform coins_spend(1, 'refund-b-0001', 'tiny');
  j := coins_refund('refund-b-0001');
  reset role;
  perform t_assert((j ->> 'refunded')::int = 0, 'a one-coin spend refunds nothing (half of one rounds to zero)');
  perform t_assert((select count(*) from points where source = 'refund' and amount <= 0) = 0, 'a refund is never zero or negative');

  raise notice 'no sequence of spends and refunds can ever increase a balance';
  delete from points where pupil_id = aisha and source in ('spend', 'refund'); perform ll_mint(aisha, 'practice', 1000, 'seed-loop');
  b0 := ll_balance(aisha); b1 := b0;
  perform t_be(kid); set local role authenticated;
  for i in 1 .. 40 loop
    ref := 'loop-spend-' || lpad(i::text, 4, '0');
    perform coins_spend(1 + (i * 7) % 40, ref, 'loop');
    if i % 2 = 0 then perform coins_refund(ref); perform coins_refund(ref); end if;
    if (coins_wallet() ->> 'balance')::int > b0 then perform t_assert(false, 'the balance went UP after spending and selling'); end if;
  end loop;
  reset role;
  perform t_assert(ll_balance(aisha) < b0 and ll_balance(aisha) >= 0, 'forty spends and twenty sales (each tried twice) left the child with LESS than they started with, never more');

  raise notice 'adults giving coins';
  delete from points where pupil_id in (aisha, hamza) and source in ('teacher_gift', 'parent_gift'); b0 := ll_balance(aisha);
  perform t_be(mauluda_uid); set local role authenticated;
  j := points_give(aisha, 20, 'lovely reading http://evil.example/x');
  reset role;
  perform t_assert((j ->> 'ok')::boolean and ll_balance(aisha) = b0 + 20, 'a teacher of the class gives a coin or twenty');
  select * into r from points where pupil_id = aisha and source = 'teacher_gift' order by id desc limit 1;
  perform t_assert(r.given_by = mauluda and r.reason not like '%evil.example%' and r.source_ref like 'gift:%', 'recorded as a teacher''s gift, with who gave it, the link removed');
  perform t_be(mauluda_uid); set local role authenticated;
  perform t_assert((points_give(aisha, 0, 'x') ->> 'error') = 'bad_amount' and (points_give(aisha, 101, 'x') ->> 'error') = 'bad_amount' and (points_give(aisha, -5, 'x') ->> 'error') = 'bad_amount' and (points_give(aisha, null, 'x') ->> 'error') = 'bad_amount', 'nought, over a hundred, negative and null are refused');
  perform t_assert((points_give(hamza, 10, 'x') ->> 'error') = 'not_allowed', 'a teacher cannot give to a child who is not in their class');
  reset role;
  perform t_be(abdur_uid); set local role authenticated;
  perform t_assert((points_give(aisha, 10, 'x') ->> 'error') = 'not_allowed', 'nor can a teacher of a different class');
  reset role;
  perform t_be(ab_uid); set local role authenticated;
  perform t_assert((points_give(aisha, 10, 'x') ->> 'error') = 'not_allowed', 'nor an admin at another school');
  reset role;
  perform t_be(yusuf_uid); set local role authenticated;
  perform t_assert((points_give(aisha, 10, 'from the office') ->> 'ok')::boolean, 'an admin of her school can');
  reset role;
  perform t_be(fatima_uid); set local role authenticated;
  perform t_assert((points_give(aisha, 10, 'for praying on time') ->> 'ok')::boolean and (points_give(hamza, 10, 'x') ->> 'error') = 'not_allowed', 'a parent can give their own child, not another');
  reset role;
  perform t_assert((select source from points where reason = 'for praying on time' order by id desc limit 1) = 'parent_gift', 'and it is recorded as a parent''s gift');
  perform t_be(kid); set local role authenticated;
  perform t_assert((points_give(aisha, 10, 'to myself') ->> 'error') = 'not_allowed', 'a child cannot give coins, not even to themselves');
  reset role;
  perform t_be(null); set local role anon;
  perform t_assert(t_say($q$select points_give(gen_random_uuid(), 10, 'x')$q$) like '42501%', 'a visitor cannot call it');
  reset role;
  perform t_be(null); update profiles set is_test = true where id = aisha; perform t_be(mauluda_uid); set local role authenticated;
  perform t_assert((points_give(aisha, 10, 'x') ->> 'error') = 'not_allowed', 'a test student cannot be given real coins');
  reset role; perform t_be(null); update profiles set is_test = false where id = aisha;
  delete from points where pupil_id = aisha and source in ('teacher_gift', 'parent_gift');
  perform t_be(mauluda_uid); set local role authenticated;
  for i in 1 .. 4 loop j := points_give(aisha, 50, 'gift ' || i); end loop;
  perform t_assert((j ->> 'ok')::boolean, 'four gifts of 50 are 200 to one child in a day');
  perform t_assert((points_give(aisha, 1, 'one more') ->> 'error') = 'daily_limit_child', 'the 201st coin to one child in a day is refused');
  reset role;
  delete from points where pupil_id = aisha and source = 'teacher_gift';
  perform ll_mint(hamza, 'teacher_gift', 1, 'noop');   -- (a real pupil in the school, for the next test's headroom)
  delete from points where source_ref = 'noop';
  insert into points (pupil_id, source, amount, given_by, source_ref) select aisha, 'teacher_gift', 100, mauluda, 'bulk-' || g from generate_series(1, 9) g;
  perform t_be(mauluda_uid); set local role authenticated;
  perform t_assert((points_give(hamza, 100, 'x') ->> 'error') = 'not_allowed', '(setup: hamza is not mauluda''s)');
  reset role;
  delete from points where source_ref like 'bulk-%';
  insert into points (pupil_id, source, amount, given_by, source_ref) select aisha, 'teacher_gift', 100, mauluda, 'bulk-' || g from generate_series(1, 10) g;
  perform t_be(mauluda_uid); set local role authenticated;
  perform t_assert((points_give(aisha, 1, 'x') ->> 'error') in ('daily_limit_child', 'daily_limit_total'), 'a giver who has already given 1,000 today is stopped');
  reset role;
  delete from points where source_ref like 'bulk-%';

  raise notice 'the garden''s own "spent" can only go up';
  perform t_be(kid); set local role authenticated;
  perform t_assert(t_say(format($q$insert into garden (pupil_id, state, spent) values (%L, '{}', 50) on conflict (pupil_id) do update set spent = 50$q$, aisha)) = 'ok', 'a child can raise it');
  perform t_assert(t_say(format($q$update garden set spent = 0 where pupil_id = %L$q$, aisha)) = 'ok', 'lowering it does not error (the app must keep syncing)');
  reset role;
  perform t_assert((select spent from garden where pupil_id = aisha) = 50, 'but it stays where it was');
  update garden set spent = 10 where pupil_id = aisha;
  perform t_assert((select spent from garden where pupil_id = aisha) = 10, 'the owner can still correct it');
  perform t_be(mauluda_uid); set local role authenticated;
  perform t_assert(points_balance(aisha) = (select ll_real from (select 1) x, lateral (select 0 as ll_real) y) + (select sum(amount)::int from points where pupil_id = aisha), 'points_balance reads the ledger alone (the garden''s "spent" of 10 is ignored)');
  reset role;

  raise notice 'the report counts coins EARNED';
  delete from points where pupil_id = aisha and (at at time zone 'Europe/London')::date = current_date;      -- (including a welcome that an earlier test's re-enrolment paid today)
  perform ll_mint(aisha, 'practice', 40, 'rep-1');
  perform t_be(kid); set local role authenticated; perform coins_spend(25, 'rep-spend-0001', 'x'); perform coins_refund('rep-spend-0001'); reset role;
  perform t_be(mauluda_uid); set local role authenticated;
  j := pupil_report(aisha, current_date, current_date);
  reset role;
  perform t_assert((j #>> '{coins,total}')::int = 40 and (j #>> '{coins,by_source,spend}') is null and (j #>> '{coins,by_source,refund}') is null, 'a report shows what was earned (40), not what was spent or given back');

  raise notice 'the plumbing';
  perform t_assert(not has_function_privilege('authenticated', 'll_mint(uuid,point_source,int,text,text,uuid)', 'execute') and not has_function_privilege('anon', 'll_mint(uuid,point_source,int,text,text,uuid)', 'execute'), 'll_mint is callable by nobody but the owner');
  perform t_assert(not has_function_privilege('authenticated', 'll_balance(uuid)', 'execute') and not has_function_privilege('authenticated', 'll_lock_pupil(uuid)', 'execute') and not has_function_privilege('authenticated', 'll_real_pupil(uuid)', 'execute'), 'the helpers are shut');
  perform t_assert(has_function_privilege('authenticated', 'coins_spend(int,text,text)', 'execute') and not has_function_privilege('anon', 'coins_spend(int,text,text)', 'execute') and not has_function_privilege('anon', 'points_give(uuid,int,text)', 'execute'), 'the public functions are for signed-in people only');
  perform t_assert((select count(*) from pg_proc where proname in ('ll_mint', 'coins_wallet', 'coins_spend', 'coins_refund', 'points_give', 'll_balance', 'll_real_pupil', 'll_lock_pupil', 'points_balance') and prosecdef and proconfig::text like '%search_path=public, pg_temp%') = 9, 'all nine are security definer with a pinned search_path');
  perform t_assert(not exists (select 1 from information_schema.role_table_grants where table_name in ('reward_rates') and grantee in ('anon', 'authenticated')), 'the reward table is closed to everyone signed in or out');
  perform t_assert((select count(*) from reward_rates where key in ('welcome', 'attendance_present', 'attendance_on_time', 'attendance_camera', 'dhikr_set', 'reading_session', 'practice_session', 'activity_day_cap')) = 8, 'the amounts are in one table');
  perform t_assert(not has_table_privilege('authenticated', 'points', 'insert') and not has_table_privilege('authenticated', 'points', 'update') and not has_table_privilege('authenticated', 'points', 'delete') and has_table_privilege('authenticated', 'points', 'select'), 'signed-in people can read points and nothing else');

  perform t_be(null);
  update profiles set auth_uid = null where id in (aisha, hamza);
  delete from auth.users where id in (kid, kid2);
  delete from points where pupil_id in (aisha, hamza, bilal) and (source_ref is not null);
  update garden set spent = 0 where pupil_id = aisha;
end $$;
