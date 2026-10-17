-- ============================================================
-- LetsLearn — which books a pupil has been given
-- ------------------------------------------------------------
-- The Books shelf showed all eight books (Elementary 1-4, Qaida 1-4)
-- to every child. A child on their first Qaida page does not need the
-- Quran-reading book on their shelf, and a teacher should be the one
-- to decide when they move up. So a pupil sees only the books somebody
-- has given them.
--
--   * pupil_books: one row per (pupil, book). book_id is the app's own
--     id ("qaida-2", "islam-1"); the books themselves are files in the
--     app, not rows here, so this stores only the choice.
--   * Nothing writes the table directly. Two functions do, each checking
--     that the caller is an admin of the pupil's school or a teacher who
--     actually teaches that pupil. ll_teaches() is NOT used: its admin
--     branch is not school-scoped (see 0010).
--   * A pupil reads their own rows, a parent their child's, a teacher the
--     pupils they teach, an admin their school's. Nobody else.
--
-- What this is not: access control for the book FILES. They are static
-- files in the app, lightly obfuscated, and the app says so ("NOT DRM").
-- This decides what a child is shown, not what a determined child could
-- fetch by hand.
-- ============================================================

create table pupil_books (
  pupil_id     uuid not null references profiles(id) on delete cascade,
  book_id      text not null check (book_id ~ '^[a-z0-9][a-z0-9-]{0,39}$'),
  assigned_by  uuid references profiles(id) on delete set null,
  assigned_at  timestamptz not null default now(),
  primary key (pupil_id, book_id)
);
create index pupil_books_pupil on pupil_books(pupil_id);

alter table pupil_books enable row level security;
revoke all on pupil_books from anon;
revoke insert, update, delete on pupil_books from authenticated;

create policy "see the books of a pupil you may see" on pupil_books
  for select using (ll_can_see_pupil(pupil_id));

-- May the caller choose this pupil's books?
create or replace function ll_may_give_books(p_pupil uuid) returns boolean
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select exists (
    select 1 from profiles pu
    where pu.id = p_pupil and pu.role = 'student'
      and (
        (ll_role() = 'admin' and pu.school_id = ll_school())
        or exists (select 1 from enrolments e
                   join class_teachers ct on ct.class_id = e.class_id
                   where e.pupil_id = pu.id and ct.teacher_id = ll_me())
      )
  );
$$;

-- Replace a pupil's whole shelf.
create or replace function pupil_books_set(p_pupil uuid, p_books text[])
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare b text; n int;
begin
  if ll_role() not in ('admin', 'teacher') then return jsonb_build_object('error', 'not_allowed'); end if;
  if not ll_may_give_books(p_pupil) then return jsonb_build_object('error', 'not_allowed'); end if;
  p_books := coalesce(p_books, '{}');
  if cardinality(p_books) > 20 then return jsonb_build_object('error', 'too_many'); end if;
  foreach b in array p_books loop
    if b is null or b !~ '^[a-z0-9][a-z0-9-]{0,39}$' then return jsonb_build_object('error', 'bad_book'); end if;
  end loop;
  delete from pupil_books where pupil_id = p_pupil and not (book_id = any (p_books));
  insert into pupil_books (pupil_id, book_id, assigned_by)
    select p_pupil, x, ll_me() from unnest(p_books) x on conflict do nothing;
  select count(*) into n from pupil_books where pupil_id = p_pupil;
  return jsonb_build_object('ok', true, 'books', n);
end $$;

-- Give one book to, or take it from, several pupils at once (a column of
-- the grid, or a whole class). Pupils the caller may not choose for are
-- skipped and counted, never silently included.
create or replace function pupil_books_toggle(p_pupils uuid[], p_book text, p_on boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare p uuid; changed int := 0; skipped int := 0;
begin
  if ll_role() not in ('admin', 'teacher') then return jsonb_build_object('error', 'not_allowed'); end if;
  if p_book is null or p_book !~ '^[a-z0-9][a-z0-9-]{0,39}$' then return jsonb_build_object('error', 'bad_book'); end if;
  if p_pupils is null or cardinality(p_pupils) > 500 then return jsonb_build_object('error', 'too_many'); end if;
  foreach p in array p_pupils loop
    if ll_may_give_books(p) then
      if p_on then
        insert into pupil_books (pupil_id, book_id, assigned_by) values (p, p_book, ll_me()) on conflict do nothing;
      else
        delete from pupil_books where pupil_id = p and book_id = p_book;
      end if;
      changed := changed + 1;
    else
      skipped := skipped + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'changed', changed, 'skipped', skipped);
end $$;

revoke all on function ll_may_give_books(uuid), pupil_books_set(uuid, text[]), pupil_books_toggle(uuid[], text, boolean) from public, anon;
grant execute on function pupil_books_set(uuid, text[]), pupil_books_toggle(uuid[], text, boolean) to authenticated;
