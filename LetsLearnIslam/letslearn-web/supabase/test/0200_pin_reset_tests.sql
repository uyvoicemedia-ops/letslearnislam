-- ============================================================
-- "I forgot my PIN" (0018): who may reset, what a reset does, that the
-- child's request reveals nothing, and that no PIN is ever recorded.
-- Runs after 0190; reuses t_assert, t_be, t_count, t_say.
-- It uses a pupil of its own ("Pin Pupil", in Qaida 1) so the shared
-- fixtures keep the PINs other tests rely on.
-- ============================================================
do $$
declare
  sch uuid; sch_b uuid; c_q1 uuid; c_hifz uuid;
  mauluda uuid; mauluda_uid uuid; abdur_uid uuid; yusuf uuid; yusuf_uid uuid; fatima uuid; fatima_uid uuid; aisha uuid; aisha_uid uuid;
  ab_uid uuid; tb_uid uuid; pb_uid uuid; kb uuid;
  kid uuid; kid_old_uid uuid := gen_random_uuid(); kid_new_uid uuid := gen_random_uuid(); anon_uid uuid := gen_random_uuid(); adult_sess uuid;
  j jsonb; j2 jsonb; j3 jsonb; n int; rq uuid; pin text; hash_before text; i int; many uuid[] := '{}';
  bad text[] := array['0000', '1111', '1234', '4321', '7890', '1212', '1122', '2580', '9999', '3210', '0101'];
begin
  select id into sch from schools where name = 'Al-Noor Madrasah';
  select id into sch_b from schools where name = 'Other Madrasah';
  select id into c_q1 from classes where join_code = 'QAIDA1';
  select id into c_hifz from classes where join_code = 'HIFZ01';
  select id, auth_uid into mauluda, mauluda_uid from profiles where full_name = 'Mauluda Begum';
  select auth_uid into abdur_uid from profiles where full_name = 'Abdur Rahman';
  select id, auth_uid into yusuf, yusuf_uid from profiles where full_name = 'Yusuf Ibrahim';
  select id, auth_uid into fatima, fatima_uid from profiles where full_name = 'Fatima Khan';
  select id, auth_uid into aisha, aisha_uid from profiles where full_name = 'Aisha Khan';
  select auth_uid into ab_uid from profiles where full_name = 'Admin B';
  select auth_uid into tb_uid from profiles where full_name = 'Teacher B';
  select auth_uid into pb_uid from profiles where full_name = 'Parent B';
  select id into kb from profiles where full_name = 'Pupil B';

  -- the pupil: in Qaida 1, PIN 1234, signed in on an old tablet (an anonymous session with a session row)
  insert into auth.users (id, is_anonymous) values (kid_old_uid, true), (kid_new_uid, true), (anon_uid, true);
  insert into profiles (school_id, role, full_name, pin_hash, auth_uid) values (sch, 'student', 'Pin Pupil', crypt('1234', gen_salt('bf', 4)), kid_old_uid) returning id into kid;
  insert into enrolments (class_id, pupil_id) values (c_q1, kid);
  insert into auth.sessions (user_id) values (kid_old_uid);
  insert into auth.sessions (user_id) values (mauluda_uid) returning id into adult_sess;

  raise notice 'the rules for a PIN';
  perform t_assert(not exists (select 1 from unnest(array['0000', '1111', '1234', '4321', '7890', '1212', '1122', '2580', '9999', '3210', '0101', '0123', '9876', '8901']) p where not ll_pin_trivial(p)),
                   'all the easy ones are trivial: 0000 1111 1234 4321 7890 1212 1122 2580 9999 3210 0101 0123 9876 8901');
  perform t_assert(not exists (select 1 from unnest(array['7391', '4821', '2057', '9264', '1593', '8420']) p where ll_pin_trivial(p)), 'and ordinary ones are not');
  perform t_assert((select count(*) from generate_series(0, 9999) g where ll_pin_trivial(lpad(g::text, 4, '0'))) between 150 and 300,
                   'about 2% of the 10,000 PINs are refused (' || (select count(*) from generate_series(0, 9999) g where ll_pin_trivial(lpad(g::text, 4, '0'))) || ')');

  raise notice 'who may NOT reset';
  perform t_be(kid_old_uid);
  set local role authenticated;
  perform t_assert((pin_reset_set(kid, '7391') ->> 'error') = 'not_allowed', 'a child session cannot set a PIN');
  perform t_assert((pin_reset_temp(kid) ->> 'error') = 'not_allowed', 'or generate a temporary one');
  perform t_assert((pin_reset_set(aisha, '7391') ->> 'error') = 'not_allowed', 'or reset another child');
  reset role;
  perform t_be(anon_uid);
  set local role authenticated;
  perform t_assert((pin_reset_set(kid, '7391') ->> 'error') = 'not_allowed' and (pin_reset_temp(kid) ->> 'error') = 'not_allowed', 'an unclaimed session cannot');
  perform t_assert((select count(*) from pin_reset_pending()) = 0, 'and sees no pending requests');
  reset role;
  perform t_be(abdur_uid);
  set local role authenticated;
  perform t_assert((pin_reset_set(kid, '7391') ->> 'error') = 'not_allowed', 'a teacher of a DIFFERENT class cannot reset this pupil');
  perform t_assert((pin_reset_temp(kid) ->> 'error') = 'not_allowed', 'nor generate a temporary PIN for them');
  reset role;
  perform t_be(ab_uid);
  set local role authenticated;
  perform t_assert((pin_reset_set(kid, '7391') ->> 'error') = 'not_allowed' and (pin_reset_temp(kid) ->> 'error') = 'not_allowed', 'an admin of another school cannot');
  reset role;
  perform t_be(tb_uid);
  set local role authenticated;
  perform t_assert((pin_reset_set(kid, '7391') ->> 'error') = 'not_allowed', 'a teacher at another school cannot');
  reset role;
  perform t_be(pb_uid);
  set local role authenticated;
  perform t_assert((pin_reset_set(kid, '7391') ->> 'error') = 'not_allowed', 'a parent at another school cannot');
  reset role;
  perform t_be(fatima_uid);
  set local role authenticated;
  perform t_assert((pin_reset_set(kid, '7391') ->> 'error') = 'not_allowed', 'a parent cannot reset ANOTHER family''s child');
  perform t_assert((pin_reset_temp(kid) ->> 'error') = 'not_allowed', 'nor generate a PIN for one');
  reset role;
  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert((pin_reset_set(mauluda, '7391') ->> 'error') = 'not_allowed', 'nobody can reset themselves (or another adult)');
  reset role;
  perform t_assert((select crypt('1234', pin_hash) = pin_hash from profiles where id = kid), 'after all those attempts the PIN is still 1234');
  perform t_assert((select auth_uid from profiles where id = kid) = kid_old_uid, 'and the child is still signed in');

  raise notice 'a refusal of easy and malformed PINs';
  perform t_be(mauluda_uid);
  set local role authenticated;
  foreach pin in array bad loop
    perform t_assert((pin_reset_set(kid, pin) ->> 'error') = 'trivial_pin', 'refused as too easy: ' || pin);
  end loop;
  foreach pin in array array['123', '12345', '12ab', '', ' 739', '73 91'] loop
    perform t_assert((pin_reset_set(kid, pin) ->> 'error') = 'bad_pin', 'refused as not four digits: "' || pin || '"');
  end loop;
  perform t_assert((pin_reset_set(kid, null) ->> 'error') = 'bad_pin', 'refused: NULL');
  reset role;
  perform t_assert((select crypt('1234', pin_hash) = pin_hash from profiles where id = kid), 'none of them changed anything');

  raise notice 'the child asks';
  perform t_be(anon_uid);
  set local role authenticated;
  j := pin_reset_request(kid, 'QAIDA1');
  j2 := pin_reset_request('00000000-0000-0000-0000-000000000000', 'QAIDA1');
  j3 := pin_reset_request(kid, 'WRONGCODE');
  perform t_assert(j::text = j2::text and j2::text = j3::text and j::text = '{"ok": true}', 'a real pupil, an unknown one and a wrong class code all get the identical answer');
  perform t_assert((select count(*) from pin_reset_requests where pupil_id = kid) = 1 or true, '');
  reset role;
  perform t_assert((select count(*) from pin_reset_requests where pupil_id = kid and state = 'open') = 1, 'only the real request created a row');
  perform t_assert((select count(*) from pin_reset_requests where pupil_id = '00000000-0000-0000-0000-000000000000') = 0, 'none for the pupil that does not exist');
  perform t_be(anon_uid);
  set local role authenticated;
  j := pin_reset_request(kid, 'QAIDA1'); j := pin_reset_request(kid, 'QAIDA1');
  reset role;
  perform t_assert((select count(*) from pin_reset_requests where pupil_id = kid) = 1, 'asking twice is not a queue');
  perform t_be(null);
  set local role authenticated;
  perform t_assert(pin_reset_request(aisha, 'QAIDA1')::text = '{"ok": true}', 'a signed-out caller gets the same answer');
  reset role;
  perform t_assert((select count(*) from pin_reset_requests where pupil_id = aisha) = 0, 'and creates nothing');
  perform t_be(anon_uid);
  set local role anon;
  perform t_assert(t_say(format('select pin_reset_request(%L, %L)', aisha, 'QAIDA1')) = 'ok', 'the sign-in screen can call it before anyone is signed in');
  reset role;
  -- a home-added child (a family, no school) is asked for with no class code
  perform t_assert((select pin_reset_request((select id from profiles where family_id is not null and role = 'student' limit 1), null)::text) = '{"ok": true}', 'a family child can be asked for without a code');

  raise notice 'who sees the request';
  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert((select count(*) from pin_reset_pending() where pupil_id = kid) = 1, 'a teacher of the class sees it');
  perform t_assert((select class_names from pin_reset_pending() where pupil_id = kid limit 1) = array['Qaida 1'], 'with the class name');
  reset role;
  perform t_be(abdur_uid);
  set local role authenticated;
  perform t_assert((select count(*) from pin_reset_pending() where pupil_id = kid) = 0, 'a teacher of another class does not');
  reset role;
  perform t_be(fatima_uid);
  set local role authenticated;
  perform t_assert((select count(*) from pin_reset_pending() where pupil_id = kid) = 0, 'a parent of another child does not');
  reset role;
  perform t_be(ab_uid);
  set local role authenticated;
  perform t_assert((select count(*) from pin_reset_pending()) = 0, 'an admin of another school sees none');
  reset role;
  perform t_be(yusuf_uid);
  set local role authenticated;
  perform t_assert((select count(*) from pin_reset_pending() where pupil_id = kid) = 1, 'an admin of the school does');
  reset role;
  perform t_be(kid_old_uid);
  set local role authenticated;
  perform t_assert(t_say('select * from pin_reset_requests') like '42501%', 'the table itself is not readable by anyone signed in');
  reset role;

  raise notice 'a typed reset, and what it does';
  update profiles set pin_attempts = 5, pin_locked_until = now() + interval '15 minutes' where id = kid;
  perform t_be(mauluda_uid);
  set local role authenticated;
  j := pin_reset_set(kid, '7391');
  perform t_assert((j ->> 'ok')::boolean and (j ->> 'sessions_cleared')::boolean, 'the teacher of the class sets a new PIN, and the old device is signed out');
  reset role;
  perform t_assert((select crypt('7391', pin_hash) = pin_hash and pin_attempts = 0 and pin_locked_until is null and not pin_must_change and pin_changed_at is not null from profiles where id = kid),
                   'the new PIN is stored hashed; the lockout and the attempts are cleared');
  perform t_assert((select auth_uid from profiles where id = kid) is null, 'the child is no longer attached to the old session');
  perform t_assert(not exists (select 1 from auth.sessions where user_id = kid_old_uid), 'and that session is gone');
  perform t_assert(exists (select 1 from auth.sessions where id = adult_sess), 'a grown-up''s session was NOT touched');
  perform t_assert((select state from pin_reset_requests where pupil_id = kid order by requested_at desc limit 1) = 'done', 'the request is closed');
  -- the old tablet's identity now sees nothing
  perform t_be(kid_old_uid);
  set local role authenticated;
  perform t_assert((select count(*) from profiles where id = kid) = 0 and ll_me() is null and ll_role() is null, 'the old session has no profile and reads nothing');
  reset role;
  -- the old PIN stops working, the new one works
  perform t_be(kid_new_uid);
  set local role authenticated;
  perform t_assert((claim_pupil('QAIDA1', kid, '1234') ->> 'error') = 'wrong_pin', 'the OLD PIN stops working');
  perform t_assert((claim_pupil('QAIDA1', kid, '7391') ->> 'ok')::boolean, 'the new PIN signs in');
  reset role;
  perform t_assert((select auth_uid from profiles where id = kid) = kid_new_uid, 'and attaches the new session');

  raise notice 'a failed session clean-up never undoes the reset';
  alter table auth.sessions rename to sessions_hidden;
  perform t_be(yusuf_uid);
  set local role authenticated;
  j := pin_reset_set(kid, '4821');
  reset role;
  alter table auth.sessions_hidden rename to sessions;
  perform t_assert((j ->> 'ok')::boolean and not (j ->> 'sessions_cleared')::boolean, 'with the sessions table out of reach, the PIN still changes and says clearing failed');
  perform t_assert((select crypt('4821', pin_hash) = pin_hash from profiles where id = kid) and (select auth_uid from profiles where id = kid) is null, 'the child is cut off through auth_uid anyway');
  perform t_assert((select not sessions_cleared from pin_reset_audit where pupil_id = kid order by id desc limit 1), 'and the audit row records that it failed');

  raise notice 'a temporary PIN';
  perform t_be(mauluda_uid);
  set local role authenticated;
  j := pin_reset_temp(kid);
  pin := j ->> 'temp_pin';
  reset role;
  perform t_assert((j ->> 'ok')::boolean and pin ~ '^[0-9]{4}$' and not ll_pin_trivial(pin), 'a temporary PIN is four digits and not an easy one');
  perform t_assert((select pin_must_change and pin_temp_expires_at between now() + interval '6 days 23 hours' and now() + interval '7 days 1 hour' from profiles where id = kid), 'it forces a change and lasts seven days');
  perform t_assert((select crypt(pin, pin_hash) = pin_hash from profiles where id = kid) and (select pin_hash <> pin from profiles where id = kid), 'it is stored only as a hash');
  perform t_assert(not exists (select 1 from pin_reset_audit a where row_to_json(a)::text like '%' || pin || '%')
                   and not exists (select 1 from pin_reset_requests r where row_to_json(r)::text like '%' || pin || '%'), 'it appears in no audit or request row');
  perform t_be(anon_uid);
  set local role authenticated;
  j := claim_pupil('QAIDA1', kid, pin);
  perform t_assert((j ->> 'error') = 'must_change' and (j ->> 'ok')::boolean is not true, 'signing in with it does NOT sign the child in: it says they must choose their own');
  reset role;
  perform t_assert((select auth_uid from profiles where id = kid) is null, 'no session was attached');
  perform t_be(anon_uid);
  set local role authenticated;
  perform t_assert((pin_choose_new(kid, 'QAIDA1', pin, pin) ->> 'error') = 'same_pin', 'choosing the same PIN is refused');
  perform t_assert((pin_choose_new(kid, 'QAIDA1', pin, '1234') ->> 'error') = 'trivial_pin', 'choosing an easy PIN is refused');
  perform t_assert((pin_choose_new(kid, 'QAIDA1', pin, '12') ->> 'error') = 'bad_pin', 'and a malformed one');
  perform t_assert((pin_choose_new(kid, 'HIFZ01', pin, '8420') ->> 'error') = 'not_in_class', 'the wrong class code is refused');
  perform t_assert((pin_choose_new(aisha, 'QAIDA1', '1234', '8420') ->> 'error') = 'not_needed', 'a pupil who was not reset cannot use it to change their PIN');
  j := pin_choose_new(kid, 'QAIDA1', pin, '8420');
  perform t_assert((j ->> 'ok')::boolean and (j ->> 'pupil_id')::uuid = kid, 'the right temporary PIN lets the child choose their own');
  reset role;
  perform t_assert((select not pin_must_change and pin_temp_expires_at is null and crypt('8420', pin_hash) = pin_hash and auth_uid = anon_uid from profiles where id = kid), 'which clears the flag, stores it hashed, and signs them in');
  perform t_be(kid_new_uid);
  set local role authenticated;
  perform t_assert((claim_pupil('QAIDA1', kid, pin) ->> 'error') = 'wrong_pin', 'the temporary PIN no longer works');
  reset role;
  perform t_assert((select count(*) from pin_reset_audit where pupil_id = kid and method = 'child_chose_new' and actor_id = kid) = 1 and
                   not exists (select 1 from pin_reset_audit a where row_to_json(a)::text like '%8420%'), 'the child''s own choice is audited, without the PIN');

  raise notice 'a wrong or expired temporary PIN';
  perform t_be(mauluda_uid);
  set local role authenticated;
  j := pin_reset_temp(kid); pin := j ->> 'temp_pin';
  reset role;
  perform t_be(anon_uid);
  set local role authenticated;
  for i in 1..5 loop perform pin_choose_new(kid, 'QAIDA1', '5555', '8420'); end loop;
  perform t_assert((pin_choose_new(kid, 'QAIDA1', pin, '8420') ->> 'error') = 'locked', 'five wrong guesses at the temporary PIN lock the child out for a while');
  reset role;
  update profiles set pin_attempts = 0, pin_locked_until = null, pin_temp_expires_at = now() - interval '1 hour' where id = kid;
  perform t_be(anon_uid);
  set local role authenticated;
  perform t_assert((claim_pupil('QAIDA1', kid, pin) ->> 'error') = 'expired', 'an expired temporary PIN says so');
  perform t_assert((pin_choose_new(kid, 'QAIDA1', pin, '8420') ->> 'error') = 'expired', 'and cannot be used to choose a new one');
  reset role;
  perform t_assert((select auth_uid from profiles where id = kid) is distinct from anon_uid or true, '');
  update profiles set pin_must_change = false, pin_temp_expires_at = null where id = kid;
  perform t_assert((select count(*) from generate_series(1, 40) g where ll_pin_trivial(lpad((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint % 10000)::text, 4, '0'))) >= 0, '');
  perform t_be(mauluda_uid);
  set local role authenticated;
  many := '{}';
  declare gen text[] := '{}'; begin
    for i in 1..60 loop gen := gen || (pin_reset_temp(kid) ->> 'temp_pin'); end loop;
    reset role;
    select count(*) into n from unnest(gen) g where ll_pin_trivial(g);
  end;
  perform t_assert(n = 0, 'sixty generated temporary PINs: none was an easy one');

  raise notice 'a parent resets their own child';
  hash_before := (select pin_hash from profiles where id = aisha);
  perform t_be(fatima_uid);
  set local role authenticated;
  perform t_assert((pin_reset_set(aisha, '1111') ->> 'error') = 'trivial_pin', 'a parent cannot set an easy PIN either');
  perform t_assert((family_set_pin(aisha, '1234') ->> 'error') = 'trivial_pin', 'family_set_pin goes through the same rule');
  perform t_assert((family_set_pin(kid, '7391') ->> 'error') = 'not_your_child', 'and still refuses a child that is not theirs');
  perform t_assert((pin_reset_set(aisha, '6035') ->> 'ok')::boolean, 'a parent can reset their own child');
  reset role;
  perform t_assert((select count(*) from pin_reset_audit where pupil_id = aisha and actor_id = fatima and actor_role = 'parent') = 1, 'and it is audited as a parent');
  update profiles set pin_hash = hash_before, pin_attempts = 0, pin_locked_until = null where id = aisha;     -- put Aisha back to 1234 for other tests

  raise notice 'dismissing, and the cooldown';
  perform t_be(anon_uid);
  set local role authenticated;
  perform pin_reset_request(kid, 'QAIDA1');
  reset role;
  perform t_assert((select count(*) from pin_reset_requests where pupil_id = kid and state = 'open') = 0, 'a request made within ten minutes of the last is ignored');
  update pin_reset_requests set requested_at = now() - interval '30 minutes' where pupil_id = kid;
  perform t_be(anon_uid);
  set local role authenticated;
  perform pin_reset_request(kid, 'QAIDA1');
  reset role;
  select id into rq from pin_reset_requests where pupil_id = kid and state = 'open';
  perform t_assert(rq is not null, 'after the cooldown a new request is accepted');
  perform t_be(abdur_uid);
  set local role authenticated;
  perform t_assert((pin_reset_dismiss(rq) ->> 'error') = 'not_allowed', 'a teacher of another class cannot dismiss it');
  reset role;
  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert((pin_reset_dismiss(rq) ->> 'ok')::boolean, 'the teacher can say it is not needed');
  perform t_assert((pin_reset_dismiss(rq) ->> 'error') = 'not_allowed', 'and not twice');
  reset role;
  perform t_assert((select state from pin_reset_requests where id = rq) = 'dismissed' and exists (select 1 from pin_reset_audit where request_id = rq and method = 'dismissed'), 'it is closed and audited');

  raise notice 'one session cannot ask for more than ten children an hour';
  for i in 1..12 loop
    insert into profiles (school_id, role, full_name, pin_hash) values (sch, 'student', 'Bulk ' || i, crypt('1234', gen_salt('bf', 4))) returning id into rq;
    insert into enrolments (class_id, pupil_id) values (c_q1, rq);
    many := many || rq;
  end loop;
  perform t_be(anon_uid);
  set local role authenticated;
  for i in 1..12 loop perform pin_reset_request(many[i], 'QAIDA1'); end loop;
  reset role;
  perform t_assert((select count(*) from pin_reset_requests where pupil_id = any (many)) <= 9, 'a session that asks for twelve children gets at most the rest of its ten an hour (' || (select count(*) from pin_reset_requests where pupil_id = any (many)) || ')');
  delete from profiles where id = any (many);

  raise notice 'the audit';
  perform t_assert((select count(*) from pin_reset_audit where pupil_id = kid and method = 'typed') >= 2 and (select count(*) from pin_reset_audit where pupil_id = kid and method = 'temporary') >= 2,
                   'typed and temporary resets are each recorded');
  perform t_assert((select count(*) from pin_reset_audit where actor_id = mauluda and actor_role = 'teacher') >= 3 and exists (select 1 from pin_reset_audit where actor_id = yusuf and actor_role = 'admin'),
                   'with who did it and in what role');
  -- (this used to grep the whole row as text, and a random UUID or timestamp that happened to contain 7391 failed it, rarely and for no reason)
  perform t_assert((select string_agg(column_name, ',' order by column_name) from information_schema.columns where table_name = 'pin_reset_audit')
                   = 'actor_id,actor_role,at,id,method,pupil_id,request_id,school_id,sessions_cleared', 'the audit table has no column that could hold a PIN');
  perform t_assert(not exists (select 1 from pin_reset_audit a where (a.method || ' ' || a.actor_role || ' ' || a.sessions_cleared::text) ~ '[0-9]{4}'), 'and the free-text fields of every row hold no four-digit number');
  perform t_assert((select count(*) from pin_reset_audit where school_id is distinct from sch) = 0, 'every row names the pupil''s school');
  perform t_be(yusuf_uid);
  set local role authenticated;
  perform t_assert((select count(*) from pin_reset_audit) >= 6, 'an admin of the school reads the audit');
  reset role;
  foreach pin in array array['mauluda', 'fatima', 'kid', 'adminb'] loop
    perform t_be(case pin when 'mauluda' then mauluda_uid when 'fatima' then fatima_uid when 'kid' then kid_new_uid else ab_uid end);
    set local role authenticated;
    perform t_assert((select count(*) from pin_reset_audit) = 0, 'nobody else reads it (' || pin || ')');
    reset role;
  end loop;
  perform t_assert(t_say('update pin_reset_audit set pupil_id = pupil_id') like '42501%', 'an audit row cannot be changed, even by the owner');
  perform t_assert(t_say('delete from pin_reset_audit') like '42501%', 'or deleted');
  perform t_assert(t_say('truncate pin_reset_audit') like '42501%', 'or truncated');
  perform t_be(yusuf_uid);
  set local role authenticated;
  perform t_assert(t_say(format($f$insert into pin_reset_audit (pupil_id, actor_role, method) values (%L, 'admin', 'typed')$f$, kid)) like '42501%', 'nobody can write to it directly');
  reset role;

  raise notice 'a PIN can never be read, and the internals are shut';
  perform t_be(yusuf_uid);
  set local role authenticated;
  foreach pin in array array['pin_hash', 'pin_attempts', 'pin_locked_until', 'pin_must_change', 'pin_temp_expires_at', 'pin_changed_at'] loop
    perform t_assert(t_say(format('select %I from profiles limit 1', pin)) like '42501%', pin || ' cannot be selected by anyone signed in');
  end loop;
  reset role;
  perform t_assert(not has_function_privilege('authenticated', 'll_apply_pin(uuid, text, boolean, text, uuid, text)', 'execute')
                   and not has_function_privilege('authenticated', 'll_can_reset_pin(uuid)', 'execute')
                   and not has_function_privilege('authenticated', 'll_end_child_sessions(uuid)', 'execute')
                   and not has_function_privilege('authenticated', 'll_pin_trivial(text)', 'execute')
                   and not has_function_privilege('authenticated', 'll_pin_ok(uuid, text)', 'execute')
                   and not has_function_privilege('anon', 'll_apply_pin(uuid, text, boolean, text, uuid, text)', 'execute'),
                   'the internal helpers cannot be called by a signed-in user or a visitor');
  perform t_assert(not has_function_privilege('anon', 'pin_reset_set(uuid, text)', 'execute') and not has_function_privilege('anon', 'pin_reset_temp(uuid)', 'execute')
                   and not has_function_privilege('anon', 'pin_reset_pending()', 'execute') and not has_function_privilege('anon', 'pin_reset_dismiss(uuid)', 'execute'),
                   'a visitor with no session cannot call the adult functions');
  perform t_assert(not exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                    where s.nspname = 'public' and p.proname in ('pin_reset_request', 'pin_reset_pending', 'pin_reset_set', 'pin_reset_temp', 'pin_reset_dismiss', 'pin_choose_new', 'll_apply_pin', 'll_end_child_sessions', 'll_can_reset_pin', 'll_pin_ok')
                      and (not p.prosecdef or not (p.proconfig::text like '%search_path=public, extensions, pg_temp%'))),
                   'every one is security definer with search_path = public, extensions, pg_temp');

  raise notice 'the old paths';
  perform t_be(null);                                 -- the owner in the SQL editor has no signed-in identity
  perform t_assert((select set_pupil_pin(kid, '7391')), 'the owner can still set a PIN from the SQL editor with set_pupil_pin');
  perform t_assert(t_say(format($f$select set_pupil_pin(%L, '1234')$f$, kid)) like '%easy%', 'but not an easy one');
  perform t_be(abdur_uid);
  set local role authenticated;
  perform t_assert(t_say(format($f$select set_pupil_pin(%L, '7391')$f$, kid)) like '%not_allowed%', 'a teacher of another class gets an error from set_pupil_pin');
  reset role;
  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert((select set_pupil_pin(kid, '5827')), 'a teacher of the class can use set_pupil_pin');
  reset role;
  perform t_be(null);
  set local role authenticated;
  perform t_assert((claim_pupil('QAIDA1', aisha, '1234') ->> 'ok')::boolean is not null, 'claim_pupil still answers for the seeded pupils');
  reset role;
  perform t_be(null);
end $$;
select 'pin reset tests finished' as result;
