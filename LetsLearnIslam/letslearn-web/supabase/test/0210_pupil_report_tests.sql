-- ============================================================
-- The progress report for one child (0019). Runs after 0200; reuses t_assert, t_be, t_count, t_say.
-- Who may ask, what they get, what must NEVER be in it, and that it only reads.
-- ============================================================
do $$
declare
  sch uuid; c_q1 uuid;
  aisha uuid; hamza uuid; fatima uuid; mauluda uuid; abdur uuid; yusuf uuid; adminb uuid; teacherb uuid;
  aisha_uid uuid; hamza_uid uuid; fatima_uid uuid; mauluda_uid uuid; abdur_uid uuid; yusuf_uid uuid; ab_uid uuid; tb_uid uuid;
  d0 date := current_date - 380;           -- a window the seed data never touches
  d1 date := current_date - 372;
  hw_a uuid; hw_b uuid; hw_c uuid;
  kid_uid uuid; j jsonb; denied jsonb; n_att int; n_pts int; n_sub int; txt text;
begin
  select id into sch from schools where name = 'Al-Noor Madrasah';
  select id into c_q1 from classes where join_code = 'QAIDA1';
  select id, auth_uid into aisha, aisha_uid from profiles where full_name = 'Aisha Khan';
  select id, auth_uid into hamza, hamza_uid from profiles where full_name = 'Hamza Malik';
  select id, auth_uid into fatima, fatima_uid from profiles where full_name = 'Fatima Khan';
  select id, auth_uid into mauluda, mauluda_uid from profiles where full_name = 'Mauluda Begum';
  select id, auth_uid into abdur, abdur_uid from profiles where full_name = 'Abdur Rahman';
  select id, auth_uid into yusuf, yusuf_uid from profiles where full_name = 'Yusuf Ibrahim';
  select id, auth_uid into adminb, ab_uid from profiles where full_name = 'Admin B';
  select id, auth_uid into teacherb, tb_uid from profiles where full_name = 'Teacher B';

  -- known data for Aisha in a window of her own (written as the owner, bypassing the rules, to set the scene)
  insert into attendance (pupil_id, class_id, on_date, mark) values
    (aisha, c_q1, d0, 'present'), (aisha, c_q1, d0 + 1, 'present'), (aisha, c_q1, d0 + 2, 'present'),
    (aisha, c_q1, d0 + 3, 'present'), (aisha, c_q1, d0 + 4, 'present'),
    (aisha, c_q1, d0 + 5, 'late'), (aisha, c_q1, d0 + 6, 'late'),
    (aisha, c_q1, d0 + 7, 'absent'), (aisha, c_q1, d0 + 8, 'excused');
  insert into practice (pupil_id, module_id, score, stars, at) values
    (aisha, 'tracing', 60, 1, (d0 + 1)::timestamp + interval '12 hours'),
    (aisha, 'tracing', 80, 2, (d0 + 2)::timestamp + interval '12 hours'),
    (aisha, 'tracing', 100, 3, (d0 + 3)::timestamp + interval '12 hours'),
    (aisha, 'mazes', 90, 2, (d0 + 4)::timestamp + interval '12 hours');
  insert into reading (pupil_id, book_id, page, updated_at) values (aisha, 'report-test-book', 5, (d0 + 2)::timestamp + interval '12 hours');
  insert into points (pupil_id, source, amount, reason, given_by, at) values
    (aisha, 'practice', 10, 'SECRETREASON-xyz', null, (d0 + 1)::timestamp + interval '12 hours'),
    (aisha, 'teacher_gift', 5, 'a private note ABC', mauluda, (d0 + 2)::timestamp + interval '12 hours');
  insert into homework (class_id, title, due_on, set_by) values (c_q1, 'Report test A', d0 + 3, mauluda) returning id into hw_a;
  insert into homework (class_id, title, due_on, set_by) values (c_q1, 'Report test B', d0 + 4, mauluda) returning id into hw_b;
  insert into homework (class_id, title, due_on, set_by) values (c_q1, 'Report test C', d0 + 5, mauluda) returning id into hw_c;
  insert into submissions (homework_id, pupil_id, score, submitted_at, marked_at, marked_by, feedback)
    values (hw_a, aisha, 80, (d0 + 3)::timestamp, (d0 + 4)::timestamp, mauluda, 'Well done FEEDBACKTXT');
  insert into submissions (homework_id, pupil_id, score, submitted_at) values (hw_c, aisha, 70, (d0 + 5)::timestamp);

  select count(*) into n_att from attendance; select count(*) into n_pts from points; select count(*) into n_sub from submissions;

  raise notice 'a parent asks about their own child';
  perform t_be(fatima_uid);
  set local role authenticated;
  j := pupil_report(aisha, d0, d1);
  reset role;
  perform t_assert(j ? 'pupil' and j -> 'pupil' ->> 'name' = 'Aisha Khan', 'a parent gets the report for their own child');
  perform t_assert((j #>> '{attendance,present}')::int = 5 and (j #>> '{attendance,late}')::int = 2 and (j #>> '{attendance,absent}')::int = 1
                   and (j #>> '{attendance,excused}')::int = 1 and (j #>> '{attendance,total}')::int = 9, 'attendance counts are exact');
  perform t_assert((j #>> '{attendance,attended_pct}')::int = 88, 'attendance percentage is 7 of 8 (the excused day is not held against her)');
  perform t_assert(jsonb_array_length(j #> '{attendance,missed}') = 3 and (j #>> '{attendance,missed,0,mark}') = 'excused' is not true, 'the missed list has the absent and late days only');
  perform t_assert((select count(*) from jsonb_array_elements(j #> '{attendance,missed}') m where m ->> 'mark' in ('absent', 'late')) = 3, 'and nothing else');
  perform t_assert((j #>> '{practice,totals,attempts}')::int = 4 and (j #>> '{practice,totals,stars}')::int = 8, 'practice totals are exact');
  perform t_assert((select (m ->> 'attempts')::int = 3 and (m ->> 'avg_score')::int = 80 and (m ->> 'best_score')::int = 100 and (m ->> 'stars')::int = 6
                    from jsonb_array_elements(j #> '{practice,by_module}') m where m ->> 'module' = 'tracing'), 'per module: attempts, average, best and stars');
  perform t_assert(jsonb_array_length(j -> 'reading') = 1 and (j #>> '{reading,0,book}') = 'report-test-book' and (j #>> '{reading,0,page}')::int = 5, 'the book she is reading');
  perform t_assert((j #>> '{homework,totals,set}')::int = 3 and (j #>> '{homework,totals,marked}')::int = 1
                   and (j #>> '{homework,totals,handed_in}')::int = 2 and (j #>> '{homework,totals,missing}')::int = 1, 'homework totals: set 3, marked 1, handed in 2, missing 1');
  perform t_assert((select m ->> 'feedback' from jsonb_array_elements(j #> '{homework,items}') m where m ->> 'title' = 'Report test A') = 'Well done FEEDBACKTXT',
                   'the teacher''s note to the child is there (the child and parent could already read it)');
  perform t_assert((j #>> '{coins,total}')::int = 15 and (j #>> '{coins,by_source,practice}')::int = 10 and (j #>> '{coins,by_source,teacher_gift}')::int = 5, 'coins: totals by kind');
  perform t_assert(j -> 'classes' -> 0 ->> 'name' is not null, 'her class is named');

  raise notice 'what must never be in it';
  txt := j::text;
  perform t_assert(txt not like '%SECRETREASON%' and txt not like '%private note%', 'no coin reasons, however they were written');
  perform t_assert(txt !~* '(given_by|"reason"|pin_|pin_hash|email|auth_uid|password)', 'no reason, giver, PIN, email or account fields');
  perform t_assert(not exists (select 1 from jsonb_object_keys(j) k where k not in ('pupil', 'classes', 'range', 'generated_on', 'attendance', 'practice', 'reading', 'homework', 'coins')),
                   'only the sections that were designed');

  raise notice 'the people who may ask';
  perform t_be(mauluda_uid); set local role authenticated; j := pupil_report(aisha, d0, d1); reset role;
  perform t_assert(j ? 'attendance', 'the teacher of her class');
  perform t_be(yusuf_uid); set local role authenticated; j := pupil_report(aisha, d0, d1); reset role;
  perform t_assert(j ? 'attendance', 'an admin of her school');
  -- the seeded children have no session yet; give Aisha one for a moment, as claiming does
  insert into auth.users (is_anonymous) values (true) returning id into kid_uid;
  update profiles set auth_uid = kid_uid where id = aisha;
  perform t_be(kid_uid); set local role authenticated; j := pupil_report(aisha, d0, d1); reset role;
  perform t_assert(j ? 'attendance', 'and the child herself');
  perform t_be(kid_uid); set local role authenticated; denied := pupil_report(hamza, d0, d1); reset role;
  perform t_assert(denied = jsonb_build_object('error', 'not_allowed'), 'but a child cannot ask about a classmate');
  update profiles set auth_uid = aisha_uid where id = aisha;
  delete from auth.users where id = kid_uid;

  raise notice 'the people who may not, and that they cannot tell why';
  perform t_be(fatima_uid); set local role authenticated; denied := pupil_report(hamza, d0, d1); reset role;
  perform t_assert(denied = jsonb_build_object('error', 'not_allowed'), 'a parent asking about someone else''s child');
  perform t_be(abdur_uid); set local role authenticated; j := pupil_report(aisha, d0, d1); reset role;
  perform t_assert(j = denied, 'a teacher of a different class gets the identical answer');
  perform t_be(ab_uid); set local role authenticated; j := pupil_report(aisha, d0, d1); reset role;
  perform t_assert(j = denied, 'an admin at another school gets the identical answer');
  perform t_be(tb_uid); set local role authenticated; j := pupil_report(aisha, d0, d1); reset role;
  perform t_assert(j = denied, 'so does a teacher at another school');
  perform t_be(yusuf_uid); set local role authenticated; j := pupil_report(gen_random_uuid(), d0, d1); reset role;
  perform t_assert(j = denied, 'a child who does not exist looks exactly like one you may not see');
  perform t_be(yusuf_uid); set local role authenticated; j := pupil_report(mauluda, d0, d1); reset role;
  perform t_assert(j = denied, 'and a grown-up is not a pupil: no report for them');
  perform t_be(null); set local role anon;
  perform t_assert(t_say(format('select pupil_report(%L, %L, %L)', aisha, d0, d1)) like '42501%', 'the signed-out public key cannot call it at all');
  reset role;
  perform t_assert(has_function_privilege('authenticated', 'pupil_report(uuid,date,date)', 'execute') and not has_function_privilege('anon', 'pupil_report(uuid,date,date)', 'execute'),
                   'execute is for signed-in people only');

  raise notice 'the range';
  perform t_be(mauluda_uid); set local role authenticated;
  perform t_assert((pupil_report(aisha, d1, d0) ->> 'error') = 'bad_range', 'from after to is refused');
  perform t_assert((pupil_report(aisha, d0, d0 + 401) ->> 'error') = 'bad_range', 'more than 400 days is refused');
  perform t_assert((pupil_report(aisha, null, d1) ->> 'error') = 'bad_range' and (pupil_report(aisha, d0, null) ->> 'error') = 'bad_range', 'a missing date is refused');
  perform t_assert((pupil_report(aisha, d0, d0 + 400) ->> 'error') is null, 'exactly 400 days is allowed');
  perform t_assert((pupil_report(aisha, d1 + 1, d1 + 30) #>> '{attendance,total}')::int = 0 and (pupil_report(aisha, d1 + 1, d1 + 30) #>> '{coins,total}')::int = 0,
                   'a window with nothing in it returns zeros, not an error');
  perform t_assert((pupil_report(aisha, d1 + 1, d1 + 30) #>> '{attendance,attended_pct}') is null, 'and no percentage (not 0%)');
  reset role;

  raise notice 'it only reads, and it runs as the caller';
  perform t_assert((select count(*) from attendance) = n_att and (select count(*) from points) = n_pts and (select count(*) from submissions) = n_sub, 'no rows were written by any of that');
  perform t_assert(not (select prosecdef from pg_proc where proname = 'pupil_report' and pronamespace = 'public'::regnamespace), 'it is SECURITY INVOKER: it can show only what the caller can already read');
  perform t_assert((select provolatile from pg_proc where proname = 'pupil_report' and pronamespace = 'public'::regnamespace) = 's', 'and it is declared STABLE (reads only)');

  perform t_be(null);
  delete from submissions where homework_id in (hw_a, hw_b, hw_c);
  delete from homework where id in (hw_a, hw_b, hw_c);
  delete from points where pupil_id = aisha and at between d0 and d1 + 1;
  delete from reading where pupil_id = aisha and book_id = 'report-test-book';
  delete from practice where pupil_id = aisha and at between d0 and d1 + 1;
  delete from attendance where pupil_id = aisha and on_date between d0 and d1;
end $$;
