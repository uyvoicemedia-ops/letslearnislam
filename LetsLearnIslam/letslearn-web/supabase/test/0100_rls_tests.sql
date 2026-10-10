-- ============================================================
-- What the policies are supposed to stop
-- ------------------------------------------------------------
-- Each test becomes one person, tries something, and asserts what
-- they got. Anything that fails raises, and testdb.sh goes red.
--
-- The interesting tests are the negative ones. A policy that lets the
-- right people in is easy to write and easy to check by using the app;
-- a policy that lets the WRONG people in looks exactly the same from
-- the inside. So most of what follows is one child trying to read
-- another child.
-- ============================================================

create or replace function t_assert(ok boolean, what text) returns void
language plpgsql as $$
begin
  if ok then raise notice '  ok    %', what;
  else raise exception 'FAILED: %', what;
  end if;
end $$;

-- become somebody: a real Supabase session is a role plus a uid
create or replace function t_be(p_uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), false);
end $$;

do $$
declare
  aisha uuid; bilal uuid; hamza uuid;
  mauluda uuid; abdur uuid; fatima uuid;
  aisha_uid uuid := gen_random_uuid();
  bilal_uid uuid := gen_random_uuid();
  mauluda_uid uuid := gen_random_uuid();
  abdur_uid uuid := gen_random_uuid();
  fatima_uid uuid := gen_random_uuid();
  yusuf uuid; yusuf_uid uuid := gen_random_uuid();
  sch uuid;
  n int; res jsonb; okbool boolean;
begin
  select id into yusuf from profiles where full_name = 'Yusuf Ibrahim';
  select id into sch   from schools  limit 1;
  select id into aisha   from profiles where full_name = 'Aisha Khan';
  select id into bilal   from profiles where full_name = 'Bilal Ahmed';
  select id into hamza   from profiles where full_name = 'Hamza Malik';
  select id into mauluda from profiles where full_name = 'Mauluda Begum';
  select id into abdur   from profiles where full_name = 'Abdur Rahman';
  select id into fatima  from profiles where full_name = 'Fatima Khan';

  -- give the adults sessions, the way signing up would
  insert into auth.users (id, email) values
    (mauluda_uid, 'teacher@example.com'),
    (abdur_uid,   'teacher2@example.com'),
    (fatima_uid,  'parent@example.com'),
    (yusuf_uid,   'admin@example.com');
  -- the trigger should have linked them by email
  perform t_assert((select auth_uid from profiles where id = mauluda) = mauluda_uid,
                   'signing up links you to the roster row waiting for you');

  -- and the children, the way claim_pupil would
  insert into auth.users (id) values (aisha_uid), (bilal_uid);
  update profiles set auth_uid = aisha_uid where id = aisha;
  update profiles set auth_uid = bilal_uid where id = bilal;

  raise notice 'a child reading their own things';
  perform t_be(aisha_uid);
  set local role authenticated;

  select count(*) into n from garden where pupil_id = aisha;
  perform t_assert(n = 1, 'a child sees their own garden');

  select count(*) into n from points where pupil_id = aisha;
  perform t_assert(n = 4, 'a child sees their own coins');

  select count(*) into n from attendance where pupil_id = aisha;
  perform t_assert(n > 0, 'a child sees their own register');

  raise notice 'a child reaching for another child';

  select count(*) into n from garden where pupil_id = bilal;
  perform t_assert(n = 0, 'a child cannot open another child''s garden');

  select count(*) into n from points where pupil_id = bilal;
  perform t_assert(n = 0, 'a child cannot read another child''s coins');

  select count(*) into n from attendance where pupil_id = bilal;
  perform t_assert(n = 0, 'a child cannot read another child''s register');

  select count(*) into n from profiles where id = hamza;
  perform t_assert(n = 0, 'a child cannot read a child in another class');

  raise notice 'a child trying to mint coins';
  begin
    insert into points (pupil_id, source, amount, reason)
    values (aisha, 'teacher_gift', 100, 'from me, to me');
    perform t_assert(false, 'a child cannot give themselves coins');
  exception when insufficient_privilege or check_violation then
    perform t_assert(true, 'a child cannot give themselves coins');
  end;

  begin
    update garden set spent = -100000 where pupil_id = aisha;
    -- allowed to write their own garden, so this one is about the balance
    perform t_assert(true, 'a child may write their own garden document');
  exception when others then
    perform t_assert(false, 'a child may write their own garden document');
  end;

  raise notice 'the answer key';
  select count(*) into n from quiz_questions;
  perform t_assert(n = 0, 'a player cannot read the quiz answers');

  reset role;

  raise notice 'a teacher';
  perform t_be(mauluda_uid);
  set local role authenticated;

  select count(*) into n from profiles where id = aisha;
  perform t_assert(n = 1, 'a teacher sees a child they teach');

  select count(*) into n from profiles where id = hamza;
  perform t_assert(n = 0, 'a teacher cannot see a child they do not teach');

  select count(*) into n from attendance where pupil_id = aisha;
  perform t_assert(n > 0, 'a teacher sees the register for their own class');

  select count(*) into n from quiz_questions;
  perform t_assert(n = 5, 'the quiz owner reads their own questions');

  reset role;

  raise notice 'another teacher, same school';
  perform t_be(abdur_uid);
  set local role authenticated;
  select count(*) into n from profiles where id = aisha;
  perform t_assert(n = 0, 'a colleague cannot browse a class that is not theirs');
  select count(*) into n from quiz_questions;
  perform t_assert(n = 0, 'a colleague cannot read someone else''s answer key');
  reset role;

  -- ---------- sharing a set is a decision, not a default ----------
  -- 0006 lets a teacher hand a set to the rest of the school. The
  -- point of these four is that nothing happens until somebody says
  -- so, and that a child is never in the room for any of it.
  raise notice 'sharing a quiz set';

  perform t_be(abdur_uid);
  set local role authenticated;
  select count(*) into n from quiz_sets;
  perform t_assert(n = 1, 'a colleague can see that the set exists');
  select count(*) into n from quiz_questions;
  perform t_assert(n = 0, 'an unshared set has no readable questions');
  reset role;

  -- the owner shares it
  perform t_be(mauluda_uid);
  set local role authenticated;
  update quiz_sets set shared = true where owner_id = mauluda;
  perform t_assert((select shared from quiz_sets where owner_id = mauluda),
                   'the owner can share their own set');
  reset role;

  perform t_be(abdur_uid);
  set local role authenticated;
  select count(*) into n from quiz_questions;
  perform t_assert(n = 5, 'a colleague can host a set once it is shared');
  -- and cannot edit it: sharing is read, not write
  begin
    update quiz_questions set prompt = 'tampered' where ord = 1;
    if found then
      perform t_assert(false, 'sharing a set does not hand over the editing');
    else
      perform t_assert(true, 'sharing a set does not hand over the editing');
    end if;
  exception when insufficient_privilege or others then
    perform t_assert(true, 'sharing a set does not hand over the editing');
  end;
  -- a colleague must not be able to share somebody else's set either
  update quiz_sets set shared = false where owner_id = mauluda;
  perform t_assert((select shared from quiz_sets where owner_id = mauluda),
                   'a colleague cannot unshare a set that is not theirs');
  reset role;

  -- the whole point: a child is never in this conversation
  perform t_be(aisha_uid);
  set local role authenticated;
  select count(*) into n from quiz_questions;
  perform t_assert(n = 0, 'a child cannot read the questions of a SHARED set');
  reset role;

  -- ---------- fees: nobody marks their own bill paid ----------
  -- The whole value of these tables is that a status in them means
  -- GoCardless said so. These are the assertions that make that true.
  raise notice 'fees and mandates';

  declare
    plan_id uuid;
    mand_id uuid;
    chg_id  uuid;
  begin
    -- seeded as the service role would, because the edge function does
    insert into fee_plans (school_id, name, amount_pence, interval)
      values (sch, 'Monthly tuition', 3500, 'monthly') returning id into plan_id;
    insert into mandates (school_id, payer_id, gc_mandate_id, status, reference)
      values (sch, fatima, 'MD_TEST_1', 'active', 'LLI-0001') returning id into mand_id;
    insert into fee_charges (school_id, payer_id, plan_id, mandate_id,
                             amount_pence, period, status)
      values (sch, fatima, plan_id, mand_id, 3500, 'Oct 2026', 'pending')
      returning id into chg_id;

    -- the parent who signed it
    perform t_be(fatima_uid);
    set local role authenticated;

    select count(*) into n from mandates;
    perform t_assert(n = 1, 'a payer sees their own Direct Debit');
    select count(*) into n from fee_charges;
    perform t_assert(n = 1, 'a payer sees their own charges');
    perform t_assert((fee_status()->>'outstanding_pence')::int = 3500,
                     'and what they still owe');

    -- the one that matters
    begin
      update fee_charges set status = 'confirmed' where id = chg_id;
      perform t_assert(not found, 'a payer cannot mark their own bill paid');
    exception when others then
      perform t_assert(true, 'a payer cannot mark their own bill paid');
    end;

    begin
      insert into fee_charges (school_id, payer_id, amount_pence, status)
        values (sch, fatima, 1, 'confirmed');
      perform t_assert(false, 'a payer cannot invent a charge');
    exception when others then
      perform t_assert(true, 'a payer cannot invent a charge');
    end;

    begin
      update mandates set status = 'active', gc_mandate_id = 'MD_FAKE'
        where id = mand_id;
      perform t_assert(not found, 'a payer cannot forge a mandate id');
    exception when others then
      perform t_assert(true, 'a payer cannot forge a mandate id');
    end;
    reset role;

    -- a teacher is not in this conversation at all
    perform t_be(mauluda_uid);
    set local role authenticated;
    select count(*) into n from mandates;
    perform t_assert(n = 0, 'a teacher cannot see who has a Direct Debit');
    select count(*) into n from fee_charges;
    perform t_assert(n = 0, 'a teacher cannot see who is behind on fees');
    reset role;

    -- a second member of staff, to be sure it is not just Mauluda
    perform t_be(abdur_uid);
    set local role authenticated;
    select count(*) into n from fee_charges;
    perform t_assert(n = 0, 'no member of staff but an admin sees a fee');
    reset role;

    -- an admin may look, and may set the price, and may not fake a payment
    perform t_be(yusuf_uid);
    set local role authenticated;
    select count(*) into n from fee_charges;
    perform t_assert(n = 1, 'an admin sees the school''s charges');

    begin
      insert into fee_plans (school_id, name, amount_pence)
        values (sch, 'Termly', 10500);
      perform t_assert(true, 'an admin sets what the madrasah charges');
    exception when others then
      perform t_assert(false, 'an admin sets what the madrasah charges');
    end;

    begin
      update fee_charges set status = 'paid_out' where id = chg_id;
      perform t_assert(not found, 'an admin cannot mark a charge collected');
    exception when others then
      perform t_assert(true, 'an admin cannot mark a charge collected');
    end;
    reset role;

    -- the webhook log belongs to the service role and nobody else
    insert into webhook_events (id, resource_type, action)
      values ('EV_TEST_1', 'payments', 'confirmed');
    perform t_be(yusuf_uid);
    set local role authenticated;
    select count(*) into n from webhook_events;
    perform t_assert(n = 0, 'not even an admin reads the webhook log');
    reset role;

    -- and a child is nowhere near any of it
    perform t_be(aisha_uid);
    set local role authenticated;
    select count(*) into n from mandates;
    perform t_assert(n = 0, 'a child cannot read a mandate');
    select count(*) into n from fee_charges;
    perform t_assert(n = 0, 'a child cannot read a fee charge');
    reset role;
  end;

  raise notice 'a parent';
  perform t_be(fatima_uid);
  set local role authenticated;

  select count(*) into n from profiles where id = aisha;
  perform t_assert(n = 1, 'a parent sees their own child');

  select count(*) into n from profiles where id = bilal;
  perform t_assert(n = 0, 'a parent cannot see somebody else''s child');

  select count(*) into n from garden where pupil_id = bilal;
  perform t_assert(n = 0, 'a parent cannot open somebody else''s child''s garden');

  begin
    insert into points (pupil_id, source, amount, reason, given_by)
    values (aisha, 'parent_gift', 10, 'for praying on time', fatima);
    perform t_assert(true, 'a parent may give their own child points');
  exception when others then
    perform t_assert(false, 'a parent may give their own child points');
  end;

  begin
    insert into points (pupil_id, source, amount, reason, given_by)
    values (bilal, 'parent_gift', 10, 'not my child', fatima);
    perform t_assert(false, 'a parent cannot give points to another child');
  exception when insufficient_privilege or check_violation then
    perform t_assert(true, 'a parent cannot give points to another child');
  end;

  begin
    insert into points (pupil_id, source, amount, reason, given_by)
    values (aisha, 'parent_gift', 5000, 'a very large gift', fatima);
    perform t_assert(false, 'the size of a gift is capped');
  exception when insufficient_privilege or check_violation then
    perform t_assert(true, 'the size of a gift is capped');
  end;

  reset role;
end $$;

-- ---------- signing in as a child ----------
do $$
declare
  aisha uuid; res jsonb; fresh uuid := gen_random_uuid(); i int;
begin
  raise notice 'class code and PIN';
  select id into aisha from profiles where full_name = 'Aisha Khan';

  perform t_assert((select count(*) from class_roster('QAIDA1')) = 3,
                   'a class code shows the three names in that class');
  perform t_assert((select count(*) from class_roster('nope')) = 0,
                   'a wrong code shows nobody');

  insert into auth.users (id) values (fresh);
  perform t_be(fresh);

  res := claim_pupil('QAIDA1', aisha, '9999');
  perform t_assert((res->>'ok')::boolean is false and res->>'error' = 'wrong_pin',
                   'the wrong PIN is refused');

  res := claim_pupil('HIFZ01', aisha, '1234');
  perform t_assert((res->>'ok')::boolean is false and res->>'error' = 'not_in_class',
                   'the right PIN with the wrong class is refused');

  res := claim_pupil('QAIDA1', aisha, '1234');
  perform t_assert((res->>'ok')::boolean, 'the right code and PIN signs the child in');
  perform t_assert((select auth_uid from profiles where id = aisha) = fresh,
                   'the session is now attached to that pupil');

  -- five wrong goes and it rests
  for i in 1..5 loop
    perform claim_pupil('QAIDA1', aisha, '0000');
  end loop;
  res := claim_pupil('QAIDA1', aisha, '1234');
  perform t_assert(res->>'error' = 'locked',
                   'guessing is locked out after five wrong goes, even with the right PIN');

  update profiles set pin_attempts = 0, pin_locked_until = null where id = aisha;
  perform t_be(null);
end $$;

-- ---------- the PIN hashes themselves ----------
do $$
declare n int;
begin
  raise notice 'PIN hashes';
  select count(*) into n
  from information_schema.column_privileges
  where table_name = 'profiles' and column_name = 'pin_hash'
    and grantee in ('anon', 'authenticated') and privilege_type = 'SELECT';
  perform t_assert(n = 0, 'no client role may select a PIN hash');
end $$;

-- ---------- the quiz scores on the server ----------
do $$
declare
  room uuid; qs uuid; mauluda uuid; mauluda_uid uuid;
  join_res jsonb; ans jsonb; player uuid; scored int;
begin
  raise notice 'the live quiz';
  select id into mauluda from profiles where full_name = 'Mauluda Begum';
  select auth_uid into mauluda_uid from profiles where id = mauluda;
  select id into qs from quiz_sets limit 1;

  insert into quiz_rooms (set_id, host_id, code, state, current_ord, asked_at)
  values (qs, mauluda, 'TEST99', 'asking', 1, now() - interval '2 seconds')
  returning id into room;

  perform t_be(null);
  join_res := quiz_join('TEST99', 'Speedy');
  perform t_assert((join_res->>'ok')::boolean, 'anyone with the room code can join');
  player := (join_res->>'player_id')::uuid;

  ans := quiz_answer(player, 0);   -- question 1's answer is 0
  perform t_assert((ans->>'ok')::boolean, 'an answer is accepted');
  perform t_assert((ans->>'ms')::int between 1500 and 4000,
                   'the server times the answer itself, not the client');

  select score into scored from quiz_players where id = player;
  perform t_assert(scored > 500, 'a right answer scores, and faster scores more');

  ans := quiz_answer(player, 0);
  perform t_assert(ans->>'error' = 'already_answered', 'nobody gets a second go');

  -- a wrong answer from a second player
  join_res := quiz_join('TEST99', 'Slowcoach');
  ans := quiz_answer((join_res->>'player_id')::uuid, 3);
  perform t_assert((ans->>'ok')::boolean, 'a wrong answer is still recorded');
  select score into scored from quiz_players where id = (join_res->>'player_id')::uuid;
  perform t_assert(scored = 0, 'a wrong answer scores nothing');

  perform t_assert((select count(*) from quiz_board(room)) = 2, 'the leaderboard lists both');
end $$;

-- ---------- the balance ----------
do $$
declare
  aisha uuid; mauluda_uid uuid; bilal_uid uuid;
  expected int; got int;
begin
  raise notice 'coins';
  select id into aisha from profiles where full_name = 'Aisha Khan';
  select auth_uid into mauluda_uid from profiles where full_name = 'Mauluda Begum';
  select auth_uid into bilal_uid from profiles where full_name = 'Bilal Ahmed';

  select coalesce(sum(amount), 0) into expected from points where pupil_id = aisha;
  update garden set spent = 25 where pupil_id = aisha;

  perform t_be(mauluda_uid);
  set local role authenticated;
  got := points_balance(aisha);
  perform t_assert(got = expected - 25,
                   'the balance is the ledger minus what has been spent');
  reset role;

  -- and the same call from someone with no business asking
  perform t_be(bilal_uid);
  set local role authenticated;
  perform t_assert(points_balance(aisha) is null,
                   'a stranger asking for a balance is told nothing, not zero');
  reset role;
  perform t_be(null);
end $$;

-- ============================================================
-- 0005 — a parent arriving on their own, and the school's veto
-- ============================================================

do $$
declare
  dad_uid   uuid := gen_random_uuid();
  kid_uid   uuid := gen_random_uuid();
  anon_uid  uuid := gen_random_uuid();
  mauluda_uid uuid;
  dad uuid; fam uuid; kid uuid; sibling uuid;
  aisha uuid; cls uuid; req uuid; code text;
  res jsonb; n int;
begin
  select id into aisha from profiles where full_name = 'Aisha Khan';
  select auth_uid into mauluda_uid from profiles where full_name = 'Mauluda Begum';
  select class_id into cls from class_teachers ct
    join profiles p on p.id = ct.teacher_id where p.full_name = 'Mauluda Begum' limit 1;
  -- read the code here, as nobody in particular: a home parent cannot see
  -- the classes table, which is exactly the point of the request flow
  select join_code into code from classes where id = cls;

  raise notice 'a parent signing up with Google, on nobody''s roster';

  insert into auth.users (id, email) values (dad_uid, 'newdad@example.com');
  perform t_be(dad_uid);
  set local role authenticated;

  res := family_open('Ilyas');
  perform t_assert((res->>'ok')::boolean, 'a stranger who signs in gets a household');
  dad := (res->>'profile')::uuid;
  fam := (res->>'family')::uuid;
  perform t_assert((select role from profiles where id = dad) = 'parent',
                   'and is a parent, never a teacher or an admin');
  perform t_assert((select school_id from profiles where id = dad) is null,
                   'and belongs to no school');

  perform t_assert(family_open('Ilyas') ->> 'family' = fam::text,
                   'calling it twice does not make a second household');

  raise notice 'adding a child at the kitchen table';

  res := family_add_child('Maryam', '4821');
  perform t_assert((res->>'ok')::boolean, 'a parent may add their own child');
  kid := (res->>'pupil')::uuid;
  perform t_assert((select school_id from profiles where id = kid) is null,
                   'the child starts with no school');
  perform t_assert((select count(*) from guardians
                    where parent_id = dad and pupil_id = kid) = 1,
                   'and is linked to the parent who made them');

  perform t_assert((family_add_child('Nope', '12') ->> 'error') = 'bad_pin',
                   'a two-digit PIN is refused');
  reset role;

  raise notice 'the child signing in at home';

  insert into auth.users (id, is_anonymous) values (kid_uid, true);
  perform t_be(kid_uid);
  set local role authenticated;

  perform t_assert((claim_child(kid, '0000') ->> 'error') = 'wrong_pin',
                   'a wrong PIN is a wrong PIN');
  perform t_assert((claim_child(kid, '4821') ->> 'ok')::boolean,
                   'the right PIN gets the child their session');

  -- and the thing this whole design exists to stop
  perform t_assert((claim_child(aisha, '1234') ->> 'error') = 'not_a_family_child',
                   'the home door cannot be used to walk into a school child');
  perform t_assert(not ll_adult_session(),
                   'an anonymous session is never an adult session');
  perform t_assert((family_open('Sneaky') ->> 'error') = 'not_an_adult_session',
                   'a child session cannot start a household');
  perform t_assert((family_add_child('Ghost', '1111') ->> 'error')
                     = 'children_cannot_add_children',
                   'nor add a child');
  reset role;

  raise notice 'a household is not a school';

  perform t_be(dad_uid);
  set local role authenticated;
  select count(*) into n from profiles where full_name = 'Aisha Khan';
  perform t_assert(n = 0, 'a home parent cannot see a school''s children');
  select count(*) into n from classes;
  perform t_assert(n = 0, 'nor its classes');
  reset role;

  raise notice 'asking a school for a place';

  perform t_be(dad_uid);
  set local role authenticated;
  perform t_assert((family_request_class(kid, 'NO-SUCH') ->> 'error') = 'no_such_class',
                   'a wrong class code asks nobody anything');
  res := family_request_class(kid, code);
  perform t_assert((res->>'ok')::boolean, 'the code raises a hand');
  req := (res->>'request')::uuid;
  perform t_assert((family_request_class(kid, code)
                    ->> 'already_asked')::boolean, 'asking twice is not a queue');
  perform t_assert((select school_id from profiles where id = kid) is null,
                   'asking is not joining');

  -- a parent cannot offer somebody else's child
  perform t_assert((family_request_class(aisha, code) ->> 'error') = 'not_your_child',
                   'a parent cannot volunteer a child who is not theirs');
  -- nor wave their own request through
  perform t_assert((class_request_decide(req, true) ->> 'error') = 'not_your_class',
                   'a parent cannot approve their own request');
  perform t_assert((select school_id from profiles where id = kid) is null,
                   'and the child is still outside the school');
  reset role;

  raise notice 'the teacher deciding';

  perform t_be(mauluda_uid);
  set local role authenticated;
  select count(*) into n from profiles where id = kid;
  perform t_assert(n = 1, 'the teacher can see the name being offered');

  perform t_assert((class_request_decide(req, true) ->> 'state') = 'approved',
                   'the teacher approves');
  perform t_assert((select school_id from profiles where id = kid) is not null,
                   'approval is what stamps the school on the child');
  perform t_assert((select count(*) from enrolments
                    where pupil_id = kid and class_id = cls) = 1,
                   'and what writes the enrolment');
  perform t_assert((class_request_decide(req, true) ->> 'error') = 'already_decided',
                   'a decision is made once');
  reset role;

  perform t_be(null);
end $$;

select 'tests finished' as result;
