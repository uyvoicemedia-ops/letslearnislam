-- ============================================================
-- The test student: who can make one, that it signs in like any
-- child (this is the first test that exercises claim_pupil's PIN
-- check through the `extensions` schema), and that a pupil cannot
-- flag themselves or anyone else.
-- Runs after 0120; reuses t_assert, t_be, t_count, t_say.
-- ============================================================
do $$
declare
  sch uuid; sch_b uuid;
  yusuf_uid uuid; mauluda_uid uuid; ab_uid uuid; aisha uuid; aisha_uid uuid;
  j jsonb; j2 jsonb; pupil uuid; code text; kid_uid uuid := gen_random_uuid(); kid2_uid uuid := gen_random_uuid();
  jb jsonb; rc int; r text;
begin
  select id into sch   from schools where name = 'Al-Noor Madrasah';
  select id into sch_b from schools where name = 'Other Madrasah';
  select auth_uid into yusuf_uid   from profiles where full_name = 'Yusuf Ibrahim';
  select auth_uid into mauluda_uid from profiles where full_name = 'Mauluda Begum';
  select auth_uid into ab_uid      from profiles where full_name = 'Admin B';
  select id, auth_uid into aisha, aisha_uid from profiles where full_name = 'Aisha Khan';
  insert into auth.users (id, is_anonymous) values (kid_uid, true), (kid2_uid, true);

  raise notice 'making a test student';
  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert((test_student_create() ->> 'error') = 'not_admin', 'a teacher cannot make a test student');
  reset role;

  perform t_be(null);
  set local role anon;
  perform t_assert(t_say('select test_student_create()') like '42501%', 'an anonymous caller cannot');
  reset role;

  perform t_be(yusuf_uid);
  set local role authenticated;
  j := test_student_create();
  perform t_assert((j ->> 'ok')::boolean, 'an admin makes one');
  pupil := (j ->> 'pupil_id')::uuid; code := j ->> 'join_code';
  j2 := test_student_create();
  perform t_assert((j2 ->> 'pupil_id')::uuid = pupil and (j2 ->> 'join_code') = code,
                   'calling it again returns the same student, not a second');
  reset role;

  perform t_assert((select is_test and role = 'student' and school_id = sch and full_name = 'Test Student'
                    from profiles where id = pupil), 'it is a flagged pupil of the admin''s school');
  perform t_assert((select count(*) from profiles where is_test and school_id = sch) = 1, 'only one per school');
  perform t_assert((select name from classes where join_code = code) = 'Test Class'
                   and (select count(*) from enrolments where class_id = (select id from classes where join_code = code)) = 1,
                   'in a Test Class of their own, with nobody else in it');
  perform t_assert((select count(*) from points where pupil_id = pupil) = 0
                   and (select count(*) from garden where pupil_id = pupil) = 0,
                   'and no coins are written to the database: the balance is test mode''s');
  perform t_assert((select count(*) from profiles where is_test and school_id = sch_b) = 0,
                   'another school has none');

  raise notice 'signing in as the test student';
  perform t_be(kid_uid);
  set local role authenticated;
  perform t_assert((select count(*) from class_roster(code)) = 1
                   and (select full_name from class_roster(code)) = 'Test Student',
                   'the class code lists exactly one name');
  perform t_assert((claim_pupil(code, pupil, '0000') ->> 'ok')::boolean is not true, 'a wrong PIN is refused');
  perform t_assert((claim_pupil(code, pupil, '1234') ->> 'ok')::boolean,
                   'PIN 1234 signs in (the hash is checked through the extensions schema)');
  perform t_assert((select id from profiles where auth_uid = kid_uid) = pupil, 'and the session is now the test student');
  reset role;

  raise notice 'the flag cannot be moved by the wrong people';
  perform t_be(kid_uid);
  set local role authenticated;
  perform t_assert(t_say(format('update profiles set is_test = false where id = %L', pupil)) like '42501%',
                   'the test student cannot unflag themselves');
  reset role;
  perform t_assert((select is_test from profiles where id = pupil), 'still flagged');

  perform t_be(aisha_uid);
  set local role authenticated;
  perform t_assert(t_say(format('update profiles set is_test = true where id = %L', aisha)) like '42501%',
                   'a real pupil cannot flag themselves as a test account');
  reset role;
  perform t_assert(not (select is_test from profiles where id = aisha), 'Aisha is still a real pupil');

  perform t_be(yusuf_uid);
  set local role authenticated;
  r := t_say(format('update profiles set is_test = false where id = %L', pupil));
  perform t_assert(r like '42501%', 'even an admin cannot flip the flag from the app any more (0016: only the owner can): ' || r);
  reset role;
  perform t_assert((select is_test from profiles where id = pupil), 'so the test student is still flagged');

  raise notice 'a second school gets its own';
  perform t_be(ab_uid);
  set local role authenticated;
  jb := test_student_create();
  perform t_assert((jb ->> 'ok')::boolean and (jb ->> 'pupil_id')::uuid <> pupil, 'another school''s admin makes a separate one');
  reset role;
  perform t_assert((select school_id from profiles where id = (jb ->> 'pupil_id')::uuid) = sch_b,
                   'in their own school, not ours');
  perform t_be(null);
end $$;
select 'test student tests finished' as result;
