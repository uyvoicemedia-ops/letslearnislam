-- ============================================================
-- Homework: who may set it, who may hand it in, who may mark it, and
-- who may see any of it. Runs after 0160; reuses t_assert, t_be, t_count, t_say.
-- ============================================================
do $$
declare
  sch uuid; c_q1 uuid; c_hifz uuid; c_b uuid;
  mauluda uuid; mauluda_uid uuid; abdur_uid uuid; yusuf uuid; yusuf_uid uuid; aisha uuid; aisha_uid uuid; bilal uuid; bilal_uid uuid; hamza uuid; hamza_uid uuid;
  fatima_uid uuid; ab_uid uuid; tb_uid uuid; kb_uid uuid; anon_uid uuid := gen_random_uuid();
  hw uuid; hw2 uuid; hw_hifz uuid; hw_past uuid; j jsonb; rc int; r record;
begin
  select id into sch from schools where name = 'Al-Noor Madrasah';
  select id into c_q1 from classes where join_code = 'QAIDA1';
  select id into c_hifz from classes where join_code = 'HIFZ01';
  select id into c_b from classes where join_code = 'OTHER1';
  select id, auth_uid into mauluda, mauluda_uid from profiles where full_name = 'Mauluda Begum';
  select auth_uid into abdur_uid from profiles where full_name = 'Abdur Rahman';
  select id, auth_uid into yusuf, yusuf_uid from profiles where full_name = 'Yusuf Ibrahim';
  select id, auth_uid into aisha, aisha_uid from profiles where full_name = 'Aisha Khan';
  select id, auth_uid into bilal, bilal_uid from profiles where full_name = 'Bilal Ahmed';
  select id, auth_uid into hamza, hamza_uid from profiles where full_name = 'Hamza Malik';
  select auth_uid into fatima_uid from profiles where full_name = 'Fatima Khan';
  select auth_uid into ab_uid from profiles where full_name = 'Admin B';
  select auth_uid into tb_uid from profiles where full_name = 'Teacher B';
  select auth_uid into kb_uid from profiles where full_name = 'Pupil B';
  insert into auth.users (id, is_anonymous) values (anon_uid, true);

  raise notice 'a teacher setting homework';
  perform t_be(mauluda_uid);
  set local role authenticated;
  j := homework_set(c_q1, '  Read page 5  ', 'Read it twice, out loud.', null, current_date + 3);
  perform t_assert((j ->> 'ok')::boolean, 'a teacher sets homework for their own class');
  hw := (j ->> 'id')::uuid;
  perform t_assert((select title = 'Read page 5' and details = 'Read it twice, out loud.' and set_by = mauluda and module_id is null from homework where id = hw),
                   'the title is trimmed, the details kept, and it records who set it');
  j := homework_set(c_q1, 'Trace letters', null, 'tracing', current_date + 2);
  hw2 := (j ->> 'id')::uuid;
  perform t_assert((homework_set(c_hifz, 'Nope', null, null, null) ->> 'error') = 'not_allowed', 'but not for a class they do not teach');
  perform t_assert((homework_set(c_q1, '', null, null, null) ->> 'error') = 'bad_title', 'a title is required');
  perform t_assert((homework_set(c_q1, repeat('x', 121), null, null, null) ->> 'error') = 'bad_title', 'and not too long');
  perform t_assert((homework_set(c_q1, 'x', repeat('y', 501), null, null) ->> 'error') = 'bad_details', 'details are capped at 500 characters');
  perform t_assert((homework_set(c_q1, 'x', null, 'drop table', null) ->> 'error') = 'bad_module', 'a link to a practice that does not exist is refused');
  perform t_assert((homework_set(c_q1, 'x', null, null, current_date - 1) ->> 'error') = 'bad_due', 'a due date in the past is refused');
  perform t_assert((homework_set(c_q1, 'x', null, null, current_date + 400) ->> 'error') = 'bad_due', 'and one more than a year away');
  perform t_assert((homework_set(c_q1, 'No date', null, null, null) ->> 'ok')::boolean, 'a due date is optional');
  perform t_assert(t_say(format($f$insert into homework (class_id, title) values (%L, 'direct')$f$, c_q1)) like '42501%', 'writing the table directly is refused');
  perform t_assert(t_say(format($f$update homework set title = 'x' where id = %L$f$, hw)) like '42501%', 'so is updating it directly');
  perform t_assert(t_say(format($f$delete from homework where id = %L$f$, hw)) like '42501%', 'and deleting from it');
  reset role;

  perform t_be(yusuf_uid);
  set local role authenticated;
  j := homework_set(c_hifz, 'Surah practice', null, 'reading', current_date + 5);
  hw_hifz := (j ->> 'id')::uuid;
  perform t_assert((j ->> 'ok')::boolean, 'an admin sets homework for any class in their school');
  reset role;
  perform t_be(ab_uid);
  set local role authenticated;
  perform t_assert((homework_set(c_q1, 'Cross school', null, null, null) ->> 'error') = 'not_allowed', 'an admin at another school cannot');
  perform t_assert((homework_update(hw, 'Hijack', null, null, null) ->> 'error') = 'not_allowed', 'or change ours');
  perform t_assert((homework_delete(hw) ->> 'error') = 'not_allowed', 'or delete it');
  perform t_assert(t_count(format('select 1 from homework where id in (%L, %L)', hw, hw_hifz)) = 0, 'or even read it');
  reset role;

  raise notice 'a pupil handing in';
  perform t_be(aisha_uid);
  set local role authenticated;
  perform t_assert(t_count(format('select 1 from homework where id = %L', hw)) = 1 and t_count(format('select 1 from homework where id = %L', hw_hifz)) = 0,
                   'a pupil sees their own class''s homework and not another class''s');
  j := homework_hand_in(hw, null);
  perform t_assert((j ->> 'ok')::boolean and (select score from submissions where homework_id = hw and pupil_id = aisha) is null,
                   'handing in with no score is just "I have done it"');
  j := homework_hand_in(hw, 70);
  perform t_assert((j ->> 'score')::int = 70, 'a later score is recorded');
  j := homework_hand_in(hw, 55);
  perform t_assert((j ->> 'score')::int = 70, 'a worse score does not replace a better one');
  j := homework_hand_in(hw, 90);
  perform t_assert((j ->> 'score')::int = 90, 'a better one does');
  j := homework_hand_in(hw, null);
  perform t_assert((j ->> 'score')::int = 90, 'handing in again with no score keeps the score');
  perform t_assert((homework_hand_in(hw, 101) ->> 'error') = 'bad_score', 'a score over 100 is refused');
  perform t_assert((homework_hand_in(hw_hifz, 50) ->> 'error') = 'not_allowed', 'a pupil cannot hand in to a class they are not in');
  perform t_assert(t_say(format($f$insert into submissions (homework_id, pupil_id, score) values (%L, %L, 100)$f$, hw2, aisha)) like '42501%', 'and cannot write submissions directly');
  perform t_assert(t_say(format($f$update submissions set score = 100 where homework_id = %L$f$, hw)) like '42501%', 'or give themselves a better mark');
  reset role;
  perform t_be(hamza_uid);
  set local role authenticated;
  perform t_assert((homework_hand_in(hw, 100) ->> 'error') = 'not_allowed', 'a pupil in another class cannot hand in to this one');
  reset role;
  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert((homework_hand_in(hw, 100) ->> 'error') = 'not_allowed', 'a teacher cannot hand work in as a pupil');
  reset role;

  raise notice 'a teacher marking';
  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert((homework_mark(hw, bilal, 80, 'x') ->> 'error') = 'not_handed_in', 'a teacher cannot mark work that has not been handed in');
  j := homework_mark(hw, aisha, null, '  Lovely reading!  ');
  perform t_assert((j ->> 'ok')::boolean, 'a teacher marks handed-in work');
  select * into r from submissions where homework_id = hw and pupil_id = aisha;
  perform t_assert(r.marked_at is not null and r.marked_by = mauluda and r.score = 90 and r.feedback = 'Lovely reading!',
                   'it records when, who and the note, and keeps the child''s own score when none is given');
  j := homework_mark(hw, aisha, 95, 'Even better');
  perform t_assert((j ->> 'ok')::boolean and (select score from submissions where homework_id = hw and pupil_id = aisha) = 95,
                   'a teacher can change the score and the note');
  perform t_assert((homework_mark(hw, aisha, 101, null) ->> 'error') = 'bad_score', 'a score over 100 is refused');
  perform t_assert((homework_mark(hw, aisha, 90, repeat('z', 301)) ->> 'error') = 'bad_feedback', 'a note is capped at 300 characters');
  perform t_assert(t_say(format($f$update submissions set score = 0 where homework_id = %L$f$, hw)) like '42501%', 'marking is not possible by writing the table directly');
  reset role;
  perform t_be(abdur_uid);
  set local role authenticated;
  perform t_assert((homework_mark(hw, aisha, 0, 'sabotage') ->> 'error') = 'not_allowed', 'a teacher of another class cannot mark it');
  perform t_assert((homework_update(hw, 'Hijack', null, null, null) ->> 'error') = 'not_allowed', 'or edit it');
  perform t_assert(t_count(format('select 1 from homework where id = %L', hw)) = 0 and t_count(format('select 1 from submissions where homework_id = %L', hw)) = 0,
                   'or see it, or its submissions');
  reset role;
  perform t_be(aisha_uid);
  set local role authenticated;
  perform t_assert((homework_hand_in(hw, 100) ->> 'error') = 'already_marked' and (select score from submissions where homework_id = hw and pupil_id = aisha) = 95,
                   'once marked, the child can no longer change it');
  perform t_assert(t_count(format($f$select 1 from submissions where homework_id = %L and feedback = 'Even better'$f$, hw)) = 1, 'the child can read their teacher''s note');
  reset role;
  perform t_be(bilal_uid);
  set local role authenticated;
  perform t_assert(t_count(format('select 1 from submissions where homework_id = %L', hw)) = 0, 'another pupil cannot read it');
  reset role;
  perform t_be(fatima_uid);
  set local role authenticated;
  perform t_assert(t_count(format($f$select 1 from submissions where homework_id = %L and feedback = 'Even better'$f$, hw)) = 1 and t_count(format('select 1 from homework where id = %L', hw)) = 1,
                   'a parent sees their child''s homework and the note');
  reset role;

  raise notice 'editing and deleting';
  insert into homework (class_id, title, due_on, set_by) values (c_q1, 'Old piece', current_date - 10, mauluda) returning id into hw_past;
  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert((homework_update(hw_past, 'Old piece, renamed', 'details', 'tracing', current_date - 10) ->> 'ok')::boolean, 'an overdue piece can be renamed without moving its date');
  perform t_assert((homework_update(hw_past, 'Old piece', null, null, current_date - 5) ->> 'error') = 'bad_due', 'but a new due date must be a real future one');
  j := homework_update(hw2, 'Trace a few letters', 'both rows', 'tracing', current_date + 6);
  perform t_assert((j ->> 'ok')::boolean and (select title from homework where id = hw2) = 'Trace a few letters', 'a teacher edits their own homework');
  perform t_assert((homework_delete(hw) ->> 'ok')::boolean, 'a teacher deletes their own homework');
  reset role;
  perform t_assert((select count(*) from submissions where homework_id = hw) = 0, 'and its submissions go with it');

  raise notice 'everyone else';
  perform t_be(tb_uid);
  set local role authenticated;
  perform t_assert(t_count(format('select 1 from homework where class_id = %L', c_q1)) = 0, 'a teacher at another school sees none of ours');
  reset role;
  perform t_be(kb_uid);
  set local role authenticated;
  perform t_assert((homework_hand_in(hw2, 50) ->> 'error') = 'not_allowed', 'a pupil at another school cannot hand in to ours');
  reset role;
  perform t_be(anon_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from homework') = 0 and (homework_hand_in(hw2, 50) ->> 'error') = 'not_allowed' and (homework_set(c_q1, 'x', null, null, null) ->> 'error') = 'not_allowed',
                   'an unclaimed anonymous session sees and does nothing');
  reset role;
  perform t_be(null);
  set local role anon;
  perform t_assert(t_say('select * from homework') like '42501%' and t_say('select * from submissions') like '42501%', 'an anonymous caller is refused outright');
  perform t_assert(t_say(format('select homework_mark(%L, %L, 1, null)', hw2, aisha)) like '42501%', 'including the functions');
  reset role;
  perform t_be(null);
end $$;
select 'homework tests finished' as result;
