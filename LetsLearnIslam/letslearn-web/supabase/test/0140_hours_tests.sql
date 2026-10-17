-- ============================================================
-- Teacher hours: where the numbers come from, that a past week stays
-- frozen, and that salary data reaches nobody but an admin (a teacher
-- sees their own hours, never a rate or a pay figure).
-- Runs after 0130; reuses t_assert, t_be, t_count, t_say.
-- It rebuilds the timetable for the first school so the expected
-- numbers do not depend on what earlier test files left behind.
-- ============================================================
do $$
declare
  sch uuid; sch_b uuid; c_q1 uuid; c_q2 uuid; c_hifz uuid; c_b uuid;
  mauluda uuid; abdur uuid; yusuf uuid; aisha uuid;
  mauluda_uid uuid; abdur_uid uuid; yusuf_uid uuid; aisha_uid uuid; fatima_uid uuid;
  tb_uid uuid; ab_uid uuid; pb_uid uuid; kb_uid uuid; anon_uid uuid := gen_random_uuid();
  wk date := (current_date - ((extract(isodow from current_date)::int - 1) + 7))::date;   -- last week's Monday
  j jsonb; r record; n int; rc int; hid uuid;
begin
  select id into sch   from schools where name = 'Al-Noor Madrasah';
  select id into sch_b from schools where name = 'Other Madrasah';
  select id into c_q1   from classes where join_code = 'QAIDA1';
  select id into c_q2   from classes where join_code = 'QAIDA2';
  select id into c_hifz from classes where join_code = 'HIFZ01';
  select id into c_b    from classes where join_code = 'OTHER1';
  select id, auth_uid into mauluda, mauluda_uid from profiles where full_name = 'Mauluda Begum';
  select id, auth_uid into abdur,   abdur_uid   from profiles where full_name = 'Abdur Rahman';
  select id, auth_uid into yusuf,   yusuf_uid   from profiles where full_name = 'Yusuf Ibrahim';
  select id, auth_uid into aisha,   aisha_uid   from profiles where full_name = 'Aisha Khan';
  select auth_uid into fatima_uid from profiles where full_name = 'Fatima Khan';
  select auth_uid into tb_uid from profiles where full_name = 'Teacher B';
  select auth_uid into ab_uid from profiles where full_name = 'Admin B';
  select auth_uid into pb_uid from profiles where full_name = 'Parent B';
  select auth_uid into kb_uid from profiles where full_name = 'Pupil B';
  insert into auth.users (id, is_anonymous) values (anon_uid, true);

  -- a known week: Qaida 1 Mon 90 min, Qaida 2 Wed 60 min (both Mauluda), Hifz Tue 120 min (Abdur)
  delete from timetable_slots where school_id = sch;
  insert into timetable_slots (class_id, weekday, starts_at, ends_at) values
    (c_q1, 1, '16:00', '17:30'), (c_q2, 3, '16:00', '17:00'), (c_hifz, 2, '10:00', '12:00');

  raise notice 'generating a week from the timetable';
  perform t_be(yusuf_uid);
  set local role authenticated;
  j := hours_generate_week(wk);
  perform t_assert((j ->> 'ok')::boolean and (j ->> 'inserted')::int = 3, 'an admin generates last week: 3 lessons -> 3 rows');
  j := hours_generate_week(wk);
  perform t_assert((j ->> 'inserted')::int = 0, 'running it again pays for nothing twice');
  perform t_assert((hours_generate_week(wk + 1) ->> 'error') = 'not_a_monday', 'a week must start on a Monday');
  j := hours_generate_week((current_date - ((extract(isodow from current_date)::int - 1)) + 7)::date);
  perform t_assert((j ->> 'inserted')::int = 0, 'next week is skipped: those lessons have not happened');

  select * into r from hours_week(wk) where teacher_name = 'Mauluda Begum';
  perform t_assert(r.minutes = 150 and r.classes = 'Qaida 1, Qaida 2', 'Mauluda: 150 minutes across Qaida 1 and Qaida 2');
  perform t_assert(r.pay_pence = 0 and r.rows_without_rate = 2 and r.rate_pence is null,
                   'no rate yet: no pay, and the two rows say so');

  j := hours_set_rate(mauluda, 1600);
  perform t_assert((j ->> 'filled')::int = 2, 'setting a rate fills the rows that had none');
  select * into r from hours_week(wk) where teacher_name = 'Mauluda Begum';
  perform t_assert(r.pay_pence = 4000 and r.rate_pence = 1600 and r.rows_without_rate = 0,
                   '150 min at £16/h is £40.00 exactly: ' || r.pay_pence);
  perform hours_set_rate(abdur, 2000);
  select * into r from hours_week(wk) where teacher_name = 'Abdur Rahman';
  perform t_assert(r.minutes = 120 and r.pay_pence = 4000, 'Abdur: 120 min at £20/h is £40.00');

  j := hours_set_rate(mauluda, 2000);
  perform t_assert((j ->> 'filled')::int = 0, 'a later rate change fills nothing: that week was paid');
  select * into r from hours_week(wk) where teacher_name = 'Mauluda Begum';
  perform t_assert(r.pay_pence = 4000 and r.rate_pence = 2000, 'last week is frozen at £16/h; the new rate is £20/h');

  raise notice 'cover and corrections';
  j := hours_add(abdur, c_hifz, wk + 3, 45, '  cover for Mauluda ');
  perform t_assert((j ->> 'ok')::boolean, 'an admin adds cover');
  select * into r from hours_week(wk) where teacher_name = 'Abdur Rahman';
  perform t_assert(r.minutes = 165 and r.pay_pence = 5500, 'it counts at the current rate: 45 min = £15.00 more');
  perform t_assert((select note from hours_log where source = 'manual' and teacher_id = abdur) = 'cover for Mauluda', 'the note is trimmed');
  perform t_assert((hours_add(abdur, c_hifz, wk, 0, null) ->> 'error') = 'bad_minutes', 'zero minutes is refused');
  perform t_assert((hours_add(abdur, c_hifz, wk, 721, null) ->> 'error') = 'bad_minutes', 'so is more than 12 hours');
  perform t_assert((hours_add(aisha, c_hifz, wk, 30, null) ->> 'error') = 'no_such_teacher', 'a pupil cannot be paid');
  perform t_assert((hours_add(abdur, c_b, wk, 30, null) ->> 'error') = 'no_such_class', 'or for another school''s class');
  perform t_assert((hours_set_rate(abdur, 20001) ->> 'error') = 'bad_rate', 'a rate over £200 an hour is refused');
  perform t_assert((select count(*) from hours_log) = 4, 'an admin sees all four rows');
  select id into hid from hours_log where source = 'manual';
  delete from hours_log where id = hid;
  get diagnostics rc = row_count;
  perform t_assert(rc = 1, 'an admin deletes a row');
  reset role;

  raise notice 'a teacher';
  perform t_be(mauluda_uid);
  set local role authenticated;
  select * into r from hours_week(wk);
  perform t_assert(r.minutes = 150 and r.teacher_name = 'Mauluda Begum', 'a teacher sees their own hours');
  perform t_assert(r.rate_pence is null and r.pay_pence is null, 'and no rate and no pay, even their own');
  perform t_assert((select count(*) from hours_week(wk)) = 1, 'and no other teacher');
  perform t_assert(t_count('select 1 from hours_log') = 2 and t_count(format('select 1 from hours_log where teacher_id = %L', abdur)) = 0,
                   'reading the table directly shows only their own rows');
  perform t_assert(t_say('select rate_pence from hours_log') like '42501%', 'the rate column itself is not readable by a teacher');
  perform t_assert(t_count('select 1 from teacher_rates') = 0, 'nor the rates table');
  perform t_assert(t_say(format($f$insert into hours_log (school_id, teacher_id, on_date, minutes, source)
        values (%L, %L, current_date, 600, 'manual')$f$, sch, mauluda)) like '42501%', 'a teacher cannot add hours to themselves');
  update hours_log set minutes = 720 where teacher_id = mauluda;
  get diagnostics rc = row_count;
  perform t_assert(rc = 0, 'or change them');
  delete from hours_log where teacher_id = mauluda;
  get diagnostics rc = row_count;
  perform t_assert(rc = 0, 'or delete them');
  perform t_assert((hours_set_rate(mauluda, 20000) ->> 'error') = 'not_admin', 'or raise their own rate');
  perform t_assert((hours_generate_week(wk) ->> 'error') = 'not_admin', 'or generate a week');
  perform t_assert((hours_add(mauluda, c_q1, wk, 60, null) ->> 'error') = 'not_admin', 'or add cover');
  reset role;

  raise notice 'everyone else';
  foreach n in array array[1, 2, 3, 4, 5] loop
    perform t_be(case n when 1 then tb_uid when 2 then ab_uid when 3 then pb_uid when 4 then kb_uid else anon_uid end);
    set local role authenticated;
    perform t_assert((select count(*) from hours_week(wk)) = 0 and t_count('select 1 from hours_log') = 0
                     and t_count('select 1 from teacher_rates') = 0,
                     'nothing for ' || (array['a teacher at another school', 'an admin at another school', 'a parent at another school',
                                             'a pupil at another school', 'an unclaimed anonymous session'])[n]);
    reset role;
  end loop;
  foreach n in array array[1, 2] loop
    perform t_be(case n when 1 then aisha_uid else fatima_uid end);
    set local role authenticated;
    perform t_assert((select count(*) from hours_week(wk)) = 0 and t_count('select 1 from hours_log') = 0,
                     'nothing for ' || (array['a pupil', 'a parent'])[n] || ' here either');
    reset role;
  end loop;

  perform t_be(ab_uid);
  set local role authenticated;
  perform t_assert((hours_set_rate(mauluda, 100) ->> 'error') = 'no_such_teacher', 'an admin cannot set another school''s teacher''s rate');
  perform t_assert((hours_add(mauluda, c_b, wk, 30, null) ->> 'error') = 'no_such_teacher', 'or add hours for them');
  perform t_assert((hours_generate_week(wk) ->> 'inserted')::int = 1, 'generating a week at their school makes only their own lesson''s row');
  reset role;
  perform t_assert((select count(*) from hours_log where school_id = sch_b) = 1 and
                   (select teacher_id from hours_log where school_id = sch_b) = (select id from profiles where full_name = 'Teacher B'),
                   'and it is for their own teacher, at their own school');
  perform t_assert((select count(*) from hours_log where school_id = sch) = 3, 'our hours are untouched');
  perform t_assert((select rate_pence from teacher_rates where teacher_id = mauluda) = 2000, 'and so is Mauluda''s rate');

  perform t_be(null);
  set local role anon;
  perform t_assert(t_say(format('select * from hours_week(%L)', wk)) like '42501%', 'an anonymous caller cannot ask for a week');
  perform t_assert(t_say('select * from hours_log') like '42501%' and t_say('select * from teacher_rates') like '42501%',
                   'or read either table');
  reset role;
  perform t_be(null);
end $$;
select 'hours tests finished' as result;
