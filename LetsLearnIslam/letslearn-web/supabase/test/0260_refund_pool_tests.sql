-- ============================================================
-- Selling for half, in total (0026). Runs after 0250.
-- ============================================================
do $$
declare aisha uuid; hamza uuid; mauluda_uid uuid; kid uuid; kid2 uuid; j jsonb; i int; sp int; rf int; r text;
begin
  select id into aisha from profiles where full_name = 'Aisha Khan';
  select id into hamza from profiles where full_name = 'Hamza Malik';
  select auth_uid into mauluda_uid from profiles where full_name = 'Mauluda Begum';
  insert into auth.users (is_anonymous) values (true) returning id into kid;
  insert into auth.users (is_anonymous) values (true) returning id into kid2;
  update profiles set auth_uid = kid where id = aisha; update profiles set auth_uid = kid2 where id = hamza;
  delete from points where pupil_id in (aisha, hamza);
  perform ll_mint(aisha, 'practice', 10000, 'pool-seed');

  raise notice 'refunding an amount';
  perform t_be(kid); set local role authenticated;
  perform coins_spend(100, 'pool-spend-0001', 'a');
  j := coins_refund_pool(50, 'pool-req-00001');
  perform t_assert((j ->> 'refunded')::int = 50, 'half of 100 can come back');
  j := coins_refund_pool(50, 'pool-req-00002');
  perform t_assert((j ->> 'refunded')::int = 0, 'but not another half: the total can never pass half of what was spent');
  j := coins_refund_pool(50, 'pool-req-00001');
  perform t_assert((j ->> 'refunded')::int = 0 and (j ->> 'already')::boolean, 'the same request twice pays once');
  perform coins_spend(30, 'pool-spend-0002', 'b');
  j := coins_refund_pool(1000, 'pool-req-00003');
  perform t_assert((j ->> 'refunded')::int = 15, 'asking for more than allowed pays only what is allowed (half of the new 30)');
  reset role;
  select -sum(amount) into sp from points where pupil_id = aisha and source = 'spend'; select sum(amount) into rf from points where pupil_id = aisha and source = 'refund';
  perform t_assert(rf = 65 and rf <= sp / 2, 'refunds 65 against spends 130: exactly half');

  raise notice 'the two ways together';
  perform t_be(kid); set local role authenticated;
  j := coins_refund('pool-spend-0001');
  perform t_assert((j ->> 'refunded')::int = 0, 'the per-spend refund cannot pay again what the pool already paid');
  j := coins_refund('pool-spend-0002');
  perform t_assert((j ->> 'refunded')::int = 0, 'nor the second spend''s half');
  perform coins_spend(200, 'pool-spend-0003', 'c');
  j := coins_refund('pool-spend-0003');
  perform t_assert((j ->> 'refunded')::int = 100, 'a new spend can be refunded by reference: half of 200');
  j := coins_refund_pool(500, 'pool-req-00004');
  perform t_assert((j ->> 'refunded')::int = 0, 'and then the pool has nothing left to give');
  reset role;
  select -sum(amount) into sp from points where pupil_id = aisha and source = 'spend'; select sum(amount) into rf from points where pupil_id = aisha and source = 'refund';
  perform t_assert(rf <= sp / 2, 'in total never more than half of everything spent (' || rf || ' of ' || sp || ')');

  raise notice 'no order of buying and selling ever gains';
  delete from points where pupil_id = aisha; perform ll_mint(aisha, 'practice', 5000, 'pool-seed-2');
  perform t_be(kid); set local role authenticated;
  for i in 1 .. 60 loop
    perform coins_spend(1 + (i * 13) % 90, 'loop-sp-' || lpad(i::text, 4, '0'), 'x');
    perform coins_refund_pool(1 + (i * 29) % 120, 'loop-rf-' || lpad(i::text, 4, '0'));
    if i % 3 = 0 then perform coins_refund('loop-sp-' || lpad(i::text, 4, '0')); end if;
  end loop;
  reset role;
  select -sum(amount) into sp from points where pupil_id = aisha and source = 'spend'; select sum(amount) into rf from points where pupil_id = aisha and source = 'refund';
  perform t_assert(rf <= sp / 2 and ll_balance(aisha) = 5000 - sp + rf and ll_balance(aisha) < 5000, 'after sixty rounds of mixed buying and selling the child is poorer, and refunds are at most half of spends (' || rf || ' <= ' || sp || '/2)');

  raise notice 'who may';
  perform t_be(kid); set local role authenticated;
  perform t_assert((coins_refund_pool(0, 'pool-bad-00001') ->> 'error') = 'bad_amount' and (coins_refund_pool(-5, 'pool-bad-00002') ->> 'error') = 'bad_amount'
                   and (coins_refund_pool(null, 'pool-bad-00003') ->> 'error') = 'bad_amount' and (coins_refund_pool(1000001, 'pool-bad-00004') ->> 'error') = 'bad_amount', 'zero, negative, null and enormous are refused');
  perform t_assert((coins_refund_pool(5, 'x') ->> 'error') = 'bad_ref' and (coins_refund_pool(5, null) ->> 'error') = 'bad_ref', 'a bad reference is refused');
  reset role;
  perform t_be(kid2); set local role authenticated;
  perform t_assert((coins_refund_pool(50, 'pool-hamza-0001') ->> 'refunded')::int = 0, 'a child who has spent nothing is refunded nothing (their pool is their own)');
  reset role;
  perform t_be(mauluda_uid); set local role authenticated;
  perform t_assert((coins_refund_pool(5, 'pool-adult-0001') ->> 'error') = 'not_allowed', 'an adult cannot');
  reset role; perform t_be(null); set local role anon;
  perform t_assert(t_say($q$select coins_refund_pool(5, 'pool-anon-00001')$q$) like '42501%', 'nor a visitor');
  reset role;
  perform t_be(null); update profiles set is_test = true where id = aisha; perform t_be(kid); set local role authenticated;
  perform t_assert((coins_refund_pool(5, 'pool-test-00001') ->> 'error') = 'test_student', 'a test student is told to use their device coins');
  reset role; perform t_be(null); update profiles set is_test = false where id = aisha;
  perform t_assert(not has_function_privilege('authenticated', 'll_refund_room(uuid)', 'execute') and has_function_privilege('authenticated', 'coins_refund_pool(int,text)', 'execute') and not has_function_privilege('anon', 'coins_refund_pool(int,text)', 'execute'), 'the helper is shut and the function is for signed-in people only');

  perform t_be(null);
  update profiles set auth_uid = null where id in (aisha, hamza);
  delete from auth.users where id in (kid, kid2);
  delete from points where pupil_id in (aisha, hamza);
end $$;
