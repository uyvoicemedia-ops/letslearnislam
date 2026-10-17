-- ============================================================
-- Which books a pupil is given: who may give them, and who may see
-- what was given. Runs after 0150; reuses t_assert, t_be, t_count, t_say.
-- ============================================================
do $$
declare
  sch uuid; mauluda_uid uuid; abdur_uid uuid; yusuf_uid uuid; aisha uuid; aisha_uid uuid; bilal uuid; bilal_uid uuid;
  hamza uuid; fatima_uid uuid; ab_uid uuid; tb_uid uuid; kb uuid; kb_uid uuid; anon_uid uuid := gen_random_uuid();
  j jsonb; rc int;
begin
  select id into sch from schools where name = 'Al-Noor Madrasah';
  select auth_uid into mauluda_uid from profiles where full_name = 'Mauluda Begum';
  select auth_uid into abdur_uid   from profiles where full_name = 'Abdur Rahman';
  select auth_uid into yusuf_uid   from profiles where full_name = 'Yusuf Ibrahim';
  select id, auth_uid into aisha, aisha_uid from profiles where full_name = 'Aisha Khan';
  select id, auth_uid into bilal, bilal_uid from profiles where full_name = 'Bilal Ahmed';
  select id into hamza from profiles where full_name = 'Hamza Malik';
  select auth_uid into fatima_uid from profiles where full_name = 'Fatima Khan';
  select auth_uid into ab_uid from profiles where full_name = 'Admin B';
  select auth_uid into tb_uid from profiles where full_name = 'Teacher B';
  select id, auth_uid into kb, kb_uid from profiles where full_name = 'Pupil B';
  insert into auth.users (id, is_anonymous) values (anon_uid, true);
  -- Bilal needs a session to be tested as a pupil
  if bilal_uid is null then bilal_uid := gen_random_uuid(); insert into auth.users (id) values (bilal_uid); update profiles set auth_uid = bilal_uid where id = bilal; end if;

  raise notice 'a teacher giving books';
  perform t_be(mauluda_uid);
  set local role authenticated;
  j := pupil_books_set(aisha, array['qaida-1']);
  perform t_assert((j ->> 'ok')::boolean and (j ->> 'books')::int = 1, 'a teacher gives their pupil the first Qaida book');
  perform t_assert((pupil_books_set(hamza, array['qaida-1']) ->> 'error') = 'not_allowed', 'but not a pupil they do not teach');
  j := pupil_books_toggle(array[aisha, bilal, hamza], 'qaida-2', true);
  perform t_assert((j ->> 'changed')::int = 2 and (j ->> 'skipped')::int = 1, 'a whole column: two of their pupils get it, the third is skipped and counted');
  perform t_assert((select count(*) from pupil_books where pupil_id = aisha) = 2 and (select count(*) from pupil_books where pupil_id = bilal) = 1, 'Aisha has two books, Bilal one');
  j := pupil_books_set(aisha, array['qaida-1', 'qaida-1', 'islam-1']);
  perform t_assert((j ->> 'books')::int = 2, 'a repeated book is one book; the shelf is replaced, not added to');
  perform t_assert(not exists (select 1 from pupil_books where pupil_id = aisha and book_id = 'qaida-2'), 'qaida-2 was taken off by the replace');
  perform t_assert((pupil_books_set(aisha, array['Qaida 1!']) ->> 'error') = 'bad_book', 'a malformed book id is refused');
  perform t_assert((pupil_books_set(aisha, array(select 'b' || g from generate_series(1, 21) g)) ->> 'error') = 'too_many', 'more than 20 is refused');
  perform t_assert((pupil_books_toggle(array[aisha], 'x y', true) ->> 'error') = 'bad_book', 'so is a bad id in a toggle');
  j := pupil_books_toggle(array[aisha, bilal], 'qaida-2', false);
  perform t_assert((j ->> 'changed')::int = 2 and not exists (select 1 from pupil_books where book_id = 'qaida-2'), 'taking a book back from a column works');
  perform t_assert(t_say(format($f$insert into pupil_books (pupil_id, book_id) values (%L, 'qaida-4')$f$, aisha)) like '42501%', 'a teacher cannot write the table directly');
  perform t_assert(t_say('delete from pupil_books') like '42501%', 'or delete from it');
  perform t_assert((select count(*) from pupil_books) = 2, 'a teacher sees only their own pupils'' rows (Aisha 2, Bilal 0 after the take-back = 2)');
  reset role;

  raise notice 'another teacher';
  perform t_be(abdur_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from pupil_books where pupil_id in (select id from profiles where full_name in (''Aisha Khan'', ''Bilal Ahmed''))') = 0,
                   'a teacher of another class sees none of Mauluda''s pupils'' books');
  perform t_assert((pupil_books_set(aisha, array['qaida-4']) ->> 'error') = 'not_allowed', 'and cannot change them');
  perform t_assert((pupil_books_set(hamza, array['islam-1', 'islam-2']) ->> 'ok')::boolean, 'but can give their own pupil books');
  reset role;

  raise notice 'pupils and parents';
  perform t_be(aisha_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from pupil_books') = 2 and t_count(format('select 1 from pupil_books where pupil_id = %L', aisha)) = 2, 'a pupil sees their own two books and nobody else''s');
  perform t_assert((pupil_books_set(aisha, array['qaida-1', 'qaida-2', 'qaida-3', 'qaida-4']) ->> 'error') = 'not_allowed', 'a pupil cannot give themselves more books');
  perform t_assert((pupil_books_toggle(array[aisha], 'qaida-4', true) ->> 'error') = 'not_allowed', 'or toggle one');
  perform t_assert(t_say(format($f$insert into pupil_books (pupil_id, book_id) values (%L, 'qaida-4')$f$, aisha)) like '42501%', 'or write the table');
  reset role;
  perform t_be(bilal_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from pupil_books') = 0, 'Bilal has been given nothing, and sees nothing');
  reset role;
  perform t_be(fatima_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from pupil_books') = 2 and t_count(format('select 1 from pupil_books where pupil_id = %L', aisha)) = 2, 'a parent sees their own child''s books, no others');
  perform t_assert((pupil_books_set(aisha, array['qaida-4']) ->> 'error') = 'not_allowed', 'and cannot change them');
  reset role;

  raise notice 'an admin';
  perform t_be(yusuf_uid);
  set local role authenticated;
  perform t_assert((pupil_books_set(bilal, array['qaida-1', 'qaida-2', 'qaida-3']) ->> 'books')::int = 3, 'an admin can give any pupil in their school books');
  perform t_assert(t_count('select 1 from pupil_books') >= 7, 'and reads the whole school''s rows');
  reset role;

  raise notice 'everyone else';
  perform t_be(ab_uid);
  set local role authenticated;
  perform t_assert((pupil_books_set(aisha, array['qaida-4']) ->> 'error') = 'not_allowed', 'an admin at another school cannot give ours books');
  perform t_assert((pupil_books_toggle(array[aisha, bilal], 'qaida-4', true) ->> 'skipped')::int = 2, 'a column across schools skips every pupil that is not theirs');
  perform t_assert(t_count('select 1 from pupil_books') = 0, 'and sees none of our rows');
  perform t_assert((pupil_books_set(kb, array['qaida-1']) ->> 'ok')::boolean, 'but can for their own pupil');
  reset role;
  perform t_be(tb_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from pupil_books') = 1 and t_count(format('select 1 from pupil_books where pupil_id = %L', kb)) = 1, 'a teacher at another school sees only their own pupil''s row, none of ours');
  reset role;
  perform t_be(kb_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from pupil_books') = 1, 'a pupil at another school sees only their own');
  reset role;
  perform t_be(anon_uid);
  set local role authenticated;
  perform t_assert(t_count('select 1 from pupil_books') = 0 and (pupil_books_set(aisha, array['qaida-1']) ->> 'error') = 'not_allowed', 'an unclaimed anonymous session sees and does nothing');
  reset role;
  perform t_be(null);
  set local role anon;
  perform t_assert(t_say('select * from pupil_books') like '42501%' and t_say(format('select pupil_books_set(%L, array[''qaida-1''])', aisha)) like '42501%', 'an anonymous caller is refused outright');
  reset role;
  perform t_be(null);
end $$;
select 'books tests finished' as result;
