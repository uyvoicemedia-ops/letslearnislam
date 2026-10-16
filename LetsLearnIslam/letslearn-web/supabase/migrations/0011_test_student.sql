-- ============================================================
-- LetsLearn — a test student, so the garden can be tried
-- ------------------------------------------------------------
-- The garden's coin economy is awkward to test honestly: the real
-- thing is earned, and a tester should not have to practise for a
-- week before seeing a mosque. The app already has a client-side
-- "test mode" (unlimited coins, full rest and food) that never
-- writes the fake balance into saved or server state.
--
-- What was missing is a pupil to be that tester, who is OBVIOUSLY
-- not a child:
--
--   * is_test on the profile, so the app can switch test mode on
--     for them and label them, and a report can leave them out.
--   * test_student_create(), an admin function that makes one
--     "Test Student" in a class of their own ("Test Class"), with a
--     known PIN, and is safe to call again.
--
-- No coins are written to the database. The balance is test mode's,
-- on the device; the points table stays a record of real children.
--
-- The PIN is 1234, the same as every seeded pupil (see SETUP.md). It
-- is printed on the admin screen, which is fine for a throwaway
-- account in a class nobody else is in. Do not put a real child in
-- the Test Class.
-- ============================================================

alter table profiles add column if not exists is_test boolean not null default false;

comment on column profiles.is_test is
  'A throwaway account for trying the app. The client switches test mode
   on for it. Only an admin (or the SQL editor) may change this.';

-- profiles has COLUMN-level select grants (0001, 0005) so the PIN hash can
-- never be read, which means a new column is invisible until it is granted.
-- Signed-in users only: an anonymous caller has no business knowing which
-- accounts are test accounts.
grant select (is_test) on profiles to authenticated;

-- "edit your own name and avatar" lets anyone update their own row, so
-- without this a pupil could flag themselves, or an admin unflag the test
-- student by accident from a stale form. auth.uid() is null in the SQL
-- editor, which is how an owner is allowed to set it directly.
create or replace function ll_test_flag_guard() returns trigger
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    if new.is_test and auth.uid() is not null and ll_role() is distinct from 'admin' then
      raise exception 'only an admin can make a test account' using errcode = '42501';
    end if;
  elsif new.is_test is distinct from old.is_test
        and auth.uid() is not null and ll_role() is distinct from 'admin' then
    raise exception 'only an admin can change a test account' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger profiles_test_flag_guard before insert or update on profiles
  for each row execute function ll_test_flag_guard();

-- One test student per school. Calling it again returns the same one.
create or replace function test_student_create()
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare
  sch uuid := ll_admin_school();
  pupil uuid; cls uuid; code text; made jsonb;
begin
  if sch is null then return jsonb_build_object('error', 'not_admin'); end if;

  select p.id into pupil from profiles p
   where p.school_id = sch and p.is_test and p.role = 'student' limit 1;

  if pupil is null then
    made := class_create('Test Class', null);
    if made ->> 'ok' is distinct from 'true' then return made; end if;
    cls := (made ->> 'id')::uuid;
    insert into profiles (school_id, role, full_name, pin_hash, is_test)
    values (sch, 'student', 'Test Student', crypt('1234', gen_salt('bf', 10)), true)
    returning id into pupil;
    insert into enrolments (class_id, pupil_id) values (cls, pupil);
  end if;

  select c.join_code into code
    from enrolments e join classes c on c.id = e.class_id
   where e.pupil_id = pupil limit 1;

  return jsonb_build_object('ok', true, 'pupil_id', pupil, 'join_code', code, 'pin', '1234');
end $$;

revoke all on function test_student_create() from public, anon;
grant execute on function test_student_create() to authenticated;
