-- ============================================================
-- The client error log (0020). Runs after 0210; reuses t_assert, t_be, t_count, t_say.
-- What must never be stored, who can write, who can read, and the limits.
-- ============================================================
do $$
declare
  sch uuid; schb uuid;
  yusuf uuid; yusuf_uid uuid; mauluda_uid uuid; fatima_uid uuid; ab_uid uuid; tb_uid uuid; aisha uuid; aisha_uid uuid; kid_uid uuid;
  j jsonb; s text; n int; r record; i int; big text;
begin
  select id into sch from schools where name = 'Al-Noor Madrasah';
  select school_id into schb from profiles where full_name = 'Admin B';
  select id, auth_uid into yusuf, yusuf_uid from profiles where full_name = 'Yusuf Ibrahim';
  select auth_uid into mauluda_uid from profiles where full_name = 'Mauluda Begum';
  select auth_uid into fatima_uid from profiles where full_name = 'Fatima Khan';
  select auth_uid into ab_uid from profiles where full_name = 'Admin B';
  select auth_uid into tb_uid from profiles where full_name = 'Teacher B';
  select id, auth_uid into aisha, aisha_uid from profiles where full_name = 'Aisha Khan';
  delete from client_errors; delete from client_error_limits;

  raise notice 'scrubbing: what must never be stored';
  s := ll_scrub('sign in failed for fatima.khan@example.com, try again', 300);
  perform t_assert(s = 'sign in failed for <email>, try again', 'an email address is removed');
  s := ll_scrub('bad token eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcDEF123_-xyz here', 300);
  perform t_assert(s = 'bad token <token> here', 'a sign-in token (JWT) is removed');
  s := ll_scrub('key sb_publishable_AbCdEf123456 and sb_secret_ZZZZ9999yyyy and sbp_0123456789abcdef0123', 300);
  perform t_assert(s not like '%AbCdEf%' and s not like '%ZZZZ9999%' and s not like '%0123456789abcdef%', 'Supabase API keys are removed');
  s := ll_scrub('GET http://localhost:8765/index.html#access_token=SECRETVALUE&type=recovery failed', 300);
  perform t_assert(s not like '%SECRETVALUE%' and s like '%failed', 'a password-reset link''s token in the address fragment is removed');
  s := ll_scrub('fetch https://abc.supabase.co/rest/v1/profiles?select=pin_hash&id=eq.5 returned 401', 300);
  perform t_assert(s not like '%pin_hash%' and s not like '%id=eq%' and s like '%returned 401', 'a URL''s query string is removed');
  s := ll_scrub('at http://x.test/app.js?v=abcdef:12:30', 300);
  perform t_assert(s not like '%abcdef%', 'also on a script URL with line numbers');
  s := ll_scrub('password=hunter2 pin: 1234 "apikey":"abc123" Authorization: Bearer abc.def', 300);
  perform t_assert(s not like '%hunter2%' and s not like '%1234%' and s not like '%abc123%' and s not like '%abc.def%', 'passwords, PINs and keys given as name=value are removed');
  perform t_assert(ll_scrub('token expired, please sign in again', 300) = 'token expired, please sign in again', 'an ordinary sentence that begins with a secret-sounding word is left alone');
  s := ll_scrub('child 3f2b8c1e-0a4d-4e7b-9c11-5d6e7f8a9b0c not found', 300);
  perform t_assert(s = 'child <id> not found', 'a UUID (a child''s id) is removed');
  s := ll_scrub('phone 07700900123 and pin 4827 were typed', 300);
  perform t_assert(s not like '%07700900123%' and s not like '%4827%', 'runs of four or more digits are removed');
  s := ll_scrub('TypeError at index.html:30829:18 and blocks:123', 300);
  perform t_assert(s like '%index.html:30829:18%' and s like '%blocks:123%', 'but line and column numbers survive');
  s := ll_scrub('Cannot read properties of undefined (reading ''map'')', 300);
  perform t_assert(s = 'Cannot read properties of undefined (reading ''map'')', 'an ordinary error message is left exactly as it was');
  perform t_assert(ll_scrub(ll_scrub('a@b.co 12345 eyJaaaaaaaaaa.bbbbbbbbbbb.ccc', 300), 300) = ll_scrub('a@b.co 12345 eyJaaaaaaaaaa.bbbbbbbbbbb.ccc', 300), 'scrubbing twice changes nothing');
  perform t_assert(length(ll_scrub(repeat('x', 5000), 300)) = 300, 'text is cut to the limit');
  perform t_assert(ll_scrub(null, 300) = '' and ll_scrub(E'a\x01\x02b', 300) = 'a b', 'null and control characters are tidied');

  raise notice 'anyone can report, and what is kept';
  set local role anon;
  perform t_be(null);
  j := log_client_error('Boom for pupil@school.test pin=9876', 'app.js:10:2', 'at f (app.js:10:2)', 'Garden', 'v1', 'Chrome/macOS');
  reset role;
  perform t_assert(j = jsonb_build_object('ok', true), 'a signed-out visitor can report an error');
  select * into r from client_errors order by id desc limit 1;
  perform t_assert(r.school_id is null and r.role is null, 'with no school and no role');
  perform t_assert(r.message = 'Boom for <email> pin=<redacted>', 'and the message was scrubbed in the database even though the caller did not');
  perform t_assert(r.page = 'garden' and r.version = 'v1' and r.browser = 'Chrome/macOS', 'the page is tidied to letters and digits only');
  perform t_be(mauluda_uid); set local role authenticated;
  j := log_client_error('Teacher side error', 'blocks.js:5:5', null, 'hours', 'v1', 'Safari/iOS');
  reset role;
  select * into r from client_errors where message = 'Teacher side error';
  perform t_assert(r.school_id = sch and r.role = 'teacher', 'a signed-in teacher''s report carries their school and their role');
  perform t_assert((select count(*) from information_schema.columns where table_name = 'client_errors' and column_name in ('auth_uid', 'user_id', 'profile_id', 'ip', 'pupil_id')) = 0,
                   'and the table has no column that could say who (no user, profile, pupil or IP)');
  perform t_assert(log_client_error('x', repeat('s', 5000), repeat('t', 100000), repeat('p', 500), repeat('v', 500), repeat('b', 500)) = jsonb_build_object('ok', true), 'huge input is accepted without an error');
  select * into r from client_errors where message = 'x';
  perform t_assert(length(r.source) <= 80 and length(r.stack) <= 1200 and length(r.page) <= 40 and length(r.version) <= 40 and length(r.browser) <= 60, 'but is cut to the limits');
  perform log_client_error('stack scrub', 'child pupil@x.test', E'at f (http://h.test/a.js?token=SECRETSTACK:1:2)\n at g pupil@x.test 12345', 'g', 'v', 'b');
  select * into r from client_errors where message = 'stack scrub';
  perform t_assert(r.stack not like '%SECRETSTACK%' and r.stack not like '%pupil@x.test%' and r.stack not like '%12345%' and r.source not like '%pupil@x.test%', 'the stack and the source are scrubbed as well as the message');
  n := (select count(*) from client_errors);
  perform log_client_error(null, 's', null, null, null, null); perform log_client_error('   ', 's', null, null, null, null);
  perform t_assert((select count(*) from client_errors) = n, 'an empty message is ignored');

  raise notice 'the same error is one row';
  delete from client_errors;
  perform t_be(mauluda_uid); set local role authenticated;
  perform log_client_error('same thing', 'a.js', 'stack one', 'garden', 'v1', 'Chrome/macOS');
  perform log_client_error('same thing', 'a.js', 'stack two', 'garden', 'v1', 'Chrome/macOS');
  perform log_client_error('same thing', 'a.js', null, 'garden', 'v1', 'Chrome/macOS');
  reset role;
  perform t_assert((select count(*) from client_errors) = 1 and (select count from client_errors) = 3, 'three reports of one error are one row with a count of 3');
  perform t_assert((select stack from client_errors) = 'stack one', 'and the first stack is kept');
  perform t_be(null); set local role anon; perform log_client_error('same thing', 'a.js', null, 'garden', 'v1', 'x'); reset role;
  perform t_assert((select count(*) from client_errors) = 2, 'the same message from a signed-out visitor is a separate row (it has no school)');
  perform t_assert((select count(*) from client_errors where school_id is null) = 1, 'exactly one of them');
  perform t_be(mauluda_uid); set local role authenticated;
  perform log_client_error('same thing', 'b.js', null, 'garden', 'v1', 'x');
  reset role;
  perform t_assert((select count(*) from client_errors) = 3, 'a different source is a different error');

  raise notice 'who can read it';
  perform t_be(yusuf_uid); set local role authenticated;
  perform t_assert(t_count('select 1 from client_errors') = 2, 'an admin reads their own school''s errors only (not the signed-out ones)');
  perform t_assert(t_count('select 1 from client_errors where school_id is null') = 0, 'none of the signed-out ones');
  reset role;
  perform t_be(ab_uid); set local role authenticated;
  perform t_assert(t_count('select 1 from client_errors') = 0, 'an admin at another school reads none');
  reset role;
  perform t_be(tb_uid); set local role authenticated;
  perform t_assert(t_count('select 1 from client_errors') = 0, 'a teacher reads none');
  reset role;
  perform t_be(fatima_uid); set local role authenticated;
  perform t_assert(t_count('select 1 from client_errors') = 0, 'a parent reads none');
  reset role;
  insert into auth.users (is_anonymous) values (true) returning id into kid_uid;
  update profiles set auth_uid = kid_uid where id = aisha;
  perform t_be(kid_uid); set local role authenticated;
  perform t_assert(t_count('select 1 from client_errors') = 0, 'a child reads none');
  perform t_assert((log_client_error('child side error', 'k.js', null, 'garden', 'v1', 'x') ->> 'ok')::boolean, 'but a child''s app can report');
  reset role;
  update profiles set auth_uid = aisha_uid where id = aisha;
  delete from auth.users where id = kid_uid;
  perform t_assert((select role from client_errors where message = 'child side error') = 'student' and (select school_id from client_errors where message = 'child side error') = sch,
                   'recorded as "a student at that school", nothing more');
  perform t_be(null); set local role anon;
  perform t_assert(t_say('select count(*) from client_errors') like '42501%', 'a signed-out visitor cannot read the table at all');
  reset role;

  raise notice 'nobody writes the table directly';
  perform t_be(yusuf_uid); set local role authenticated;
  perform t_assert(t_say($q$insert into client_errors (day, fingerprint, message) values (current_date, 'x', 'forged')$q$) like '42501%', 'a signed-in person cannot insert a row (even an admin)');
  perform t_assert(t_say('update client_errors set count = 0') like '42501%', 'or change one');
  perform t_assert(t_say('delete from client_errors') like '42501%', 'or delete one');
  perform t_assert(t_say('select count(*) from client_error_limits') like '42501%', 'the limits table is shut');
  perform t_assert(t_say('select client_errors_purge()') like '42501%' and t_say($q$select ll_scrub('a', 5)$q$) like '42501%', 'the purge and the scrubber are not callable');
  reset role;
  perform t_be(null); set local role anon;
  perform t_assert(t_say($q$insert into client_errors (day, fingerprint, message) values (current_date, 'x', 'forged')$q$) like '42501%', 'nor a signed-out visitor');
  reset role;

  raise notice 'the limits';
  delete from client_errors; delete from client_error_limits;
  perform t_be(mauluda_uid); set local role authenticated;
  for i in 1 .. 40 loop perform log_client_error('flood ' || i, 'f.js', null, 'g', 'v', 'b'); end loop;
  reset role;
  perform t_assert((select count(*) from client_errors) = 30, 'one signed-in person can send 30 different errors an hour, not 40');
  perform t_be(mauluda_uid); set local role authenticated;
  j := log_client_error('flood 41', 'f.js', null, 'g', 'v', 'b');
  reset role;
  perform t_assert(j = jsonb_build_object('ok', true), 'and the call past the limit still answers ok, so nothing can be learned from it');
  perform t_be(fatima_uid); set local role authenticated;
  perform log_client_error('someone else', 'f.js', null, 'g', 'v', 'b');
  reset role;
  perform t_assert((select count(*) from client_errors where message = 'someone else') = 1, 'another person''s allowance is separate');
  delete from client_errors; delete from client_error_limits;
  perform t_be(null); set local role anon;
  for i in 1 .. 70 loop perform log_client_error('anon flood ' || i, 'f.js', null, 'g', 'v', 'b'); end loop;
  reset role;
  perform t_assert((select count(*) from client_errors) = 60, 'all signed-out visitors together get 60 an hour');
  delete from client_errors; delete from client_error_limits;
  insert into client_error_limits (key, hour, n) values ('all', date_trunc('hour', now()), 1000);
  perform t_be(mauluda_uid); set local role authenticated;
  perform log_client_error('project wide', 'f.js', null, 'g', 'v', 'b');
  reset role;
  perform t_assert((select count(*) from client_errors) = 0, 'and the whole project, 1,000 an hour');
  delete from client_error_limits;
  insert into client_errors (school_id, day, fingerprint, message)
    select sch, (now() at time zone 'Europe/London')::date, md5('pad ' || g || '|'), 'pad ' || g from generate_series(1, 500) g;
  perform t_be(mauluda_uid); set local role authenticated;
  perform log_client_error('a new one past the daily cap', 'f.js', null, 'g', 'v', 'b');
  perform log_client_error('pad 7', null, null, 'g', 'v', 'b');
  reset role;
  perform t_assert(not exists (select 1 from client_errors where message = 'a new one past the daily cap'), 'a school at 500 different errors a day stops getting new ones');
  perform t_assert((select count from client_errors where message = 'pad 7') = 2, 'but one it already knows still counts up');
  delete from client_errors; delete from client_error_limits;

  raise notice 'keeping it for 30 days';
  insert into client_errors (school_id, day, fingerprint, message, last_at) values
    (sch, current_date - 40, 'old', 'old error', now() - interval '40 days'), (sch, current_date - 5, 'recent', 'recent error', now() - interval '5 days');
  insert into client_error_limits (key, hour, n) values ('anon', now() - interval '3 days', 5), ('anon', date_trunc('hour', now()), 5);
  perform client_errors_purge();
  perform t_assert(not exists (select 1 from client_errors where message = 'old error') and exists (select 1 from client_errors where message = 'recent error'), 'older than 30 days goes, recent stays');
  perform t_assert((select count(*) from client_error_limits) = 1, 'and old limit counters go');

  raise notice 'the plumbing';
  perform t_assert((select prosecdef from pg_proc where proname = 'log_client_error') and (select proconfig::text from pg_proc where proname = 'log_client_error') like '%search_path=public, pg_temp%',
                   'the door is security definer with a pinned search_path');
  perform t_assert(has_function_privilege('anon', 'log_client_error(text,text,text,text,text,text)', 'execute') and has_function_privilege('authenticated', 'log_client_error(text,text,text,text,text,text)', 'execute'),
                   'and open to both, by design');
  perform t_assert(not has_function_privilege('anon', 'client_errors_purge()', 'execute') and not has_function_privilege('authenticated', 'client_errors_purge()', 'execute'), 'the purge is not');
  perform t_assert((select relrowsecurity from pg_class where relname = 'client_errors') and (select relrowsecurity from pg_class where relname = 'client_error_limits'), 'row-level security is on for both tables');
  delete from client_errors; delete from client_error_limits;
  perform t_be(null);
end $$;
