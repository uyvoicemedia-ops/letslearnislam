-- ============================================================
-- LetsLearn — a progress report for one child
-- ------------------------------------------------------------
-- The "Report card" in Print & export was a label. This is the data
-- behind a real one: attendance, practice by module, reading,
-- homework and the coins earned, for one child over a date range.
--
-- It is SECURITY INVOKER on purpose. The function reads the same tables
-- the caller could already read, through the same row-level-security
-- policies, so it cannot show anything the screens could not. It adds one
-- check on top, ll_can_see_pupil(): the child, their parent, a teacher of
-- one of their classes, or an admin of the same school. Anyone else
-- (another school, another parent, a pupil asking about a classmate, the
-- signed-out public key) gets { "error": "not_allowed" }, the same answer
-- whether or not that child exists, so it cannot be used to find out.
--
-- What it deliberately leaves out:
--   * the free-text "reason" and "given_by" on points: a teacher's or a
--     parent's private note about a gift is not part of a report; only the
--     totals by kind of coin are;
--   * email, PIN fields, the garden, anything about other children.
-- It reads. It writes nothing.
--
-- The range is at most 400 days, so one call cannot be asked to scan a
-- child's whole history, and lists are capped (60 missed days, 80 pieces of
-- homework, 50 books) so a report stays a page or two.
-- ============================================================

create or replace function pupil_report(p_pupil uuid, p_from date, p_to date)
returns jsonb
language plpgsql stable security invoker set search_path = public, pg_temp as $$
declare
  nm text; att jsonb; prac jsonb; prac_tot jsonb; rd jsonb; hw jsonb; hw_tot jsonb; pts jsonb; cls jsonb;
begin
  if p_pupil is null or p_from is null or p_to is null then
    return jsonb_build_object('error', 'bad_range');
  end if;
  -- the check, and the same answer for "not yours" and "does not exist"
  if not ll_can_see_pupil(p_pupil) then return jsonb_build_object('error', 'not_allowed'); end if;
  select full_name into nm from profiles where id = p_pupil and role = 'student';
  if nm is null then return jsonb_build_object('error', 'not_allowed'); end if;
  if p_from > p_to or p_to - p_from > 400 then return jsonb_build_object('error', 'bad_range'); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'name', c.name,
           'teachers', (select coalesce(jsonb_agg(t.full_name order by t.full_name), '[]'::jsonb)
                        from class_teachers ct join profiles t on t.id = ct.teacher_id
                        where ct.class_id = c.id)) order by c.name), '[]'::jsonb)
    into cls
  from enrolments e join classes c on c.id = e.class_id
  where e.pupil_id = p_pupil;

  select jsonb_build_object(
           'present', count(*) filter (where mark = 'present'),
           'late',    count(*) filter (where mark = 'late'),
           'absent',  count(*) filter (where mark = 'absent'),
           'excused', count(*) filter (where mark = 'excused'),
           'total',   count(*),
           -- excused days are not held against the child
           'attended_pct', case when count(*) filter (where mark <> 'excused') = 0 then null
                           else round(100.0 * count(*) filter (where mark in ('present', 'late'))
                                      / count(*) filter (where mark <> 'excused')) end,
           'missed', (select coalesce(jsonb_agg(jsonb_build_object('on', m.on_date, 'mark', m.mark) order by m.on_date desc), '[]'::jsonb)
                      from (select on_date, mark from attendance
                            where pupil_id = p_pupil and on_date between p_from and p_to and mark in ('absent', 'late')
                            order by on_date desc limit 60) m))
    into att
  from attendance where pupil_id = p_pupil and on_date between p_from and p_to;

  select coalesce(jsonb_agg(jsonb_build_object(
           'module', module_id, 'attempts', attempts, 'avg_score', avg_score, 'best_score', best_score,
           'stars', stars, 'last_on', last_on) order by module_id), '[]'::jsonb)
    into prac
  from (select module_id, count(*) as attempts, round(avg(score)) as avg_score, max(score) as best_score,
               sum(stars) as stars, max((at at time zone 'Europe/London')::date) as last_on
        from practice
        where pupil_id = p_pupil and (at at time zone 'Europe/London')::date between p_from and p_to
        group by module_id) x;

  select jsonb_build_object('attempts', count(*), 'stars', coalesce(sum(stars), 0))
    into prac_tot
  from practice where pupil_id = p_pupil and (at at time zone 'Europe/London')::date between p_from and p_to;

  select coalesce(jsonb_agg(jsonb_build_object('book', book_id, 'page', page, 'finished', finished_at is not null) order by updated_at desc), '[]'::jsonb)
    into rd
  from (select book_id, page, finished_at, updated_at from reading
        where pupil_id = p_pupil and (updated_at at time zone 'Europe/London')::date between p_from and p_to
        order by updated_at desc limit 50) r;

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', title, 'due_on', due_on, 'status', status, 'score', score, 'feedback', feedback) order by due_on desc nulls last), '[]'::jsonb)
    into hw
  from (select h.title, h.due_on, s.score, s.feedback,
               case when s.marked_at is not null then 'marked'
                    when s.id is not null then 'handed_in'
                    when h.due_on is not null and h.due_on < current_date then 'missing'
                    else 'open' end as status
        from homework h
        join enrolments e on e.class_id = h.class_id and e.pupil_id = p_pupil
        left join submissions s on s.homework_id = h.id and s.pupil_id = p_pupil
        where coalesce(h.due_on, (h.created_at at time zone 'Europe/London')::date) between p_from and p_to
        order by h.due_on desc nulls last limit 80) y;

  select jsonb_build_object(
           'set',       count(*),
           'marked',    count(*) filter (where status = 'marked'),
           'handed_in', count(*) filter (where status in ('marked', 'handed_in')),
           'missing',   count(*) filter (where status = 'missing'))
    into hw_tot
  from (select case when s.marked_at is not null then 'marked'
                    when s.id is not null then 'handed_in'
                    when h.due_on is not null and h.due_on < current_date then 'missing'
                    else 'open' end as status
        from homework h
        join enrolments e on e.class_id = h.class_id and e.pupil_id = p_pupil
        left join submissions s on s.homework_id = h.id and s.pupil_id = p_pupil
        where coalesce(h.due_on, (h.created_at at time zone 'Europe/London')::date) between p_from and p_to) z;

  -- totals by kind of coin only: never the reason, never who gave it
  select jsonb_build_object(
           'total', coalesce(sum(amount), 0),
           'by_source', (select coalesce(jsonb_object_agg(source, amt), '{}'::jsonb)
                         from (select source, sum(amount) as amt from points
                               where pupil_id = p_pupil and (at at time zone 'Europe/London')::date between p_from and p_to
                               group by source) s))
    into pts
  from points where pupil_id = p_pupil and (at at time zone 'Europe/London')::date between p_from and p_to;

  return jsonb_build_object(
    'pupil', jsonb_build_object('name', nm),
    'classes', cls,
    'range', jsonb_build_object('from', p_from, 'to', p_to),
    'generated_on', (now() at time zone 'Europe/London')::date,
    'attendance', att,
    'practice', jsonb_build_object('totals', prac_tot, 'by_module', prac),
    'reading', rd,
    'homework', jsonb_build_object('totals', hw_tot, 'items', hw),
    'coins', pts);
end $$;

revoke all on function pupil_report(uuid, date, date) from public, anon;
grant execute on function pupil_report(uuid, date, date) to authenticated;

comment on function pupil_report(uuid, date, date) is
  'A read-only progress report for one child. Security invoker: it can show only what the caller could already read, plus ll_can_see_pupil(). Leaves out points.reason and points.given_by.';
