-- ============================================================
-- LetsLearn — setting, handing in and marking homework
-- ------------------------------------------------------------
-- Until now a teacher could only READ homework counts: nothing in the
-- app could set a piece, and nothing could mark one. The tables were
-- there (0001) and a child's hand-in was written by the client, but
-- three things about the old rules had to change first.
--
--   * "staff mark work" let ANY teacher or admin update ANY submission,
--     in any class and at any school. Marking is now a function that
--     checks the caller runs that homework's class.
--   * "staff set homework" and "read homework for your classes" went
--     through ll_teaches(), whose admin branch is not scoped to a school
--     (see 0010), so an admin at one school could read, change or delete
--     another's homework. Reading is now "you run the class or you are in
--     it"; writing is only through the functions below.
--   * A child's re-do could never raise their score: the client upserted
--     a submission, but a child has no UPDATE right, so the second
--     attempt failed without a sound. homework_hand_in does it properly:
--     it keeps the better score, and never touches work that has been
--     marked.
--
-- Nobody writes homework or submissions directly any more. Each function
-- checks the caller and the class itself and returns { ok } or { error }.
--
-- A teacher marks work that has been handed in. The mark can keep the
-- child's own score (from the practice) or replace it, and carries a
-- short note the child and their parent can read.
-- ============================================================

alter table homework    add column if not exists details  text check (details  is null or length(details)  <= 500);
alter table submissions add column if not exists feedback text check (feedback is null or length(feedback) <= 300);

comment on column homework.details is 'What to do, in the teacher''s words. Especially for work with no practice linked.';
comment on column submissions.feedback is 'The teacher''s short note, shown to the child and their parent.';

drop policy if exists "staff set homework" on homework;
drop policy if exists "read homework for your classes" on homework;
drop policy if exists "hand in your own work" on submissions;
drop policy if exists "staff mark work" on submissions;

revoke all on homework, submissions from anon;
revoke insert, update, delete on homework, submissions from authenticated;

create policy "read the homework of your classes" on homework
  for select using (ll_manages_class(class_id) or ll_in_class(class_id));
-- "read submissions you may see" (0003) stays: ll_can_see_pupil already answers it.

-- the practice modules a piece of homework may be linked to
create or replace function ll_homework_module_ok(p text) returns boolean
language sql immutable as $$
  select p is null or p in ('tracing', 'mazes', 'quizzes', 'sayitback', 'reading', 'assessments', 'colouring', 'books');
$$;

create or replace function homework_set(p_class uuid, p_title text, p_details text, p_module text, p_due date)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare t text := btrim(coalesce(p_title, '')); d text := nullif(btrim(coalesce(p_details, '')), ''); new_id uuid;
begin
  if ll_role() not in ('teacher', 'admin') or not ll_manages_class(p_class) then return jsonb_build_object('error', 'not_allowed'); end if;
  if length(t) not between 1 and 120 then return jsonb_build_object('error', 'bad_title'); end if;
  if d is not null and length(d) > 500 then return jsonb_build_object('error', 'bad_details'); end if;
  if not ll_homework_module_ok(p_module) then return jsonb_build_object('error', 'bad_module'); end if;
  if p_due is not null and (p_due < current_date or p_due > current_date + 366) then return jsonb_build_object('error', 'bad_due'); end if;
  insert into homework (class_id, title, details, module_id, due_on, set_by)
  values (p_class, t, d, p_module, p_due, ll_me()) returning id into new_id;
  return jsonb_build_object('ok', true, 'id', new_id);
end $$;

create or replace function homework_update(p_id uuid, p_title text, p_details text, p_module text, p_due date)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare h homework%rowtype; t text := btrim(coalesce(p_title, '')); d text := nullif(btrim(coalesce(p_details, '')), '');
begin
  select * into h from homework where id = p_id;
  if h.id is null or ll_role() not in ('teacher', 'admin') or not ll_manages_class(h.class_id) then return jsonb_build_object('error', 'not_allowed'); end if;
  if length(t) not between 1 and 120 then return jsonb_build_object('error', 'bad_title'); end if;
  if d is not null and length(d) > 500 then return jsonb_build_object('error', 'bad_details'); end if;
  if not ll_homework_module_ok(p_module) then return jsonb_build_object('error', 'bad_module'); end if;
  -- a due date that is already past may stay as it is; changing it means a real one
  if p_due is distinct from h.due_on and p_due is not null and (p_due < current_date or p_due > current_date + 366) then
    return jsonb_build_object('error', 'bad_due');
  end if;
  update homework set title = t, details = d, module_id = p_module, due_on = p_due where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- Deleting takes the submissions with it (they reference the homework); the
-- screen says so before it asks.
create or replace function homework_delete(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare c uuid;
begin
  select class_id into c from homework where id = p_id;
  if c is null or ll_role() not in ('teacher', 'admin') or not ll_manages_class(c) then return jsonb_build_object('error', 'not_allowed'); end if;
  delete from homework where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- A pupil hands a piece in. With a score (from the practice) the better one is
-- kept; without one it is simply "I have done it". Marked work is left alone.
create or replace function homework_hand_in(p_hw uuid, p_score int default null)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare me uuid := ll_me(); c uuid; cur submissions%rowtype;
begin
  if ll_role() is distinct from 'student' or me is null then return jsonb_build_object('error', 'not_allowed'); end if;
  select class_id into c from homework where id = p_hw;
  if c is null or not exists (select 1 from enrolments e where e.class_id = c and e.pupil_id = me) then
    return jsonb_build_object('error', 'not_allowed');
  end if;
  if p_score is not null and p_score not between 0 and 100 then return jsonb_build_object('error', 'bad_score'); end if;
  select * into cur from submissions where homework_id = p_hw and pupil_id = me;
  if cur.homework_id is not null and cur.marked_at is not null then return jsonb_build_object('error', 'already_marked'); end if;
  if cur.homework_id is null then
    insert into submissions (homework_id, pupil_id, score) values (p_hw, me, p_score);
    return jsonb_build_object('ok', true, 'score', p_score);
  end if;
  update submissions set score = case when p_score is null then score else greatest(coalesce(score, 0), p_score) end
   where homework_id = p_hw and pupil_id = me returning score into p_score;
  return jsonb_build_object('ok', true, 'score', p_score);
end $$;

-- A teacher marks work that has been handed in.
create or replace function homework_mark(p_hw uuid, p_pupil uuid, p_score int, p_feedback text)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare c uuid; f text := nullif(btrim(coalesce(p_feedback, '')), '');
begin
  select class_id into c from homework where id = p_hw;
  if c is null or ll_role() not in ('teacher', 'admin') or not ll_manages_class(c) then return jsonb_build_object('error', 'not_allowed'); end if;
  if not exists (select 1 from submissions where homework_id = p_hw and pupil_id = p_pupil) then return jsonb_build_object('error', 'not_handed_in'); end if;
  if p_score is not null and p_score not between 0 and 100 then return jsonb_build_object('error', 'bad_score'); end if;
  if f is not null and length(f) > 300 then return jsonb_build_object('error', 'bad_feedback'); end if;
  update submissions set score = coalesce(p_score, score), feedback = f, marked_at = now(), marked_by = ll_me()
   where homework_id = p_hw and pupil_id = p_pupil;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function ll_homework_module_ok(text), homework_set(uuid, text, text, text, date), homework_update(uuid, text, text, text, date),
  homework_delete(uuid), homework_hand_in(uuid, int), homework_mark(uuid, uuid, int, text) from public, anon;
grant execute on function homework_set(uuid, text, text, text, date), homework_update(uuid, text, text, text, date),
  homework_delete(uuid), homework_hand_in(uuid, int), homework_mark(uuid, uuid, int, text) to authenticated;
