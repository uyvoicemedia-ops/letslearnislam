-- ============================================================
-- LetsLearn — row-level security
-- ------------------------------------------------------------
-- Run last. RLS is already on from 0001, so until this file runs the
-- database is closed and the app will read nothing.
--
-- The shape of every rule here is the same question: is this row about
-- a child this person is entitled to see? ll_can_see_pupil() answers
-- it once — self, their parent, a teacher of one of their classes, or
-- an admin of the same school — and everything else defers to it.
--
-- Two things worth saying out loud, because they are easy to get wrong
-- and expensive to get wrong with children's data:
--
--   * A pupil may READ their attendance, marks and points, and may not
--     write them. The only rows a child can create are their own
--     practice, their own reading, their own garden and their own club
--     posts. Coins in particular are insert-only by adults and by the
--     server-side quiz function, so no amount of console poking mints
--     a coin.
--
--   * "Same school" is not enough on its own for anything personal. A
--     teacher at Al-Noor cannot read a child they do not teach. Only
--     the club, which is a shared noticeboard by design, is school-wide.
-- ============================================================

-- ---------- schools, classes, roster ----------

create policy "see your own school" on schools
  for select using (id = ll_school());

-- Your own row, and rows about people you are entitled to see. Note the
-- pin columns are already revoked at the column level in 0001.
-- Reading a person is NARROWER than managing one, and the two must be
-- separate policies. A `for all` management policy also grants select,
-- and permissive policies are OR'd together, so a single "staff manage
-- their school" rule quietly hands every teacher every child in the
-- building. The test suite caught exactly that.
create policy "see yourself" on profiles
  for select using (
    auth_uid = auth.uid()
    or ll_can_see_pupil(id)                                  -- your pupils
    or (school_id = ll_school() and role in ('teacher', 'admin'))  -- the staff list
  );

create policy "edit your own name and avatar" on profiles
  for update using (auth_uid = auth.uid()) with check (auth_uid = auth.uid());

-- Management, deliberately without select.
create policy "staff add people" on profiles
  for insert with check (ll_role() in ('teacher', 'admin') and school_id = ll_school());
create policy "staff edit people" on profiles
  for update using (ll_role() in ('teacher', 'admin') and school_id = ll_school())
  with check (ll_role() in ('teacher', 'admin') and school_id = ll_school());
create policy "admins remove people" on profiles
  for delete using (ll_role() = 'admin' and school_id = ll_school());

create policy "see classes in your school" on classes
  for select using (school_id = ll_school());
create policy "staff manage classes" on classes
  for all using (ll_role() in ('teacher', 'admin') and school_id = ll_school())
  with check (ll_role() in ('teacher', 'admin') and school_id = ll_school());

create policy "see who teaches what" on class_teachers
  for select using (exists (select 1 from classes c
                            where c.id = class_id and c.school_id = ll_school()));
create policy "admins assign teachers" on class_teachers
  for all using (ll_role() = 'admin') with check (ll_role() = 'admin');

-- Same trap as profiles: an enrolment row names a pupil, so a blanket
-- staff policy would let any teacher enumerate every child in the
-- school by class. Scoped to classes you actually teach.
create policy "see enrolments you may see" on enrolments
  for select using (ll_can_see_pupil(pupil_id) or ll_teaches(class_id));
create policy "staff enrol into their own classes" on enrolments
  for insert with check (ll_teaches(class_id));
create policy "staff unenrol from their own classes" on enrolments
  for delete using (ll_teaches(class_id));

create policy "see your own family links" on guardians
  for select using (parent_id = ll_me() or ll_can_see_pupil(pupil_id));
create policy "admins link families" on guardians
  for all using (ll_role() = 'admin') with check (ll_role() = 'admin');

-- ---------- the register, homework, practice ----------

create policy "read attendance you may see" on attendance
  for select using (ll_can_see_pupil(pupil_id));
create policy "staff take the register" on attendance
  for all using (ll_teaches(class_id)) with check (ll_teaches(class_id));

create policy "read homework for your classes" on homework
  for select using (
    ll_teaches(class_id)
    or exists (select 1 from enrolments e
               where e.class_id = homework.class_id and ll_can_see_pupil(e.pupil_id))
  );
create policy "staff set homework" on homework
  for all using (ll_teaches(class_id)) with check (ll_teaches(class_id));

create policy "read submissions you may see" on submissions
  for select using (ll_can_see_pupil(pupil_id));
-- a child hands in their own work, and cannot mark it
create policy "hand in your own work" on submissions
  for insert with check (pupil_id = ll_me());
create policy "staff mark work" on submissions
  for update using (ll_role() in ('teacher', 'admin')) with check (ll_role() in ('teacher', 'admin'));

create policy "read practice you may see" on practice
  for select using (ll_can_see_pupil(pupil_id));
create policy "record your own practice" on practice
  for insert with check (pupil_id = ll_me());

create policy "read reading you may see" on reading
  for select using (ll_can_see_pupil(pupil_id));
create policy "record your own reading" on reading
  for all using (pupil_id = ll_me()) with check (pupil_id = ll_me());

-- ---------- coins and the garden ----------

-- Read your own; adults read the children they are entitled to.
create policy "read points you may see" on points
  for select using (ll_can_see_pupil(pupil_id));

-- Nobody writes a coin from the client except an adult giving one, and
-- an adult may only give to a child they are entitled to see. Practice,
-- attendance and quiz coins are all written by security-definer
-- functions, which are not subject to this policy at all.
create policy "adults give points" on points
  for insert with check (
    ll_role() in ('teacher', 'admin', 'parent')
    and ll_can_see_pupil(pupil_id)
    and given_by = ll_me()
    and amount between 1 and 100
    and source in ('teacher_gift', 'parent_gift')
  );

create policy "read gardens you may see" on garden
  for select using (ll_can_see_pupil(pupil_id));
create policy "tend your own garden" on garden
  for all using (pupil_id = ll_me()) with check (pupil_id = ll_me());

-- ---------- the club ----------

-- Approved posts are school-wide; your own unapproved post stays
-- visible to you so it does not look like it vanished.
create policy "read approved posts" on club_posts
  for select using (
    school_id = ll_school()
    and (approved or author_id = ll_me() or ll_role() in ('teacher', 'admin'))
  );
create policy "write your own post" on club_posts
  for insert with check (
    author_id = ll_me() and school_id = ll_school()
    -- children's posts arrive unapproved, whatever the client sends
    and (approved = false or ll_role() in ('teacher', 'admin'))
  );
create policy "authors delete their own" on club_posts
  for delete using (author_id = ll_me() or ll_role() in ('teacher', 'admin'));
create policy "staff moderate" on club_posts
  for update using (ll_role() in ('teacher', 'admin') and school_id = ll_school())
  with check (ll_role() in ('teacher', 'admin') and school_id = ll_school());

create policy "read likes on posts you can see" on club_likes
  for select using (exists (select 1 from club_posts p where p.id = post_id));
create policy "like as yourself" on club_likes
  for insert with check (liker_id = ll_me());
create policy "unlike your own" on club_likes
  for delete using (liker_id = ll_me());

-- ---------- the quiz ----------

create policy "read quiz sets in your school" on quiz_sets
  for select using (school_id = ll_school());
create policy "staff write quiz sets" on quiz_sets
  for insert with check (ll_role() in ('teacher', 'admin')
                         and school_id = ll_school() and owner_id = ll_me());
-- your own set, or an admin tidying up. Not any colleague's.
create policy "owners edit their quiz sets" on quiz_sets
  for update using (owner_id = ll_me() or ll_role() = 'admin')
  with check (owner_id = ll_me() or ll_role() = 'admin');
create policy "owners delete their quiz sets" on quiz_sets
  for delete using (owner_id = ll_me() or ll_role() = 'admin');

-- A player must NOT be able to read the questions, because `answer` is
-- in the row. The host reads them and pushes each one out over
-- realtime; players receive the prompt and the choices, never the key.
create policy "only the owner reads questions" on quiz_questions
  for select using (exists (select 1 from quiz_sets s
                            where s.id = set_id and s.owner_id = ll_me()));
create policy "owner writes questions" on quiz_questions
  for all using (exists (select 1 from quiz_sets s
                         where s.id = set_id and s.owner_id = ll_me()))
  with check (exists (select 1 from quiz_sets s
                      where s.id = set_id and s.owner_id = ll_me()));

-- Anyone with the code can watch the room's state; that is what makes
-- the screen change for everyone at once. The room row carries no
-- answers, only which question number is up and when it went up.
create policy "watch a room" on quiz_rooms
  for select using (true);
create policy "host runs the room" on quiz_rooms
  for all using (host_id = ll_me()) with check (host_id = ll_me());

create policy "see the players in your room" on quiz_players
  for select using (exists (select 1 from quiz_players mine
                            where mine.room_id = quiz_players.room_id
                              and (mine.pupil_id = ll_me()))
                    or exists (select 1 from quiz_rooms r
                               where r.id = room_id and r.host_id = ll_me()));

-- Answers are written only by quiz_answer(), which is security definer.
-- No client-side insert policy exists, so a player cannot post their own
-- score, and no select policy exists either, so nobody can read what
-- anyone else pressed.
create policy "host reviews answers" on quiz_answers
  for select using (exists (select 1 from quiz_rooms r
                            where r.id = room_id and r.host_id = ll_me()));
