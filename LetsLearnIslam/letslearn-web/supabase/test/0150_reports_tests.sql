-- ============================================================
-- Report recipients and the report log: admin-only, school-scoped,
-- and the log can only grow.
-- Runs after 0140; reuses t_assert, t_be, t_count, t_say.
-- ============================================================
do $$
declare
  sch uuid; yusuf uuid; yusuf_uid uuid; mauluda_uid uuid; aisha_uid uuid; fatima_uid uuid;
  ab uuid; ab_uid uuid; tb_uid uuid; rc int; lid uuid;
begin
  select id into sch from schools where name = 'Al-Noor Madrasah';
  select id, auth_uid into yusuf, yusuf_uid from profiles where full_name = 'Yusuf Ibrahim';
  select auth_uid into mauluda_uid from profiles where full_name = 'Mauluda Begum';
  select auth_uid into aisha_uid from profiles where full_name = 'Aisha Khan';
  select auth_uid into fatima_uid from profiles where full_name = 'Fatima Khan';
  select id, auth_uid into ab, ab_uid from profiles where full_name = 'Admin B';
  select auth_uid into tb_uid from profiles where full_name = 'Teacher B';

  perform t_be(yusuf_uid);
  set local role authenticated;
  perform t_assert(t_say(format($f$insert into report_recipients (school_id, name, email, role)
        values (%L, 'Accountant', 'books@example.org', 'Accountant')$f$, sch)) = 'ok', 'an admin adds a recipient');
  perform t_assert(t_say(format($f$insert into report_recipients (school_id, name, email) values (%L, 'Dup', 'BOOKS@example.org')$f$, sch)) like '23505%',
                   'the same address twice (any case) is refused');
  foreach rc in array array[1, 2, 3, 4] loop
    perform t_assert(t_say(format($f$insert into report_recipients (school_id, name, email) values (%L, 'X', %L)$f$, sch,
        (array['not-an-address', 'a b@example.org', 'a@b', '@example.org'])[rc])) like '23514%',
        'a malformed address is refused: ' || (array['not-an-address', 'a b@example.org', 'a@b', '@example.org'])[rc]);
  end loop;
  perform t_assert(t_say(format($f$insert into report_recipients (school_id, name, email) values (%L, '   ', 'x@example.org')$f$, sch)) like '23514%',
                   'a recipient needs a name');
  perform t_assert(t_say(format($f$insert into report_log (school_id, report, format, action, by_id)
        values (%L, 'Salary report', 'csv', 'downloaded', %L)$f$, sch, yusuf)) = 'ok', 'an admin logs a download');
  perform t_assert(t_say(format($f$insert into report_log (school_id, report, format, action, by_id)
        values (%L, 'Salary report', 'csv', 'delivered', %L)$f$, sch, yusuf)) like '23514%',
        'there is no "delivered" status: nothing here can know that');
  perform t_assert(t_say(format($f$insert into report_log (school_id, report, format, action, by_id)
        values (%L, 'Salary report', 'csv', 'downloaded', %L)$f$, sch, ab)) like '42501%',
        'and the log cannot be written in somebody else''s name');
  select id into lid from report_log limit 1;
  update report_log set report = 'Edited' where id = lid;
  get diagnostics rc = row_count;
  perform t_assert(rc = 0, 'a log entry cannot be rewritten, even by an admin');
  delete from report_log where id = lid;
  get diagnostics rc = row_count;
  perform t_assert(rc = 0, 'or deleted');
  perform t_assert(t_count('select 1 from report_recipients') = 1 and t_count('select 1 from report_log') = 1, 'an admin reads both');
  delete from report_recipients;
  get diagnostics rc = row_count;
  perform t_assert(rc = 1, 'an admin can remove a recipient');
  insert into report_recipients (school_id, name, email) values (sch, 'Accountant', 'books@example.org');
  reset role;

  raise notice 'everyone else';
  perform t_be(mauluda_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from report_recipients') = 0 and t_count('select 1 from report_log') = 0, 'a teacher sees no recipients and no log');
  perform t_assert(t_say(format($f$insert into report_recipients (school_id, name, email) values (%L, 'Me', 'me@example.org')$f$, sch)) like '42501%',
                   'and cannot add one (that is how payroll reaches a stranger)');
  reset role;
  foreach rc in array array[1, 2, 3, 4] loop
    perform t_be(case rc when 1 then aisha_uid when 2 then fatima_uid when 3 then tb_uid else ab_uid end);
    set local role authenticated;
    perform t_assert(t_count('select 1 from report_recipients') = 0 and t_count('select 1 from report_log') = 0,
                     'nothing for ' || (array['a pupil', 'a parent', 'a teacher at another school', 'an admin at another school'])[rc]);
    reset role;
  end loop;
  perform t_be(ab_uid);
  set local role authenticated;
  perform t_assert(t_say(format($f$insert into report_recipients (school_id, name, email) values (%L, 'Spy', 'spy@example.org')$f$, sch)) like '42501%',
                   'an admin cannot add a recipient to another school');
  reset role;
  perform t_be(null);
  set local role anon;
  perform t_assert(t_say('select * from report_recipients') like '42501%' and t_say('select * from report_log') like '42501%', 'an anonymous caller is refused');
  reset role;
  perform t_be(null);
end $$;
select 'report tests finished' as result;
