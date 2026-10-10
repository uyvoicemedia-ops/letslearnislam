-- ============================================================
-- LetsLearn — seed
-- ------------------------------------------------------------
-- The same school the prototype has always shown, as real rows, so the
-- app looks familiar the first time it talks to the database instead of
-- greeting you with eight empty tables.
--
-- BEFORE YOU RUN THIS, change the three email addresses below to ones
-- you can actually receive at. They are how your admin, teacher and
-- parent accounts get matched to these roster rows when you sign up.
--
-- EVERY PUPIL'S PIN HERE IS 1234. That is fine for a laptop on your
-- desk and not fine for anything else. Before a real child uses this,
-- set real PINs — the teacher screen does it, or:
--     select set_pupil_pin('<pupil uuid>', '7391');
-- ============================================================

do $$
declare
  sch uuid;
  c1 uuid; c2 uuid; c3 uuid; c4 uuid;
  t_mauluda uuid; t_yusuf uuid; t_abdur uuid;
  a_admin uuid; p_fatima uuid;
  s1 uuid; s2 uuid; s3 uuid; s4 uuid;
  s5 uuid; s6 uuid; s7 uuid; s8 uuid;
  qs uuid;
  test_pin text := crypt('1234', gen_salt('bf', 10));
begin

insert into schools (name) values ('Al-Noor Madrasah') returning id into sch;

-- ---------- adults ----------
-- CHANGE THESE EMAILS
insert into profiles (school_id, role, full_name, email) values
  (sch, 'admin',   'Yusuf Ibrahim',  'admin@example.com')    returning id into a_admin;
insert into profiles (school_id, role, full_name, email) values
  (sch, 'teacher', 'Mauluda Begum',  'teacher@example.com')  returning id into t_mauluda;
insert into profiles (school_id, role, full_name, email) values
  (sch, 'teacher', 'Abdur Rahman',   'teacher2@example.com') returning id into t_abdur;
insert into profiles (school_id, role, full_name, email) values
  (sch, 'parent',  'Fatima Khan',    'parent@example.com')   returning id into p_fatima;

-- the admin also teaches Nazira A, as in the prototype
t_yusuf := a_admin;

-- ---------- classes ----------
insert into classes (school_id, name, room, join_code) values
  (sch, 'Qaida 1',  'Room 1', 'QAIDA1') returning id into c1;
insert into classes (school_id, name, room, join_code) values
  (sch, 'Qaida 2',  'Room 1', 'QAIDA2') returning id into c2;
insert into classes (school_id, name, room, join_code) values
  (sch, 'Nazira A', 'Room 2', 'NAZIRA') returning id into c3;
insert into classes (school_id, name, room, join_code) values
  (sch, 'Hifz',     'Room 3', 'HIFZ01') returning id into c4;

insert into class_teachers (class_id, teacher_id) values
  (c1, t_mauluda), (c2, t_mauluda), (c3, t_yusuf), (c4, t_abdur);

-- ---------- pupils ----------
insert into profiles (school_id, role, full_name, pin_hash) values
  (sch, 'student', 'Aisha Khan',      test_pin) returning id into s1;
insert into profiles (school_id, role, full_name, pin_hash) values
  (sch, 'student', 'Bilal Ahmed',     test_pin) returning id into s2;
insert into profiles (school_id, role, full_name, pin_hash) values
  (sch, 'student', 'Maryam Siddiq',   test_pin) returning id into s3;
insert into profiles (school_id, role, full_name, pin_hash) values
  (sch, 'student', 'Yusuf Patel',     test_pin) returning id into s4;
insert into profiles (school_id, role, full_name, pin_hash) values
  (sch, 'student', 'Zainab Ali',      test_pin) returning id into s5;
insert into profiles (school_id, role, full_name, pin_hash) values
  (sch, 'student', 'Ibrahim Hussain', test_pin) returning id into s6;
insert into profiles (school_id, role, full_name, pin_hash) values
  (sch, 'student', 'Khadija Rahman',  test_pin) returning id into s7;
insert into profiles (school_id, role, full_name, pin_hash) values
  (sch, 'student', 'Hamza Malik',     test_pin) returning id into s8;

insert into enrolments (class_id, pupil_id) values
  (c1, s1), (c1, s2), (c1, s3),
  (c2, s4), (c2, s5),
  (c3, s6), (c3, s7),
  (c4, s8);

insert into guardians (parent_id, pupil_id) values (p_fatima, s1);

-- ---------- a term's worth of register ----------
-- Roughly the attendance percentages the prototype showed, spread over
-- the last 30 school days so the screens have something to draw.
insert into attendance (pupil_id, class_id, on_date, mark, marked_by)
select p.pupil, p.cls, d::date,
       case when random() < p.rate then 'present'::attendance_mark
            when random() < 0.5    then 'late'::attendance_mark
            else 'absent'::attendance_mark end,
       t_mauluda
from (values
        (s1, c1, 0.96), (s2, c1, 0.88), (s3, c1, 1.00),
        (s4, c2, 0.72), (s5, c2, 0.94),
        (s6, c3, 0.91), (s7, c3, 0.98), (s8, c4, 0.85)
     ) as p(pupil, cls, rate),
     generate_series(current_date - 29, current_date, interval '1 day') d
where extract(dow from d) not in (0, 6);

-- ---------- homework ----------
insert into homework (class_id, title, module_id, due_on, set_by) values
  (c1, 'Trace ب ت ث',           'tracing',   current_date - 4, t_mauluda),
  (c1, 'Letters quiz — group 2', 'quizzes',   current_date - 2, t_mauluda),
  (c2, 'Read pages 12–15',       'reading',   current_date - 3, t_mauluda),
  (c3, 'Say It Back — Al-Asr',   'sayitback', current_date - 1, t_yusuf),
  (c4, 'Surah Al-Kawthar',       'reading',   current_date,     t_abdur);

-- ---------- a little history for Aisha, who is the demo child ----------
insert into practice (pupil_id, module_id, label, score, stars, at)
select s1, m.id, m.label, m.score, m.stars, now() - (m.days || ' days')::interval
from (values
        ('tracing',   'Tracing ب',        95, 3, 1),
        ('quizzes',   'Letters quiz',     80, 2, 1),
        ('mazes',     'Letter maze',      70, 2, 2),
        ('sayitback', 'Say It Back',     100, 3, 2),
        ('reading',   'Qaida page 8',     90, 3, 3)
     ) as m(id, label, score, stars, days);

insert into reading (pupil_id, book_id, page, finished_at) values
  (s1, 'qaida-1', 12, now() - interval '3 days'),
  (s1, 'qaida-2', 4,  null),
  (s1, 'elementary-1', 20, now() - interval '1 day');

insert into points (pupil_id, source, amount, reason, given_by, at) values
  (s1, 'teacher_gift', 20, 'for helping a younger child', t_mauluda, now() - interval '1 day'),
  (s1, 'parent_gift',  10, 'for listening to your parents', p_fatima, now() - interval '2 hours'),
  (s1, 'homework',      8, 'Trace ب ت ث handed in', null, now() - interval '3 days'),
  (s1, 'practice',     39, '13 stars', null, now() - interval '2 days');

insert into garden (pupil_id, state) values (s1, '{}'::jsonb);

-- ---------- a quiz to try ----------
insert into quiz_sets (school_id, owner_id, title)
values (sch, t_mauluda, 'Letters — group 1')
returning id into qs;

insert into quiz_questions (set_id, ord, prompt, choices, answer, seconds) values
  (qs, 1, 'Which one is ا?',  '["ا","ب","ت","ث"]'::jsonb, 0, 20),
  (qs, 2, 'Which one is ب?',  '["ت","ب","ن","ي"]'::jsonb, 1, 20),
  (qs, 3, 'How many dots does ث have?', '["one","two","three","none"]'::jsonb, 2, 15),
  (qs, 4, 'Which letter comes first?',  '["ب","ا","ت","ث"]'::jsonb, 1, 15),
  (qs, 5, 'Which one is ت?',  '["ث","ن","ت","ب"]'::jsonb, 2, 20);

raise notice 'Seeded Al-Noor Madrasah. Class codes: QAIDA1 QAIDA2 NAZIRA HIFZ01. Every pupil PIN is 1234 — change them.';

end $$;
