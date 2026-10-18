-- Which migrations are applied? Paste into the Supabase SQL Editor and Run. Read-only: it changes nothing.
-- Every row should say true once a migration is in. The two privilege checks (0016, 0017) say true when the
-- hole is CLOSED. Rows are in the order to apply them.
select * from (values
  ('0009 class sessions',        to_regclass('public.class_sessions') is not null),
  ('0010 timetable and classes', to_regclass('public.timetable_slots') is not null),
  ('0011 test student',          exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'is_test')),
  ('0012 teacher hours',         to_regclass('public.hours_log') is not null),
  ('0013 reports',               to_regclass('public.report_log') is not null),
  ('0014 pupil books',           to_regclass('public.pupil_books') is not null),
  ('0015 homework',              to_regprocedure('public.homework_set(uuid,text,text,text,date)') is not null),
  ('0016 profiles lockdown',     not has_table_privilege('authenticated', 'public.profiles', 'insert')),
  ('0017 cross school',          not has_table_privilege('authenticated', 'public.guardians', 'insert')),
  ('0018 PIN reset',             to_regclass('public.pin_reset_audit') is not null),
  ('0019 pupil report',          to_regprocedure('public.pupil_report(uuid,date,date)') is not null),
  ('0020 client errors',         to_regclass('public.client_errors') is not null),
  ('0021 parent notifications',  to_regclass('public.notify_outbox') is not null),
  ('0022 points enum',           exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'point_source' and e.enumlabel = 'welcome')),
  ('0023 coin ledger',           to_regprocedure('public.coins_spend(integer,text,text)') is not null),
  ('0024 points enum 2',         exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'point_source' and e.enumlabel = 'salah')),
  ('0025 earning rules',         to_regprocedure('public.register_finish(uuid,date)') is not null),
  ('0026 refund pool',           to_regprocedure('public.coins_refund_pool(integer,text)') is not null)
) as t(migration, applied);
