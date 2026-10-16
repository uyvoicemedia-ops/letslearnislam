-- ============================================================
-- Class sessions: who may see a meeting link, who may set one,
-- and what a link is allowed to be.
-- ------------------------------------------------------------
-- Runs after 0100, so it reuses t_assert and t_be, and the people
-- 0100 already linked to sessions (Mauluda, Abdur, Fatima, Yusuf,
-- Aisha, Bilal). It adds a second school, because "nobody from
-- another school" cannot be tested with one.
--
-- A test that expects an error also checks WHICH error. Otherwise a
-- typo in the statement would pass as "denied".
-- ============================================================

-- Run a statement as whoever is currently connected and say what happened:
-- 'ok', or the SQLSTATE it raised.
create or replace function t_try(p_sql text) returns text
language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

create or replace function t_count(p_sql text) returns int
language plpgsql as $$
declare n int;
begin
  execute 'select count(*) from (' || p_sql || ') q' into n;
  return n;
end $$;

do $$
declare
  sch uuid; sch_b uuid;
  c_q1 uuid; c_q2 uuid; c_hifz uuid; c_b uuid;
  mauluda uuid; abdur uuid; fatima uuid; yusuf uuid; aisha uuid; bilal uuid; hamza uuid;
  mauluda_uid uuid; abdur_uid uuid; fatima_uid uuid; yusuf_uid uuid;
  aisha_uid uuid; bilal_uid uuid; hamza_uid uuid;
  tb uuid; tb_uid uuid := gen_random_uuid();
  ab uuid; ab_uid uuid := gen_random_uuid();
  pb uuid; pb_uid uuid := gen_random_uuid();
  kb uuid; kb_uid uuid := gen_random_uuid();
  anon_uid uuid := gen_random_uuid();
  s_q1 uuid; s_hifz uuid; s_q1_by_admin uuid;
  n int; r text; rc int; row_ record;
  bad text;
begin
  select id into sch from schools where name = 'Al-Noor Madrasah';
  select id into c_q1   from classes where join_code = 'QAIDA1';
  select id into c_q2   from classes where join_code = 'QAIDA2';
  select id into c_hifz from classes where join_code = 'HIFZ01';

  select id, auth_uid into mauluda, mauluda_uid from profiles where full_name = 'Mauluda Begum';
  select id, auth_uid into abdur,   abdur_uid   from profiles where full_name = 'Abdur Rahman';
  select id, auth_uid into fatima,  fatima_uid  from profiles where full_name = 'Fatima Khan';
  select id, auth_uid into yusuf,   yusuf_uid   from profiles where full_name = 'Yusuf Ibrahim';
  select id, auth_uid into aisha,   aisha_uid   from profiles where full_name = 'Aisha Khan';
  select id, auth_uid into bilal,   bilal_uid   from profiles where full_name = 'Bilal Ahmed';
  select id into hamza from profiles where full_name = 'Hamza Malik';

  -- Hamza is in Hifz and has not signed in yet in 0100; give him a session
  hamza_uid := gen_random_uuid();
  insert into auth.users (id) values (hamza_uid);
  update profiles set auth_uid = hamza_uid where id = hamza;

  -- ---------- a second school, with the same cast ----------
  insert into schools (name) values ('Other Madrasah') returning id into sch_b;
  insert into classes (school_id, name, join_code) values (sch_b, 'Their Class', 'OTHER1')
    returning id into c_b;

  insert into profiles (school_id, role, full_name, email) values
    (sch_b, 'teacher', 'Teacher B', 'tb@example.net') returning id into tb;
  insert into profiles (school_id, role, full_name, email) values
    (sch_b, 'admin',   'Admin B',   'ab@example.net') returning id into ab;
  insert into profiles (school_id, role, full_name, email) values
    (sch_b, 'parent',  'Parent B',  'pb@example.net') returning id into pb;
  insert into profiles (school_id, role, full_name, pin_hash) values
    (sch_b, 'student', 'Pupil B', 'x') returning id into kb;
  insert into auth.users (id, email) values
    (tb_uid, 'tb@example.net'), (ab_uid, 'ab@example.net'), (pb_uid, 'pb@example.net');
  insert into auth.users (id) values (kb_uid);
  update profiles set auth_uid = tb_uid where id = tb;
  update profiles set auth_uid = ab_uid where id = ab;
  update profiles set auth_uid = pb_uid where id = pb;
  update profiles set auth_uid = kb_uid where id = kb;
  insert into class_teachers values (c_b, tb);
  insert into enrolments values (c_b, kb);
  insert into guardians values (pb, kb);

  -- an anonymous session that never claimed a pupil
  insert into auth.users (id, is_anonymous) values (anon_uid, true);

  raise notice 'the approved platforms';
  perform t_assert((select count(*) from school_link_hosts where school_id = sch) = 4,
                   'an existing school starts with Zoom, Meet and the two Teams hosts');
  perform t_assert((select count(*) from school_link_hosts where school_id = sch_b) = 4,
                   'a school made later gets the same starting list');

  -- ---------- teachers write ----------
  raise notice 'a teacher setting sessions';
  perform t_be(mauluda_uid);
  set local role authenticated;

  r := t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at, link)
        values (%L, 'Qaida 1 live', now() + interval '1 day', now() + interval '1 day 1 hour',
                'https://zoom.us/j/123456789')$f$, c_q1));
  perform t_assert(r = 'ok', 'a teacher adds a session to their own class');

  select id into s_q1 from class_sessions where class_id = c_q1;
  perform t_assert((select created_by from class_sessions where id = s_q1) = mauluda,
                   'created_by is the teacher, stamped by the database');
  perform t_assert((select school_id from class_sessions where id = s_q1) = sch,
                   'school_id is the class''s school');

  r := t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at, link)
        values (%L, 'Hifz live', now() + interval '1 day', now() + interval '1 day 1 hour',
                'https://zoom.us/j/1')$f$, c_hifz));
  perform t_assert(r = '42501', 'a teacher cannot add a session to a class they do not teach');

  -- forging the school and the author does nothing
  r := t_try(format($f$insert into class_sessions (school_id, created_by, class_id, title, starts_at, ends_at)
        values (%L, %L, %L, 'Forged', now() + interval '2 days', now() + interval '2 days 1 hour')$f$,
        sch_b, abdur, c_q2));
  perform t_assert(r = 'ok', 'a session with a forged school and author is still accepted for their class');
  perform t_assert((select school_id = sch and created_by = mauluda
                    from class_sessions where title = 'Forged'),
                   'but the school and author are overwritten with the true ones');

  update class_sessions set title = 'Qaida 1 live (moved)' where id = s_q1;
  get diagnostics rc = row_count;
  perform t_assert(rc = 1, 'a teacher edits a session in their own class');

  -- a teacher moving a session into someone else's class
  r := t_try(format('update class_sessions set class_id = %L where id = %L', c_hifz, s_q1));
  perform t_assert(r = '42501', 'a teacher cannot move a session into a class they do not teach');

  delete from class_sessions where title = 'Forged';
  get diagnostics rc = row_count;
  perform t_assert(rc = 1, 'a teacher deletes a session in their own class');
  reset role;

  -- Abdur teaches Hifz
  perform t_be(abdur_uid);
  set local role authenticated;
  r := t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at, link)
        values (%L, 'Hifz circle', now() + interval '1 day', now() + interval '1 day 1 hour',
                'https://meet.google.com/abc-defg-hij')$f$, c_hifz));
  perform t_assert(r = 'ok', 'the Hifz teacher adds a Hifz session');
  select id into s_hifz from class_sessions where class_id = c_hifz;

  update class_sessions set title = 'Hijacked' where id = s_q1;
  get diagnostics rc = row_count;
  perform t_assert(rc = 0, 'a teacher cannot edit another teacher''s class session');
  delete from class_sessions where id = s_q1;
  get diagnostics rc = row_count;
  perform t_assert(rc = 0, 'and cannot delete it');
  perform t_assert(t_count(format('select 1 from class_sessions where id = %L', s_q1)) = 0,
                   'and cannot even see it');
  reset role;

  -- ---------- pupils ----------
  raise notice 'a pupil';
  perform t_be(aisha_uid);
  set local role authenticated;
  perform t_assert(t_count(format('select 1 from class_sessions where id = %L', s_q1)) = 1,
                   'a pupil sees a session for their own class, with its link');
  perform t_assert((select link from class_sessions where id = s_q1) = 'https://zoom.us/j/123456789',
                   'and the link is the one the teacher set');
  perform t_assert(t_count(format('select 1 from class_sessions where id = %L', s_hifz)) = 0,
                   'a pupil does not see another class''s session');
  perform t_assert(t_count('select 1 from class_sessions') = 1,
                   'and sees nothing else');

  r := t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at, link)
        values (%L, 'Pupil made', now(), now() + interval '1 hour', 'https://zoom.us/j/9')$f$, c_q1));
  perform t_assert(r = '42501', 'a pupil cannot create a session, even in their own class');
  update class_sessions set link = 'https://zoom.us/j/evil' where id = s_q1;
  get diagnostics rc = row_count;
  perform t_assert(rc = 0, 'a pupil cannot edit a session');
  delete from class_sessions where id = s_q1;
  get diagnostics rc = row_count;
  perform t_assert(rc = 0, 'a pupil cannot delete a session');
  perform t_assert(t_try('delete from school_link_hosts') = 'ok'
                   and (select count(*) from school_link_hosts) = 0,
                   'a pupil sees no approved platforms (and deletes nothing: nothing was visible)');
  reset role;
  perform t_assert((select count(*) from school_link_hosts where school_id = sch) = 4,
                   'the approved list is intact after a pupil tried to delete it');

  perform t_be(hamza_uid);
  set local role authenticated;
  perform t_assert(t_count(format('select 1 from class_sessions where id = %L', s_hifz)) = 1,
                   'a Hifz pupil sees the Hifz session');
  perform t_assert(t_count(format('select 1 from class_sessions where id = %L', s_q1)) = 0,
                   'and not the Qaida 1 one');
  reset role;

  -- ---------- parents ----------
  raise notice 'a parent';
  perform t_be(fatima_uid);
  set local role authenticated;
  perform t_assert(t_count(format('select 1 from class_sessions where id = %L', s_q1)) = 1,
                   'a parent sees a session for their child''s class');
  perform t_assert(t_count(format('select 1 from class_sessions where id = %L', s_hifz)) = 0,
                   'a parent does not see a class their child is not in');
  perform t_assert(t_count('select 1 from class_sessions') = 1,
                   'and sees nothing else');
  r := t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at)
        values (%L, 'Parent made', now(), now() + interval '1 hour')$f$, c_q1));
  perform t_assert(r = '42501', 'a parent cannot create a session');
  update class_sessions set title = 'Parent edit' where id = s_q1;
  get diagnostics rc = row_count;
  perform t_assert(rc = 0, 'a parent cannot edit a session');
  delete from class_sessions where id = s_q1;
  get diagnostics rc = row_count;
  perform t_assert(rc = 0, 'a parent cannot delete a session');
  reset role;

  -- ---------- admin ----------
  raise notice 'an admin';
  perform t_be(yusuf_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from class_sessions') = 2,
                   'an admin sees every session in their school');
  r := t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at, link)
        values (%L, 'Cover for Hifz', now() + interval '3 days', now() + interval '3 days 1 hour',
                'https://teams.microsoft.com/l/meetup-join/abc')$f$, c_hifz));
  perform t_assert(r = 'ok', 'an admin can set a session for any class in their school');
  select id into s_q1_by_admin from class_sessions where title = 'Cover for Hifz';
  perform t_assert((select created_by from class_sessions where id = s_q1_by_admin) = yusuf,
                   'and is recorded as its author');
  reset role;

  -- ---------- another school ----------
  raise notice 'somebody from another school';
  foreach bad in array array['teacher', 'admin', 'parent', 'pupil'] loop
    perform t_be(case bad when 'teacher' then tb_uid when 'admin' then ab_uid
                          when 'parent' then pb_uid else kb_uid end);
    set local role authenticated;
    perform t_assert(t_count('select 1 from class_sessions') = 0,
                     format('a %s at another school reads no sessions and no links', bad));
    reset role;
  end loop;

  perform t_be(tb_uid);
  set local role authenticated;
  r := t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at)
        values (%L, 'Cross school', now(), now() + interval '1 hour')$f$, c_q1));
  perform t_assert(r = '42501', 'a teacher cannot add a session to another school''s class');
  reset role;

  perform t_be(ab_uid);
  set local role authenticated;
  r := t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at)
        values (%L, 'Cross school admin', now(), now() + interval '1 hour')$f$, c_q1));
  perform t_assert(r = '42501', 'an admin cannot add a session to another school''s class');
  update class_sessions set title = 'Cross edit' where id = s_q1;
  get diagnostics rc = row_count;
  perform t_assert(rc = 0, 'an admin cannot edit another school''s session');
  delete from class_sessions where id = s_q1;
  get diagnostics rc = row_count;
  perform t_assert(rc = 0, 'an admin cannot delete another school''s session');
  perform t_assert(t_count(format('select 1 from school_link_hosts where school_id = %L', sch)) = 0,
                   'an admin cannot read another school''s approved platforms');
  r := t_try(format($f$insert into school_link_hosts values (%L, 'evil.example')$f$, sch));
  perform t_assert(r = '42501', 'an admin cannot approve a platform for another school');
  reset role;

  -- ---------- nobody, and a session that never claimed anyone ----------
  raise notice 'no one at all';
  perform t_be(null);
  set local role anon;
  perform t_assert(t_try('select * from class_sessions') = '42501',
                   'an anonymous caller is refused outright');
  perform t_assert(t_try('select * from school_link_hosts') = '42501',
                   'and cannot read the approved platforms');
  perform t_assert(t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at)
        values (%L, 'Anon', now(), now() + interval '1 hour')$f$, c_q1)) = '42501',
                   'and cannot write a session');
  reset role;

  perform t_be(anon_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from class_sessions') = 0,
                   'an anonymous session that has not claimed a pupil reads nothing');
  reset role;

  -- ---------- what a link is allowed to be ----------
  raise notice 'links';
  perform t_be(mauluda_uid);
  set local role authenticated;

  foreach bad in array array[
      'javascript:alert(1)',
      'JaVaScRiPt:alert(1)',
      'data:text/html,<script>alert(1)</script>',
      'file:///etc/passwd',
      'ftp://zoom.us/file',
      'vbscript:msgbox(1)',
      '//zoom.us/j/1',
      'zoom.us/j/1',
      'https://zoom.us@evil.example/j/1',
      'https://zoom.us:pw@evil.example/',
      'https://zoom.us.evil.example/j/1',
      'https://notzoom.us/j/1',
      'https://evil.example/zoom.us',
      'https://evil.example/?next=https://zoom.us',
      E'https://zoom.us\\@evil.example',
      'https://zoom.us/a b',
      E'https://zoom.us/j/1\n',
      ' https://zoom.us/j/1',
      'https://zoom.us/j/1 ',
      'https://',
      'https://example.com/',
      'http://localhost/j/1',
      'http://127.0.0.1/j/1',
      ''
    ] loop
    r := t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at, link)
          values (%L, 'bad link', now(), now() + interval '1 hour', %L)$f$, c_q1, bad));
    perform t_assert(r in ('23514'), format('rejected link %L (got %s)', bad, r));
  end loop;

  foreach bad in array array[
      'https://zoom.us/j/123456789?pwd=abc123',
      'HTTPS://ZOOM.US/J/1',
      'http://zoom.us/j/1',
      'https://us02web.zoom.us/j/1',
      'https://meet.google.com/abc-defg-hij',
      'https://teams.live.com/meet/9876',
      'https://zoom.us:443/j/1'
    ] loop
    r := t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at, link)
          values (%L, 'good link', now(), now() + interval '1 hour', %L)$f$, c_q1, bad));
    perform t_assert(r = 'ok', format('accepted link %L (got %s)', bad, r));
  end loop;

  perform t_assert(t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at)
        values (%L, 'no link yet', now(), now() + interval '1 hour')$f$, c_q1)) = 'ok',
        'a session may exist before it has a link');
  r := t_try(format('update class_sessions set link = %L where id = %L', 'javascript:alert(1)', s_q1));
  perform t_assert(r = '23514', 'an edit cannot swap a good link for javascript:');
  reset role;

  -- the checks hold for everyone, including a superuser and the SQL editor
  perform t_assert(t_try(format($f$insert into class_sessions (school_id, class_id, title, starts_at, ends_at, link)
        values (%L, %L, 'x', now(), now() + interval '1 hour', 'javascript:alert(1)')$f$, sch, c_q1)) = '23514',
        'javascript: is refused for a superuser too: the rule is in the table');

  -- ---------- the times ----------
  raise notice 'times';
  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert(t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at)
        values (%L, 'backwards', now() + interval '1 hour', now())$f$, c_q1)) = '23514',
        'a session cannot end before it starts');
  perform t_assert(t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at)
        values (%L, 'forever', now(), now() + interval '9 hours')$f$, c_q1)) = '23514',
        'a session cannot run longer than eight hours');
  perform t_assert(t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at)
        values (%L, '   ', now(), now() + interval '1 hour')$f$, c_q1)) = '23514',
        'a session needs a real title');
  reset role;

  -- ---------- the approved list is the school's to edit ----------
  raise notice 'the approved platforms, edited';
  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from school_link_hosts') = 4,
                   'a teacher can see which platforms their school approves');
  perform t_assert(t_try($f$insert into school_link_hosts select school_id, 'whereby.com' from profiles where auth_uid = auth.uid()$f$) = '42501',
                   'a teacher cannot add a platform');
  perform t_assert(t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at, link)
        values (%L, 'whereby', now(), now() + interval '1 hour', 'https://whereby.com/room')$f$, c_q1)) = '23514',
        'so a link to an unlisted platform is refused');
  delete from school_link_hosts;
  get diagnostics rc = row_count;
  perform t_assert(rc = 0, 'a teacher cannot remove one either');
  reset role;

  perform t_be(yusuf_uid);
  set local role authenticated;
  perform t_assert(t_try(format($f$insert into school_link_hosts values (%L, 'whereby.com')$f$, sch)) = 'ok',
                   'an admin adds a platform to their own school');
  reset role;

  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert(t_try(format($f$insert into class_sessions (class_id, title, starts_at, ends_at, link)
        values (%L, 'whereby now ok', now(), now() + interval '1 hour', 'https://whereby.com/room')$f$, c_q1)) = 'ok',
        'and a teacher can then use it');
  reset role;

  perform t_be(yusuf_uid);
  set local role authenticated;
  delete from school_link_hosts where host = 'whereby.com';
  get diagnostics rc = row_count;
  perform t_assert(rc = 1, 'an admin removes it again');
  reset role;

  perform t_be(null);
end $$;

select 'session tests finished' as result;
