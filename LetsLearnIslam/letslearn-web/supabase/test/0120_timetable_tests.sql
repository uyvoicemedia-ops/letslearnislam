-- ============================================================
-- The weekly timetable and the class-running functions.
-- ------------------------------------------------------------
-- Runs after 0110, reusing t_assert, t_be, t_count and the second
-- school it built ("Other Madrasah", with Teacher B / Admin B /
-- Parent B / Pupil B). Every refusal checks WHICH refusal it was.
-- ============================================================

create or replace function t_say(p_sql text) returns text
language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;

do $$
declare
  sch uuid; sch_b uuid;
  c_q1 uuid; c_q2 uuid; c_naz uuid; c_hifz uuid; c_b uuid;
  mauluda_uid uuid; abdur uuid; abdur_uid uuid; yusuf uuid; yusuf_uid uuid;
  fatima_uid uuid; aisha uuid; aisha_uid uuid; hamza_uid uuid;
  tb_uid uuid; ab_uid uuid; pb_uid uuid; kb_uid uuid; kb uuid;
  anon_uid uuid;
  tb uuid; slot_q1 uuid; r text; j jsonb; rc int; new_class uuid; code text;
begin
  select id into sch   from schools where name = 'Al-Noor Madrasah';
  select id into sch_b from schools where name = 'Other Madrasah';
  select id into c_q1   from classes where join_code = 'QAIDA1';
  select id into c_q2   from classes where join_code = 'QAIDA2';
  select id into c_naz  from classes where join_code = 'NAZIRA';
  select id into c_hifz from classes where join_code = 'HIFZ01';
  select id into c_b    from classes where join_code = 'OTHER1';

  select auth_uid into mauluda_uid from profiles where full_name = 'Mauluda Begum';
  select id, auth_uid into abdur,  abdur_uid  from profiles where full_name = 'Abdur Rahman';
  select id, auth_uid into yusuf,  yusuf_uid  from profiles where full_name = 'Yusuf Ibrahim';
  select auth_uid into fatima_uid from profiles where full_name = 'Fatima Khan';
  select id, auth_uid into aisha, aisha_uid from profiles where full_name = 'Aisha Khan';
  select auth_uid into hamza_uid from profiles where full_name = 'Hamza Malik';
  select id, auth_uid into tb, tb_uid from profiles where full_name = 'Teacher B';
  select auth_uid into ab_uid from profiles where full_name = 'Admin B';
  select auth_uid into pb_uid from profiles where full_name = 'Parent B';
  select id, auth_uid into kb, kb_uid from profiles where full_name = 'Pupil B';
  anon_uid := gen_random_uuid();
  insert into auth.users (id, is_anonymous) values (anon_uid, true);

  -- the other school's class has a room called "Room 1" too, to prove rooms are per school
  update classes set room = 'Room 1' where id = c_b;

  -- ---------- an admin builds the week ----------
  raise notice 'an admin setting the timetable';
  perform t_be(yusuf_uid);
  set local role authenticated;

  perform t_assert(t_say(format($f$insert into timetable_slots (class_id, weekday, starts_at, ends_at)
        values (%L, 1, '16:00', '17:00')$f$, c_q1)) = 'ok', 'an admin adds a lesson');
  select id into slot_q1 from timetable_slots where class_id = c_q1;
  perform t_assert((select school_id from timetable_slots where id = slot_q1) = sch,
                   'the school is taken from the class');

  perform t_assert(t_say(format($f$insert into timetable_slots (school_id, class_id, weekday, starts_at, ends_at)
        values (%L, %L, 2, '16:00', '17:00')$f$, sch_b, c_q1)) = 'ok',
        'a forged school on a lesson is accepted for their own class');
  perform t_assert((select count(*) from timetable_slots where weekday = 2 and school_id = sch) = 1,
                   'but is overwritten with the true school');

  r := t_say(format($f$insert into timetable_slots (class_id, weekday, starts_at, ends_at)
        values (%L, 1, '16:30', '17:30')$f$, c_q1));
  perform t_assert(r like '23P01%class already%', 'a class cannot be in two lessons at once: ' || r);

  perform t_assert(t_say(format($f$insert into timetable_slots (class_id, weekday, starts_at, ends_at)
        values (%L, 1, '17:00', '18:00')$f$, c_q1)) = 'ok',
        'back-to-back lessons are fine: one ends as the next starts');

  -- Nazira (Yusuf, "Room 2") borrowing Room 1 while Qaida 1 has it
  r := t_say(format($f$insert into timetable_slots (class_id, weekday, starts_at, ends_at, room)
        values (%L, 1, '16:30', '17:00', ' room 1 ')$f$, c_naz));
  perform t_assert(r like '23P01%room%', 'a room cannot be used twice at once, whatever its case or padding: ' || r);

  -- Qaida 2 shares Room 1 AND Mauluda
  r := t_say(format($f$insert into timetable_slots (class_id, weekday, starts_at, ends_at, room)
        values (%L, 1, '16:30', '17:30', 'Room 9')$f$, c_q2));
  perform t_assert(r like '23P01%teacher%', 'a teacher cannot teach two classes at once: ' || r);

  perform t_assert(t_say(format($f$insert into timetable_slots (class_id, weekday, starts_at, ends_at, room)
        values (%L, 1, '16:30', '17:30', 'Room 9')$f$, c_hifz)) = 'ok',
        'a different class, room and teacher at the same time is fine');
  perform t_assert(t_say(format($f$insert into timetable_slots (class_id, weekday, starts_at, ends_at)
        values (%L, 3, '16:30', '17:30')$f$, c_q2)) = 'ok', 'the same room on another day is fine');

  r := t_say(format($f$update timetable_slots set ends_at = '17:30' where id = %L$f$, slot_q1));
  perform t_assert(r like '23P01%', 'stretching a lesson into the next one is refused: ' || r);
  perform t_assert(t_say(format($f$update timetable_slots set room = 'Hall' where id = %L$f$, slot_q1)) = 'ok',
                   'a lesson can be edited without clashing with itself');

  perform t_assert(t_say(format($f$insert into timetable_slots (class_id, weekday, starts_at, ends_at)
        values (%L, 4, '17:00', '16:00')$f$, c_q1)) like '23514%', 'a lesson cannot end before it starts');
  perform t_assert(t_say(format($f$insert into timetable_slots (class_id, weekday, starts_at, ends_at)
        values (%L, 4, '08:00', '17:00')$f$, c_q1)) like '23514%', 'nor run longer than eight hours');
  perform t_assert(t_say(format($f$insert into timetable_slots (class_id, weekday, starts_at, ends_at)
        values (%L, 8, '16:00', '17:00')$f$, c_q1)) like '23514%', 'there is no eighth day');
  reset role;

  -- the same room name at another school is not a clash
  perform t_assert(t_say(format($f$insert into timetable_slots (class_id, weekday, starts_at, ends_at)
        values (%L, 1, '16:00', '17:00')$f$, c_b)) = 'ok',
        'another school may use a room with the same name at the same time');

  -- ---------- who sees the week ----------
  raise notice 'who sees the week';
  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from timetable_slots') = (select count(*) from timetable_slots where school_id = sch),
                   'a teacher sees the whole school''s week, and nothing from another school');
  perform t_assert(t_say(format($f$insert into timetable_slots (class_id, weekday, starts_at, ends_at)
        values (%L, 5, '16:00', '17:00')$f$, c_q1)) like '42501%', 'a teacher cannot change the timetable');
  delete from timetable_slots where id = slot_q1;
  get diagnostics rc = row_count;
  perform t_assert(rc = 0, 'or delete a lesson');
  reset role;

  perform t_be(aisha_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from timetable_slots') = 3 and
                   t_count(format('select 1 from timetable_slots where class_id <> %L', c_q1)) = 0,
                   'a pupil sees only their own class''s lessons');
  perform t_assert(t_say(format($f$insert into timetable_slots (class_id, weekday, starts_at, ends_at)
        values (%L, 5, '16:00', '17:00')$f$, c_q1)) like '42501%', 'a pupil cannot write');
  reset role;

  perform t_be(fatima_uid);
  set local role authenticated;
  perform t_assert(t_count(format('select 1 from timetable_slots where class_id = %L', c_q1)) = 3
                   and t_count(format('select 1 from timetable_slots where class_id <> %L', c_q1)) = 0,
                   'a parent sees their child''s class and no other');
  reset role;

  perform t_be(hamza_uid);
  set local role authenticated;
  perform t_assert(t_count(format('select 1 from timetable_slots where class_id = %L', c_q1)) = 0,
                   'a pupil in another class does not see it');
  reset role;

  foreach r in array array['tb', 'ab', 'pb', 'kb'] loop
    perform t_be(case r when 'tb' then tb_uid when 'ab' then ab_uid when 'pb' then pb_uid else kb_uid end);
    set local role authenticated;
    perform t_assert(t_count(format('select 1 from timetable_slots where school_id = %L', sch)) = 0,
                     'nobody at another school (' || r || ') reads this school''s timetable');
    reset role;
  end loop;

  perform t_be(ab_uid);
  set local role authenticated;
  perform t_assert(t_say(format($f$insert into timetable_slots (class_id, weekday, starts_at, ends_at)
        values (%L, 5, '16:00', '17:00')$f$, c_q1)) like '42501%', 'an admin cannot write to another school''s timetable');
  delete from timetable_slots where class_id = c_q1;
  get diagnostics rc = row_count;
  perform t_assert(rc = 0, 'or delete from it');
  reset role;

  perform t_be(null);
  set local role anon;
  perform t_assert(t_say('select * from timetable_slots') like '42501%', 'an anonymous caller is refused');
  reset role;
  perform t_be(anon_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from timetable_slots') = 0, 'an unclaimed anonymous session reads nothing');
  reset role;

  -- ---------- running the classes ----------
  raise notice 'creating and managing classes';
  perform t_be(yusuf_uid);
  set local role authenticated;
  j := class_create('  Tajweed 1 ', 'Room 4');
  perform t_assert((j ->> 'ok')::boolean, 'an admin creates a class');
  new_class := (j ->> 'id')::uuid;
  code := j ->> 'join_code';
  perform t_assert(code ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$',
                   'its join code is six unambiguous characters: ' || code);
  perform t_assert((select name = 'Tajweed 1' and school_id = sch and room = 'Room 4'
                    from classes where id = new_class), 'it belongs to the admin''s school, name trimmed');
  perform t_assert((class_create('', null) ->> 'error') = 'bad_name', 'a class needs a name');
  perform t_assert((class_create(repeat('x', 61), null) ->> 'error') = 'bad_name', 'and a sensible one');

  j := class_move_pupil(aisha, new_class);
  perform t_assert((j ->> 'ok')::boolean, 'an admin moves a pupil');
  perform t_assert((select count(*) from enrolments where pupil_id = aisha) = 1
                   and (select class_id from enrolments where pupil_id = aisha) = new_class,
                   'the pupil is in exactly one class, the new one');
  j := class_move_pupil(aisha, c_q1);
  perform t_assert((j ->> 'ok')::boolean
                   and (select class_id from enrolments where pupil_id = aisha) = c_q1,
                   'and can be moved back');
  perform t_assert((class_move_pupil(kb, c_q1) ->> 'error') = 'no_such_pupil',
                   'an admin cannot move another school''s pupil');
  perform t_assert((class_move_pupil(aisha, c_b) ->> 'error') = 'no_such_class',
                   'or move one of theirs into another school''s class');
  perform t_assert((class_move_pupil(abdur, c_q1) ->> 'error') = 'no_such_pupil',
                   'or "move" a teacher as if they were a pupil');

  j := class_set_teacher(new_class, abdur, true);
  perform t_assert((j ->> 'ok')::boolean
                   and exists (select 1 from class_teachers where class_id = new_class and teacher_id = abdur),
                   'an admin puts a teacher on a class');
  j := class_set_teacher(new_class, abdur, false);
  perform t_assert((j ->> 'ok')::boolean
                   and not exists (select 1 from class_teachers where class_id = new_class and teacher_id = abdur),
                   'and takes them off');
  perform t_assert((class_set_teacher(new_class, aisha, true) ->> 'error') = 'no_such_teacher',
                   'a pupil cannot be made a teacher');
  reset role;

  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert((class_create('Sneaky', null) ->> 'error') = 'not_admin', 'a teacher cannot create a class this way');
  perform t_assert((class_move_pupil(aisha, c_q2) ->> 'error') = 'not_admin', 'or move a pupil');
  perform t_assert((class_set_teacher(c_q2, abdur, true) ->> 'error') = 'not_admin', 'or assign a teacher');
  reset role;

  perform t_be(ab_uid);
  set local role authenticated;
  perform t_assert((class_set_teacher(c_q1, tb, true) ->> 'error') = 'no_such_class',
                   'an admin cannot assign a teacher to another school''s class');
  reset role;

  perform t_be(null);
  set local role anon;
  perform t_assert(t_say($f$select class_create('Anon', null)$f$) like '42501%', 'an anonymous caller cannot create a class');
  reset role;

  -- leave the fixtures as 0100 left them
  perform t_assert((select count(*) from enrolments where pupil_id = aisha and class_id = c_q1) = 1,
                   'the register is as it was');
  perform t_be(null);
end $$;

select 'timetable tests finished' as result;
