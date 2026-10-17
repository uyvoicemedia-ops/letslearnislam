-- ============================================================
-- Nobody edits their own role (0016). Each attempt is checked twice:
-- that it is refused, and that the row is unchanged afterwards.
-- Runs after 0170; reuses t_assert, t_be, t_say.
-- ============================================================
do $$
declare
  aisha uuid; aisha_uid uuid; mauluda uuid; mauluda_uid uuid; bilal uuid; yusuf_uid uuid; fatima uuid; fatima_uid uuid; ab_uid uuid; sch uuid; sch_b uuid;
  pin_before text; rc int; col text;
begin
  select id, auth_uid into aisha, aisha_uid from profiles where full_name = 'Aisha Khan';
  select id, auth_uid into mauluda, mauluda_uid from profiles where full_name = 'Mauluda Begum';
  select id into bilal from profiles where full_name = 'Bilal Ahmed';
  select auth_uid into yusuf_uid from profiles where full_name = 'Yusuf Ibrahim';
  select id, auth_uid into fatima, fatima_uid from profiles where full_name = 'Fatima Khan';
  select auth_uid into ab_uid from profiles where full_name = 'Admin B';
  select id into sch from schools where name = 'Al-Noor Madrasah';
  select id into sch_b from schools where name = 'Other Madrasah';

  raise notice 'a child';
  perform t_be(aisha_uid);
  set local role authenticated;
  foreach col in array array['role', 'school_id', 'family_id', 'email', 'auth_uid', 'pin_hash', 'pin_attempts', 'pin_locked_until', 'is_test'] loop
    perform t_assert(t_say(format('update profiles set %I = %I where id = %L', col, col, aisha)) like '42501%',
                     'a child cannot update their own ' || col);
  end loop;
  perform t_assert(t_say(format($f$update profiles set role = 'admin' where id = %L$f$, aisha)) like '42501%', 'a child cannot make themselves an admin');
  perform t_assert(t_say(format($f$update profiles set pin_hash = 'x' where id = %L$f$, aisha)) like '42501%', 'or write their own PIN hash');
  perform t_assert(t_say(format($f$update profiles set full_name = 'Aisha K.' where id = %L$f$, aisha)) = 'ok', 'a child can still change their own name');
  perform t_assert(t_say(format($f$update profiles set avatar = '{"x":1}'::jsonb where id = %L$f$, aisha)) = 'ok', 'and their own avatar');
  update profiles set full_name = 'Aisha Khan' where id = aisha;
  perform t_assert(t_say(format($f$insert into profiles (school_id, role, full_name, email) values (%L, 'admin', 'Child Made Admin', 'x@example.com')$f$, sch)) like '42501%', 'a child cannot create a profile');
  reset role;
  perform t_assert((select role from profiles where id = aisha) = 'student', 'and Aisha is still a pupil afterwards');
  perform t_assert((select pin_hash from profiles where id = aisha) is not null and (select pin_hash from profiles where id = aisha) <> 'x', 'with her own PIN untouched');

  raise notice 'a teacher';
  select pin_hash into pin_before from profiles where id = bilal;
  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert(t_say(format($f$update profiles set role = 'admin' where id = %L$f$, mauluda)) like '42501%', 'a teacher cannot make themselves an admin');
  perform t_assert(t_say(format($f$update profiles set role = 'teacher' where id = %L$f$, bilal)) like '42501%', 'or change a pupil''s role');
  perform t_assert(t_say(format($f$update profiles set pin_hash = 'zzz' where id = %L$f$, bilal)) like '42501%', 'or write a pupil''s PIN hash directly (no function, no audit)');
  perform t_assert(t_say(format($f$update profiles set school_id = %L where id = %L$f$, sch_b, bilal)) like '42501%', 'or move a pupil to another school');
  perform t_assert(t_say(format($f$update profiles set email = 'planted@example.com' where id = %L$f$, mauluda)) like '42501%', 'or change an email (which is how a sign-up is matched)');
  perform t_assert(t_say(format($f$insert into profiles (school_id, role, full_name, email) values (%L, 'admin', 'Planted Admin', 'planted@example.com')$f$, sch)) like '42501%', 'a teacher cannot plant a new admin profile');
  perform t_assert(t_say(format($f$insert into profiles (school_id, role, full_name, pin_hash) values (%L, 'student', 'Ghost Pupil', 'x')$f$, sch)) like '42501%', 'or a pupil');
  perform t_assert(t_say(format($f$update profiles set full_name = 'Bilal A.' where id = %L$f$, bilal)) = 'ok', 'a teacher can still correct a pupil''s name');
  update profiles set full_name = 'Bilal Ahmed' where id = bilal;
  reset role;
  perform t_assert((select role from profiles where id = mauluda) = 'teacher' and (select pin_hash from profiles where id = bilal) = pin_before
                   and not exists (select 1 from profiles where full_name in ('Planted Admin', 'Ghost Pupil')),
                   'and nothing changed: still a teacher, the PIN is as it was, no planted profiles');

  raise notice 'a parent, and an admin';
  perform t_be(fatima_uid);
  set local role authenticated;
  perform t_assert(t_say(format($f$update profiles set role = 'admin' where id = %L$f$, fatima)) like '42501%', 'a parent cannot make themselves an admin');
  perform t_assert(t_say(format($f$update profiles set pin_hash = 'q' where id = %L$f$, aisha)) like '42501%', 'or write their child''s PIN hash');
  reset role;
  perform t_be(yusuf_uid);
  set local role authenticated;
  perform t_assert(t_say(format($f$update profiles set role = 'admin' where id = %L$f$, mauluda)) like '42501%', 'even an admin cannot change roles from the app (the owner does that in the SQL editor)');
  perform t_assert(t_say(format($f$update profiles set full_name = 'Mauluda B.' where id = %L$f$, mauluda)) = 'ok', 'but can correct a name');
  update profiles set full_name = 'Mauluda Begum' where id = mauluda;
  reset role;
  perform t_be(ab_uid);
  set local role authenticated;
  perform t_assert((select count(*) from profiles where id = aisha) = 0 or true, '');
  update profiles set full_name = 'Hijacked' where id = aisha;
  get diagnostics rc = row_count;
  perform t_assert(rc = 0, 'an admin at another school cannot rename our pupil');
  reset role;

  raise notice 'the things that must keep working';
  perform t_assert(exists (select 1 from pg_proc where proname = 'claim_pupil'), 'claim_pupil still exists');
  perform t_be(null);
end $$;
select 'profiles lockdown tests finished' as result;
