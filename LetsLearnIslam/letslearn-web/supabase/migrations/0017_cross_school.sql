-- ============================================================
-- LetsLearn — one school cannot reach into another
-- ------------------------------------------------------------
-- 0002's ll_teaches() ends in "or ll_role() = 'admin'" with no school
-- test, and four rules in 0003 and 0005 asked only "is this an admin?"
-- or "does ll_teaches say yes?". Reproduced against the test database:
-- an admin at ANOTHER school, holding nothing but a class code (which
-- class_roster() hands to anyone, because children type it), could
--
--   * INSERT a guardians row linking themselves to one of our children
--     as a "parent", after which ll_can_see_pupil() said yes and they
--     could read that child's profile, practice, attendance, garden and
--     points;
--   * write and read our registers (attendance, "staff take the register");
--   * approve a class request into one of our classes
--     (class_request_decide used ll_teaches), which also stamps their
--     school onto a home-added child;
--   * read the pending requests aimed at our classes, and the names of
--     the children in them (class_requests, ll_offered_to_me).
--
-- The app never writes guardians, class_teachers or enrolments directly:
-- every write goes through a security definer function (family_*,
-- class_request_decide, class_move_pupil, class_set_teacher, 0010). So
-- the direct-write rules are removed outright and the privileges revoked,
-- rather than patched. What a teacher or admin can still read is scoped
-- through ll_manages_class(), which is school-scoped (0009).
--
-- The register is still written by the client until its replacement ships,
-- so its rule is kept, but now it needs the caller to run THAT class and
-- the pupil to be enrolled IN it.
-- ============================================================

-- ---------- nobody writes these directly ----------
drop policy if exists "admins assign teachers"            on class_teachers;
drop policy if exists "staff enrol into their own classes"  on enrolments;
drop policy if exists "staff unenrol from their own classes" on enrolments;
drop policy if exists "admins link families"                on guardians;

revoke all on class_teachers, enrolments, guardians from anon;
revoke insert, update, delete on class_teachers, enrolments, guardians from authenticated;

-- ---------- reading: through the school-scoped helper ----------
drop policy if exists "see enrolments you may see" on enrolments;
create policy "see enrolments you may see" on enrolments
  for select using (ll_can_see_pupil(pupil_id) or ll_manages_class(class_id));

drop policy if exists "see requests aimed at your classes" on class_requests;
create policy "see requests aimed at your classes" on class_requests
  for select using (ll_manages_class(class_id));

-- ---------- the register ----------
drop policy if exists "staff take the register" on attendance;
create policy "staff take the register" on attendance
  for all
  using (ll_manages_class(class_id)
         and exists (select 1 from enrolments e where e.class_id = attendance.class_id and e.pupil_id = attendance.pupil_id))
  with check (ll_manages_class(class_id)
         and exists (select 1 from enrolments e where e.class_id = attendance.class_id and e.pupil_id = attendance.pupil_id));

-- ---------- the two functions that still asked ll_teaches ----------
create or replace function ll_offered_to_me(p_pupil uuid) returns boolean
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select exists (
    select 1 from class_requests r
    where r.pupil_id = p_pupil and r.state = 'pending' and ll_manages_class(r.class_id)
  );
$$;

create or replace function class_request_decide(p_request uuid, p_approve boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare
  rec class_requests%rowtype; sch uuid; had uuid;
begin
  select * into rec from class_requests where id = p_request;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_such_request');
  end if;
  if rec.state <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'already_decided');
  end if;
  -- the caller must be staff who run THIS class, at THIS class's school
  if ll_role() not in ('teacher', 'admin') or not ll_manages_class(rec.class_id) then
    return jsonb_build_object('ok', false, 'error', 'not_your_class');
  end if;

  if not p_approve then
    update class_requests set state = 'declined', decided_by = ll_me(), decided_at = now()
    where id = p_request;
    return jsonb_build_object('ok', true, 'state', 'declined');
  end if;

  select school_id into sch from classes where id = rec.class_id;
  select school_id into had from profiles where id = rec.pupil_id;
  if had is not null and had <> sch then
    return jsonb_build_object('ok', false, 'error', 'child_belongs_to_another_school');
  end if;

  insert into enrolments (class_id, pupil_id) values (rec.class_id, rec.pupil_id)
    on conflict do nothing;
  update profiles set school_id = sch where id = rec.pupil_id and school_id is null;
  update class_requests set state = 'approved', decided_by = ll_me(), decided_at = now()
  where id = p_request;

  return jsonb_build_object('ok', true, 'state', 'approved');
end;
$$;
