-- ============================================================
-- One school cannot reach into another (0017). The attack this was
-- written from: an admin at another school, holding only a class code.
-- Runs after 0180; reuses t_assert, t_be, t_count, t_say.
-- ============================================================
do $$
declare
  sch uuid; c_q1 uuid; c_hifz uuid; c_b uuid;
  aisha uuid; hamza uuid; fatima uuid; mauluda uuid; abdur uuid; yusuf uuid; adminb uuid; teacherb uuid;
  mauluda_uid uuid; abdur_uid uuid; yusuf_uid uuid; fatima_uid uuid; aisha_uid uuid; ab_uid uuid; tb_uid uuid;
  req uuid; j jsonb; n int; rc int;
begin
  select id into sch from schools where name = 'Al-Noor Madrasah';
  select id into c_q1 from classes where join_code = 'QAIDA1';
  select id into c_hifz from classes where join_code = 'HIFZ01';
  select id into c_b from classes where join_code = 'OTHER1';
  select id, auth_uid into aisha, aisha_uid from profiles where full_name = 'Aisha Khan';
  select id into hamza from profiles where full_name = 'Hamza Malik';
  select id, auth_uid into fatima, fatima_uid from profiles where full_name = 'Fatima Khan';
  select id, auth_uid into mauluda, mauluda_uid from profiles where full_name = 'Mauluda Begum';
  select id, auth_uid into abdur, abdur_uid from profiles where full_name = 'Abdur Rahman';
  select id, auth_uid into yusuf, yusuf_uid from profiles where full_name = 'Yusuf Ibrahim';
  select id, auth_uid into adminb, ab_uid from profiles where full_name = 'Admin B';
  select id, auth_uid into teacherb, tb_uid from profiles where full_name = 'Teacher B';

  raise notice 'an admin at another school, with only a class code';
  perform t_be(ab_uid);
  set local role authenticated;
  perform t_assert((select count(*) from class_roster('QAIDA1') where full_name = 'Aisha Khan') = 1, 'the class code does give them the pupil id (this is by design)');
  perform t_assert(t_say(format('insert into guardians (parent_id, pupil_id) values (%L, %L)', adminb, aisha)) like '42501%', 'but they cannot link themselves to the child as a guardian');
  perform t_assert(t_count(format('select 1 from profiles where id = %L', aisha)) = 0, 'so they still cannot read the child');
  perform t_assert(t_count(format('select 1 from practice where pupil_id = %L', aisha)) = 0 and t_count(format('select 1 from attendance where pupil_id = %L', aisha)) = 0
                   and t_count(format('select 1 from garden where pupil_id = %L', aisha)) = 0 and t_count(format('select 1 from points where pupil_id = %L', aisha)) = 0,
                   'or her practice, attendance, garden or points');
  perform t_assert(t_say(format('insert into class_teachers (class_id, teacher_id) values (%L, %L)', c_q1, adminb)) like '42501%', 'they cannot make themselves a teacher of our class');
  perform t_assert(t_say(format('insert into enrolments (class_id, pupil_id) values (%L, %L)', c_q1, adminb)) like '42501%', 'or enrol anyone in it');
  perform t_assert(t_say(format('delete from enrolments where class_id = %L', c_q1)) like '42501%', 'or remove our pupils from it');
  perform t_assert(t_count('select 1 from attendance') = 0, 'they read none of our registers');
  perform t_assert(t_say(format($f$insert into attendance (pupil_id, class_id, on_date, mark) values (%L, %L, current_date - 40, 'absent')$f$, aisha, c_q1)) like '42501%', 'and cannot write one');
  perform t_assert(t_count(format('select 1 from enrolments where class_id = %L', c_q1)) = 0, 'or see who is in our classes');
  reset role;
  perform t_assert(not exists (select 1 from guardians where parent_id = adminb), 'nothing was written');

  raise notice 'a class request into our school';
  insert into class_requests (pupil_id, class_id, asked_by) values (hamza, c_q1, fatima) returning id into req;
  perform t_be(ab_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from class_requests') = 0, 'another school''s admin cannot see requests aimed at our class');
  perform t_assert((select ll_offered_to_me(hamza)) is false, 'or be offered the pupil in one');
  perform t_assert((class_request_decide(req, true) ->> 'error') = 'not_your_class', 'or approve it');
  reset role;
  perform t_assert((select state from class_requests where id = req) = 'pending', 'the request is untouched');
  perform t_be(abdur_uid);
  set local role authenticated;
  perform t_assert((class_request_decide(req, true) ->> 'error') = 'not_your_class', 'a teacher of a different class cannot approve it either');
  reset role;
  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from class_requests') >= 1 and (select ll_offered_to_me(hamza)), 'the teacher of that class sees it, and the child on offer');
  perform t_assert((class_request_decide(req, true) ->> 'state') = 'approved', 'and can approve it');
  reset role;
  delete from enrolments where class_id = c_q1 and pupil_id = hamza;

  raise notice 'a teacher, and the register';
  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert(t_say(format('insert into enrolments (class_id, pupil_id) values (%L, %L)', c_q1, hamza)) like '42501%', 'a teacher cannot enrol a pupil by writing the table');
  perform t_assert(t_say(format('insert into guardians (parent_id, pupil_id) values (%L, %L)', mauluda, hamza)) like '42501%', 'or link themselves to one');
  perform t_assert(t_count(format('select 1 from enrolments where class_id = %L', c_q1)) >= 2, 'but they still see who is in their own class');
  perform t_assert(t_say(format($f$insert into attendance (pupil_id, class_id, on_date, mark) values (%L, %L, current_date - 50, 'present')$f$, aisha, c_q1)) = 'ok', 'a teacher can still mark their own class');
  perform t_assert(t_say(format($f$insert into attendance (pupil_id, class_id, on_date, mark) values (%L, %L, current_date - 51, 'present')$f$, hamza, c_q1)) like '42501%', 'but not a pupil who is not in that class');
  perform t_assert(t_say(format($f$insert into attendance (pupil_id, class_id, on_date, mark) values (%L, %L, current_date - 52, 'present')$f$, hamza, c_hifz)) like '42501%', 'nor a class they do not teach');
  perform t_assert(t_say(format($f$update attendance set mark = 'absent' where pupil_id = %L and on_date = current_date - 50$f$, aisha)) = 'ok', 'and can correct a mark');
  reset role;

  raise notice 'an admin of the same school, and the families';
  perform t_be(yusuf_uid);
  set local role authenticated;
  perform t_assert(t_say(format($f$insert into attendance (pupil_id, class_id, on_date, mark) values (%L, %L, current_date - 53, 'late')$f$, hamza, c_hifz)) = 'ok', 'an admin can mark any class in their own school');
  perform t_assert((class_move_pupil(aisha, c_q1) ->> 'ok')::boolean, 'class_move_pupil still works for them');
  perform t_assert(t_say(format('delete from enrolments where pupil_id = %L', aisha)) like '42501%', 'but not by writing the table');
  reset role;
  perform t_be(fatima_uid);
  set local role authenticated;
  perform t_assert(t_count(format('select 1 from guardians where pupil_id = %L', aisha)) = 1, 'a parent still sees their own family link');
  perform t_assert(t_say(format('insert into guardians (parent_id, pupil_id) values (%L, %L)', fatima, hamza)) like '42501%', 'but cannot add one');
  reset role;
  delete from attendance where on_date between current_date - 53 and current_date - 50;
  perform t_be(null);
end $$;
select 'cross-school tests finished' as result;
