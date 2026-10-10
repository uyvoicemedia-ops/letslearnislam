-- ============================================================
-- LetsLearn — quiz sets the app can actually use
-- ------------------------------------------------------------
-- Everything the live quiz needed was already here: sets,
-- questions, rooms, players, server-side scoring. What was
-- missing is the three things the CLIENT needs before it can stop
-- hard-coding its nineteen built-in sets.
--
-- 1. The picker groups sets ("The alphabet", "Joining", "Reading
--    words", "The deen") and shows a note in the host lobby for
--    the four deen sets, which a teacher must read before using
--    them. Neither had anywhere to live, so a set fetched from
--    the database lost its heading and lost its warning.
--
-- 2. Every question carries a picture, because a four year old
--    cannot read the prompt. Most are worked out from the Arabic
--    or from keywords, but a teacher can override that in the
--    editor, and an explicit choice had nowhere to go either.
--
-- 3. Sharing. See below — this is the interesting one.
-- ============================================================

alter table quiz_sets      add column if not exists grp  text;
alter table quiz_sets      add column if not exists note text;
alter table quiz_questions add column if not exists pic  text;

comment on column quiz_sets.grp is
  'Picker heading. Null falls into "Starter sets".';
comment on column quiz_sets.note is
  'Shown in the host lobby before the game starts — used to tell a
   teacher to read a set through first.';
comment on column quiz_questions.pic is
  'Explicit picture key chosen by the author. Null means work it out
   from the Arabic or the keywords; the string "none" means no picture.';

-- ------------------------------------------------------------
-- A set you can see but can never host
-- ------------------------------------------------------------
-- quiz_sets is readable across the school, but quiz_questions was
-- readable only by the set's owner. So every teacher could SEE a
-- colleague's set in the picker, choose it, and start a game with
-- nothing in it.
--
-- The tempting fix is to let all staff read all questions in their
-- school. That is a real weakening, and the test suite says so in
-- as many words: "a colleague cannot read someone else's answer
-- key". Turning a passing security test red to make a feature work
-- is how a schema quietly stops meaning anything.
--
-- So sharing becomes a decision somebody makes, not a side effect.
-- `shared` defaults to false, which is exactly today's behaviour:
-- nothing that exists now becomes readable to anybody new. A
-- teacher who wants the whole madrasah to use their wudu set ticks
-- the box, and only then can a colleague read its questions.
--
-- A child still cannot read a single question under any of this.
-- Every policy below requires an adult role, and the answer key
-- lives in the row.
alter table quiz_sets add column if not exists shared boolean not null default false;

comment on column quiz_sets.shared is
  'The owner has let other staff in this school host this set. False
   keeps the questions private to the owner, which is the default.';

create policy "staff read shared questions in their school" on quiz_questions
  for select using (
    ll_role() in ('teacher', 'admin')
    and exists (select 1 from quiz_sets s
                where s.id = set_id
                  and s.shared
                  and s.school_id = ll_school())
  );

-- The owner's write policy was `for all`, which also grants select —
-- the trap this project has now hit three times. It is harmless here,
-- because the owner may read their own questions anyway, but reading
-- and writing are separate policies everywhere else in this schema
-- and there is no reason for this one to be the exception.
drop policy if exists "owner writes questions" on quiz_questions;

create policy "owners read their questions" on quiz_questions
  for select using (exists (select 1 from quiz_sets s
                            where s.id = set_id and s.owner_id = ll_me()));
create policy "owners insert their questions" on quiz_questions
  for insert with check (exists (select 1 from quiz_sets s
                                 where s.id = set_id and s.owner_id = ll_me()));
create policy "owners update their questions" on quiz_questions
  for update using (exists (select 1 from quiz_sets s
                            where s.id = set_id and s.owner_id = ll_me()))
          with check (exists (select 1 from quiz_sets s
                              where s.id = set_id and s.owner_id = ll_me()));
create policy "owners delete their questions" on quiz_questions
  for delete using (exists (select 1 from quiz_sets s
                            where s.id = set_id and s.owner_id = ll_me()));

-- "only the owner reads questions" from 0003 said the same thing as
-- "owners read their questions" above. Dropping it last means there is
-- no instant where nobody can read their own questions.
drop policy if exists "only the owner reads questions" on quiz_questions;
