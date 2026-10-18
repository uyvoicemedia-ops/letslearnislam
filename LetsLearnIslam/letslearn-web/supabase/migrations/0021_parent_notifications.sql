-- ============================================================
-- LetsLearn — emails to parents, only if everyone said yes
-- ------------------------------------------------------------
-- This file is the DATABASE half. It decides who may be told what, writes
-- the message into an outbox, and nothing else. It sends nothing: a small
-- scheduled function (supabase/functions/notify-send) reads the outbox and
-- is itself switched to "dry run" until you turn real sending on.
--
-- Three separate yeses are needed before one email is even queued:
--
--   1. THE SCHOOL. An admin switches parent emails on for the school
--      (notify_school_set). Off by default. Nothing queues while it is off.
--   2. THE PARENT. Each parent switches each kind of message on for
--      themselves (notify_prefs_set). Off by default: nobody is signed up
--      by being on a roster. Every email carries a one-click unsubscribe.
--   3. A CONFIRMED ADDRESS. The parent's sign-in email must be confirmed.
--      That only means something once Supabase's "Confirm email" is ON, so
--      docs/notifications.md makes that step one of the go-live checklist.
--      This migration also makes roster linking wait for that
--      confirmation (below), so a stranger who types a parent's email at
--      sign-up can no longer become that parent.
--
-- What an email says is deliberately small: the child's FIRST name, the
-- class, a date. Never a score, never a coin reason, never a meeting link
-- (an online lesson says when, and to open the app), never bank details.
-- Teacher-written homework titles are cut to 80 characters and any web
-- address in them is replaced.
--
-- Kinds: absence, homework, fees, session. (test is for the admin's own
-- address, to check the pipe.) Quiet hours: nothing is sent between 21:00
-- and 07:00 London; it waits until 07:30. Each parent gets at most 8 a day.
-- The same event never queues twice for the same parent.
--
-- Nobody signed in can write to any of these tables. The outbox holds
-- addresses only by reference: the sender function looks the address up
-- at send time and sees it only then.
-- ============================================================

-- ---------- sign-up linking waits for a confirmed email ----------
-- (This closes the hole noted in the build notes: the trigger used to link
-- on INSERT, before the address had been proved. With "Confirm email" ON a
-- new account is unconfirmed at insert; it is linked when the address is
-- confirmed. With it OFF, accounts are confirmed at insert and nothing
-- changes, which is exactly why it must be ON before real families.)
create or replace function ll_link_new_user() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.email_confirmed_at is null then return new; end if;
  update profiles
     set auth_uid = new.id
   where email is not null
     and lower(email) = lower(new.email)
     and auth_uid is null
     and role <> 'student';
  return new;
end;
$$;

drop trigger if exists on_auth_user_confirmed on auth.users;
create trigger on_auth_user_confirmed
  after update of email_confirmed_at on auth.users
  for each row when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
  execute function ll_link_new_user();

-- ---------- tables ----------
do $$ begin
  create type notify_event as enum ('absence', 'homework', 'fees', 'session', 'test');
exception when duplicate_object then null; end $$;

create table if not exists notify_school_settings (
  school_id  uuid primary key references schools(id) on delete cascade,
  enabled    boolean not null default false,
  changed_by uuid references profiles(id) on delete set null,
  changed_at timestamptz not null default now()
);

create table if not exists notify_prefs (
  parent_id  uuid not null references profiles(id) on delete cascade,
  event      notify_event not null check (event <> 'test'),
  enabled    boolean not null,
  updated_at timestamptz not null default now(),
  primary key (parent_id, event)
);

create table if not exists notify_outbox (
  id          bigint generated always as identity primary key,
  school_id   uuid not null references schools(id) on delete cascade,
  parent_id   uuid not null references profiles(id) on delete cascade,
  event       notify_event not null,
  dedupe_key  text not null,
  subject     text not null check (length(subject) <= 200),
  body        text not null check (length(body) <= 2000),
  unsub_token text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  state       text not null default 'queued' check (state in ('queued', 'sending', 'sent', 'dry', 'failed', 'skipped')),
  attempts    int not null default 0,
  last_error  text,
  created_at  timestamptz not null default now(),
  send_after  timestamptz not null default now(),
  claimed_at  timestamptz,
  sent_at     timestamptz,
  unique (parent_id, dedupe_key)
);
create index if not exists notify_outbox_due on notify_outbox (state, send_after);
create index if not exists notify_outbox_school on notify_outbox (school_id, created_at desc);
create unique index if not exists notify_outbox_token on notify_outbox (unsub_token);

alter table notify_school_settings enable row level security;
alter table notify_prefs enable row level security;
alter table notify_outbox enable row level security;
revoke all on notify_school_settings, notify_prefs, notify_outbox from anon, authenticated;
-- a parent may read their own history, minus the token and the body of other people's mail
grant select (id, event, subject, state, created_at, sent_at) on notify_outbox to authenticated;
grant select on notify_prefs to authenticated;
grant select on notify_school_settings to authenticated;

drop policy if exists "read your own notification history" on notify_outbox;
create policy "read your own notification history" on notify_outbox
  for select using (parent_id = ll_me());
drop policy if exists "read your own notification choices" on notify_prefs;
create policy "read your own notification choices" on notify_prefs
  for select using (parent_id = ll_me());
drop policy if exists "admins read their school's switch" on notify_school_settings;
create policy "admins read their school's switch" on notify_school_settings
  for select using (ll_role() = 'admin' and school_id = ll_school());

-- ---------- who may be told ----------
create or replace function ll_notify_ok(p_school uuid, p_parent uuid, p_event notify_event) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from notify_school_settings s where s.school_id = p_school and s.enabled)
     and exists (select 1 from notify_prefs np where np.parent_id = p_parent and np.event = p_event and np.enabled)
     and exists (select 1 from profiles p join auth.users u on u.id = p.auth_uid
                 where p.id = p_parent and p.role = 'parent' and p.email is not null
                   and lower(u.email) = lower(p.email) and u.email_confirmed_at is not null
                   and coalesce(u.is_anonymous, false) = false);
$$;

-- nothing between 21:00 and 07:00 London; it waits for 07:30
create or replace function ll_notify_when() returns timestamptz
language sql stable set search_path = public, pg_temp as $$
  select case
    when extract(hour from (now() at time zone 'Europe/London')) >= 21
      then (((now() at time zone 'Europe/London')::date + 1) + time '07:30') at time zone 'Europe/London'
    when extract(hour from (now() at time zone 'Europe/London')) < 7
      then ((now() at time zone 'Europe/London')::date + time '07:30') at time zone 'Europe/London'
    else now() end;
$$;

create or replace function ll_notify_clean(p text, p_max int) returns text
language sql immutable set search_path = public, pg_temp as $$
  select left(btrim(regexp_replace(regexp_replace(coalesce(p, ''), '(https?://|www\.)\S+', '<link>', 'gi'), '[\r\n\t]+', ' ', 'g')), p_max);
$$;

create or replace function ll_notify_enqueue(p_school uuid, p_parent uuid, p_event notify_event, p_key text, p_subject text, p_body text) returns void
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare today int;
begin
  if not ll_notify_ok(p_school, p_parent, p_event) then return; end if;
  select count(*) into today from notify_outbox
   where parent_id = p_parent and event <> 'test'
     and (created_at at time zone 'Europe/London')::date = (now() at time zone 'Europe/London')::date;
  if today >= 8 then return; end if;                                  -- at most 8 a day
  insert into notify_outbox (school_id, parent_id, event, dedupe_key, subject, body, send_after)
    values (p_school, p_parent, p_event, p_key, left(p_subject, 200), left(p_body, 2000), ll_notify_when())
    on conflict (parent_id, dedupe_key) do nothing;
end $$;

-- ---------- what triggers a message ----------
-- None of these may ever stop the thing that triggered them: a teacher
-- marking the register must not fail because an email could not be queued.

create or replace function ll_notify_on_attendance() returns trigger
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare pu profiles%rowtype; cn text; g record;
begin
  if new.mark <> 'absent' or new.on_date < current_date - 1 then return new; end if;   -- not a note about last week
  if tg_op = 'UPDATE' and old.mark is not distinct from new.mark then return new; end if;
  select * into pu from profiles where id = new.pupil_id;
  select name into cn from classes where id = new.class_id;
  for g in select parent_id from guardians where pupil_id = new.pupil_id loop
    perform ll_notify_enqueue(pu.school_id, g.parent_id, 'absence', 'absence:' || new.pupil_id || ':' || new.on_date,
      split_part(btrim(pu.full_name), ' ', 1) || ' was marked absent',
      split_part(btrim(pu.full_name), ' ', 1) || ' was marked absent from ' || coalesce(cn, 'class') || ' on '
        || to_char(new.on_date, 'FMDay FMDD FMMonth') || E'.\n\nIf this is a mistake, please tell the madrasah.');
  end loop;
  return new;
exception when others then return new;
end $$;

create or replace function ll_notify_on_homework() returns trigger
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare cn text; sch uuid; g record;
begin
  if new.due_on is not null and new.due_on < current_date then return new; end if;
  select name, school_id into cn, sch from classes where id = new.class_id;
  for g in select distinct gu.parent_id from enrolments e join guardians gu on gu.pupil_id = e.pupil_id where e.class_id = new.class_id loop
    perform ll_notify_enqueue(sch, g.parent_id, 'homework', 'homework:' || new.id,
      'New homework for ' || coalesce(cn, 'class'),
      'New homework for ' || coalesce(cn, 'class') || ': ' || ll_notify_clean(new.title, 80)
        || case when new.due_on is not null then E'\nDue ' || to_char(new.due_on, 'FMDay FMDD FMMonth') else '' end
        || E'.\n\nOpen the app to see the details.');
  end loop;
  return new;
exception when others then return new;
end $$;

create or replace function ll_notify_on_session() returns trigger
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare cn text; g record;
begin
  if new.starts_at < now() then return new; end if;
  select name into cn from classes where id = new.class_id;
  for g in select distinct gu.parent_id from enrolments e join guardians gu on gu.pupil_id = e.pupil_id where e.class_id = new.class_id loop
    perform ll_notify_enqueue(new.school_id, g.parent_id, 'session', 'session:' || new.id,
      'An online lesson for ' || coalesce(cn, 'class'),
      'An online lesson for ' || coalesce(cn, 'class') || ' is on '
        || to_char(new.starts_at at time zone 'Europe/London', 'FMDay FMDD FMMonth') || ' at '
        || to_char(new.starts_at at time zone 'Europe/London', 'HH24:MI')
        || E'.\n\nOpen the app to join. The link is not in this email.');
  end loop;
  return new;
exception when others then return new;
end $$;

create or replace function ll_notify_on_fee() returns trigger
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare amt text := to_char(new.amount_pence / 100.0, 'FM999990.00');
begin
  if tg_op = 'INSERT' and new.status = 'pending' then
    perform ll_notify_enqueue(new.school_id, new.payer_id, 'fees', 'fee:' || new.id || ':pending',
      'A fee is due',
      'A fee of £' || amt || coalesce(' for ' || ll_notify_clean(new.period, 40), '')
        || case when new.charge_date is not null then ' will be collected on ' || to_char(new.charge_date, 'FMDay FMDD FMMonth') else ' is due' end
        || E'.\n\nOpen the app to see the details.');
  elsif tg_op = 'UPDATE' and new.status = 'failed' and old.status is distinct from new.status then
    perform ll_notify_enqueue(new.school_id, new.payer_id, 'fees', 'fee:' || new.id || ':failed',
      'A payment could not be collected',
      'A payment of £' || amt || coalesce(' for ' || ll_notify_clean(new.period, 40), '')
        || E' could not be collected.\n\nPlease open the app, or contact the madrasah.');
  end if;
  return new;
exception when others then return new;
end $$;

drop trigger if exists ll_notify_attendance on attendance;
create trigger ll_notify_attendance after insert or update of mark on attendance for each row execute function ll_notify_on_attendance();
drop trigger if exists ll_notify_homework on homework;
create trigger ll_notify_homework after insert on homework for each row execute function ll_notify_on_homework();
drop trigger if exists ll_notify_session on class_sessions;
create trigger ll_notify_session after insert on class_sessions for each row execute function ll_notify_on_session();
drop trigger if exists ll_notify_fee on fee_charges;
create trigger ll_notify_fee after insert or update of status on fee_charges for each row execute function ll_notify_on_fee();

-- ---------- the parent's side ----------
create or replace function notify_prefs_get() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare me uuid := ll_me(); p profiles%rowtype; u record; masked text; verified boolean := false; sch boolean;
begin
  if me is null or not coalesce(ll_adult_session(), false) then return jsonb_build_object('error', 'not_allowed'); end if;
  select * into p from profiles where id = me;
  if p.role <> 'parent' then return jsonb_build_object('error', 'not_allowed'); end if;
  select email, email_confirmed_at into u from auth.users where id = auth.uid();
  if p.email is not null then
    masked := left(split_part(p.email, '@', 1), 1) || '***@' || split_part(p.email, '@', 2);
    verified := u.email_confirmed_at is not null and lower(u.email) = lower(p.email);
  end if;
  select exists (select 1 from guardians g join profiles pu on pu.id = g.pupil_id
                 join notify_school_settings s on s.school_id = pu.school_id and s.enabled
                 where g.parent_id = me) into sch;
  return jsonb_build_object(
    'email', masked, 'verified', verified, 'school_enabled', sch,
    'prefs', jsonb_build_object(
      'absence',  coalesce((select enabled from notify_prefs where parent_id = me and event = 'absence'), false),
      'homework', coalesce((select enabled from notify_prefs where parent_id = me and event = 'homework'), false),
      'fees',     coalesce((select enabled from notify_prefs where parent_id = me and event = 'fees'), false),
      'session',  coalesce((select enabled from notify_prefs where parent_id = me and event = 'session'), false)));
end $$;

create or replace function notify_prefs_set(p_event text, p_enabled boolean) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare me uuid := ll_me();
begin
  if me is null or not coalesce(ll_adult_session(), false) or ll_role() <> 'parent' then return jsonb_build_object('error', 'not_allowed'); end if;
  if p_event is null or p_event not in ('absence', 'homework', 'fees', 'session') or p_enabled is null then return jsonb_build_object('error', 'bad_event'); end if;
  insert into notify_prefs (parent_id, event, enabled) values (me, p_event::notify_event, p_enabled)
    on conflict (parent_id, event) do update set enabled = excluded.enabled, updated_at = now();
  return jsonb_build_object('ok', true, 'event', p_event, 'enabled', p_enabled);
end $$;

-- one click from the email, no sign-in: it can only switch THAT kind off for THAT parent,
-- and it answers the same for a bad token as for a good one
create or replace function notify_unsubscribe(p_token text) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare r record;
begin
  if p_token is not null and length(p_token) = 64 and p_token ~ '^[0-9a-f]+$' then
    select parent_id, event into r from notify_outbox where unsub_token = p_token;
    if found and r.event <> 'test' then
      insert into notify_prefs (parent_id, event, enabled) values (r.parent_id, r.event, false)
        on conflict (parent_id, event) do update set enabled = false, updated_at = now();
    end if;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- the admin's side ----------
create or replace function notify_school_set(p_enabled boolean) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare me uuid := ll_me(); sch uuid := ll_school();
begin
  if ll_role() <> 'admin' or sch is null or not coalesce(ll_adult_session(), false) then return jsonb_build_object('error', 'not_allowed'); end if;
  if p_enabled is null then return jsonb_build_object('error', 'bad_value'); end if;
  insert into notify_school_settings (school_id, enabled, changed_by) values (sch, p_enabled, me)
    on conflict (school_id) do update set enabled = excluded.enabled, changed_by = me, changed_at = now();
  if not p_enabled then                                               -- switching off also empties the queue
    update notify_outbox set state = 'skipped', last_error = 'school_off' where school_id = sch and state in ('queued', 'sending');
  end if;
  return jsonb_build_object('ok', true, 'enabled', p_enabled);
end $$;

create or replace function notify_school_status() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare sch uuid := ll_school();
begin
  if ll_role() <> 'admin' or sch is null then return jsonb_build_object('error', 'not_allowed'); end if;
  return jsonb_build_object(
    'enabled', coalesce((select enabled from notify_school_settings where school_id = sch), false),
    'counts', (select coalesce(jsonb_object_agg(state, n), '{}'::jsonb) from
                 (select state, count(*) n from notify_outbox where school_id = sch and created_at > now() - interval '7 days' group by state) c),
    'opted_in', (select coalesce(jsonb_object_agg(event, n), '{}'::jsonb) from
                 (select np.event, count(*) n from notify_prefs np join profiles p on p.id = np.parent_id
                  where np.enabled and (p.school_id = sch or exists (select 1 from guardians g join profiles pu on pu.id = g.pupil_id where g.parent_id = p.id and pu.school_id = sch))
                  group by np.event) o),
    'failures', (select coalesce(jsonb_agg(jsonb_build_object('event', event, 'at', created_at, 'error', left(coalesce(last_error, ''), 120)) order by created_at desc), '[]'::jsonb) from
                 (select event, created_at, last_error from notify_outbox where school_id = sch and state = 'failed' order by created_at desc limit 10) f));
end $$;

-- a test email to the admin's OWN confirmed address, to check the whole pipe before any parent is involved
create or replace function notify_send_test() returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare me uuid := ll_me(); sch uuid := ll_school(); p profiles%rowtype; ok boolean;
begin
  if ll_role() <> 'admin' or sch is null or not coalesce(ll_adult_session(), false) then return jsonb_build_object('error', 'not_allowed'); end if;
  if not coalesce((select enabled from notify_school_settings where school_id = sch), false) then return jsonb_build_object('error', 'school_off'); end if;
  select * into p from profiles where id = me;
  select exists (select 1 from auth.users u where u.id = auth.uid() and p.email is not null and lower(u.email) = lower(p.email) and u.email_confirmed_at is not null) into ok;
  if not ok then return jsonb_build_object('error', 'email_not_confirmed'); end if;
  insert into notify_outbox (school_id, parent_id, event, dedupe_key, subject, body, send_after)
    values (sch, me, 'test', 'test:' || me || ':' || extract(epoch from now())::bigint, 'Test email from LetsLearn',
            E'This is a test. If you can read it, parent emails can reach a confirmed address.\n\nNo child is mentioned.', now());
  return jsonb_build_object('ok', true);
end $$;

-- ---------- the sender's side: the service role only ----------
create or replace function notify_claim_batch(p_limit int)
returns table (id bigint, to_email text, to_name text, subject text, body text, unsub_token text, event notify_event)
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  -- tidy: forget mail older than 90 days; give up on a send that has been stuck for 15 minutes
  delete from notify_outbox o where o.created_at < now() - interval '90 days';
  update notify_outbox o set state = case when o.attempts >= 5 then 'failed' else 'queued' end,
         last_error = coalesce(o.last_error, 'stuck sending')
   where o.state = 'sending' and o.claimed_at < now() - interval '15 minutes';

  -- re-check the three yeses at the moment of sending: a parent who opted out, or a school that
  -- switched off, an hour ago must not be emailed now
  update notify_outbox o set state = 'skipped', last_error = 'no_longer_allowed'
   where o.state = 'queued' and o.send_after <= now() and o.event <> 'test'
     and not ll_notify_ok(o.school_id, o.parent_id, o.event);
  update notify_outbox o set state = 'skipped', last_error = 'no_longer_allowed'
   where o.state = 'queued' and o.send_after <= now() and o.event = 'test'
     and not exists (select 1 from notify_school_settings s where s.school_id = o.school_id and s.enabled);

  return query
  with due as (
    select o.id from notify_outbox o
     where o.state = 'queued' and o.send_after <= now()
     order by o.send_after, o.id
     limit greatest(1, least(coalesce(p_limit, 25), 100))
     for update skip locked),
  mark as (
    update notify_outbox o set state = 'sending', claimed_at = now(), attempts = o.attempts + 1
      from due where o.id = due.id returning o.*)
  select m.id, p.email, p.full_name, m.subject, m.body, m.unsub_token, m.event
    from mark m join profiles p on p.id = m.parent_id
   where p.email is not null;
end $$;

create or replace function notify_mark(p_id bigint, p_result text, p_error text) returns void
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare a int;
begin
  select attempts into a from notify_outbox where id = p_id and state = 'sending';
  if not found then return; end if;
  if p_result = 'sent' then update notify_outbox set state = 'sent', sent_at = now(), last_error = null where id = p_id;
  elsif p_result = 'dry' then update notify_outbox set state = 'dry', last_error = null where id = p_id;
  elsif p_result = 'retry' and a < 5 then
    update notify_outbox set state = 'queued', send_after = now() + make_interval(mins => 5 * a * a), last_error = left(coalesce(p_error, ''), 200) where id = p_id;
  else update notify_outbox set state = 'failed', last_error = left(coalesce(p_error, 'failed'), 200) where id = p_id;
  end if;
end $$;

-- ---------- who may call what ----------
revoke all on function ll_notify_ok(uuid, uuid, notify_event), ll_notify_when(), ll_notify_clean(text, int),
  ll_notify_enqueue(uuid, uuid, notify_event, text, text, text),
  ll_notify_on_attendance(), ll_notify_on_homework(), ll_notify_on_session(), ll_notify_on_fee(),
  notify_claim_batch(int), notify_mark(bigint, text, text) from public, anon, authenticated;
revoke all on function notify_prefs_get(), notify_prefs_set(text, boolean), notify_school_set(boolean),
  notify_school_status(), notify_send_test() from public, anon;
grant execute on function notify_prefs_get(), notify_prefs_set(text, boolean), notify_school_set(boolean),
  notify_school_status(), notify_send_test() to authenticated;
revoke all on function notify_unsubscribe(text) from public;
grant execute on function notify_unsubscribe(text) to anon, authenticated;
grant execute on function notify_claim_batch(int), notify_mark(bigint, text, text) to service_role;
