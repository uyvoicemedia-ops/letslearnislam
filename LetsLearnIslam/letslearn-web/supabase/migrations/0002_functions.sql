-- ============================================================
-- LetsLearn — functions
-- ------------------------------------------------------------
-- Run after 0001_schema.sql and before 0003_rls.sql.
--
-- Everything here is `security definer`, which means it runs as the
-- function's owner and IGNORES row-level security. That is the point:
-- the policies in 0003 refer to these helpers, and a policy that
-- queried its own table under RLS would recurse forever. It also means
-- each one is a hole in the wall, so each is written to answer exactly
-- one question and return nothing else.
--
-- Every one of them pins search_path. Without that, a caller who can
-- create a schema could shadow `profiles` with their own table and the
-- definer's privileges would happily read it.
-- ============================================================

-- ---------- who is asking ----------

create or replace function ll_me() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select id from profiles where auth_uid = auth.uid();
$$;

create or replace function ll_role() returns user_role
language sql stable security definer set search_path = public, pg_temp as $$
  select role from profiles where auth_uid = auth.uid();
$$;

create or replace function ll_school() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select school_id from profiles where auth_uid = auth.uid();
$$;

create or replace function ll_teaches(p_class uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from class_teachers ct
    where ct.class_id = p_class and ct.teacher_id = ll_me()
  ) or ll_role() = 'admin';
$$;

-- Self, their parent, a teacher of one of their classes, or an admin of
-- the same school. This is the single answer to "may I look at this
-- child", and every policy that needs it calls this rather than
-- rewriting the join.
create or replace function ll_can_see_pupil(p_pupil uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select
    p_pupil = ll_me()
    or exists (select 1 from guardians g
               where g.pupil_id = p_pupil and g.parent_id = ll_me())
    or exists (select 1 from enrolments e
               join class_teachers ct on ct.class_id = e.class_id
               where e.pupil_id = p_pupil and ct.teacher_id = ll_me())
    or (ll_role() = 'admin'
        and exists (select 1 from profiles p
                    where p.id = p_pupil and p.school_id = ll_school()));
$$;

-- ---------- a child signing in ----------

-- The name list for a class code. Deliberately returns three columns
-- and no more: knowing a class code lets you see who is in that class,
-- which is what a printed code on a classroom wall already tells you.
-- It does not leak PINs, attendance, points or anything else.
create or replace function class_roster(p_code text)
returns table (pupil_id uuid, full_name text, avatar jsonb)
language sql stable security definer set search_path = public, pg_temp as $$
  select p.id, p.full_name, p.avatar
  from classes c
  join enrolments e on e.class_id = c.id
  join profiles p on p.id = e.pupil_id
  where upper(c.join_code) = upper(trim(p_code))
    and p.role = 'student'
  order by p.full_name;
$$;

-- Attach the anonymous session the browser just created to a pupil row,
-- if the PIN is right.
--
-- Re-claiming from a different device is allowed and is not a bug: the
-- PIN is the credential, so a child who moves to a new tablet and types
-- it correctly should get their garden back. The previous device simply
-- stops being that pupil.
create or replace function claim_pupil(p_code text, p_pupil uuid, p_pin text)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  rec profiles%rowtype;
  ok  boolean;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'no_session');
  end if;

  select p.* into rec
  from profiles p
  join enrolments e on e.pupil_id = p.id
  join classes c on c.id = e.class_id
  where p.id = p_pupil
    and p.role = 'student'
    and upper(c.join_code) = upper(trim(p_code));

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_in_class');
  end if;

  if rec.pin_locked_until is not null and rec.pin_locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked',
                              'until', rec.pin_locked_until);
  end if;

  ok := rec.pin_hash = crypt(p_pin, rec.pin_hash);

  if not ok then
    -- five wrong goes and it rests for fifteen minutes. Long enough to
    -- make guessing 10,000 PINs pointless, short enough that a child who
    -- genuinely forgot is not locked out of the lesson.
    update profiles set
      pin_attempts = pin_attempts + 1,
      pin_locked_until = case when pin_attempts + 1 >= 5
                              then now() + interval '15 minutes' end
    where id = rec.id;
    return jsonb_build_object('ok', false, 'error', 'wrong_pin');
  end if;

  update profiles set
    auth_uid = auth.uid(),
    pin_attempts = 0,
    pin_locked_until = null
  where id = rec.id;

  return jsonb_build_object('ok', true, 'pupil_id', rec.id,
                            'full_name', rec.full_name,
                            'school_id', rec.school_id);
end;
$$;

-- Teachers and admins set PINs; nobody ever reads one back.
create or replace function set_pupil_pin(p_pupil uuid, p_pin text)
returns boolean
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  if ll_role() not in ('teacher', 'admin') then
    raise exception 'only a teacher or admin may set a PIN';
  end if;
  if not ll_can_see_pupil(p_pupil) then
    raise exception 'not your pupil';
  end if;
  if p_pin !~ '^[0-9]{4,8}$' then
    raise exception 'a PIN is 4 to 8 digits';
  end if;
  update profiles set
    pin_hash = crypt(p_pin, gen_salt('bf', 10)),
    pin_attempts = 0, pin_locked_until = null
  where id = p_pupil and role = 'student';
  return found;
end;
$$;

-- ---------- coins ----------

create or replace function points_balance(p_pupil uuid) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select case when ll_can_see_pupil(p_pupil) then
    coalesce((select sum(amount) from points where pupil_id = p_pupil), 0)
    - coalesce((select spent from garden where pupil_id = p_pupil), 0)
  end;
$$;

-- ---------- the live quiz ----------

-- Join by room code. A child in the school joins as themselves; anyone
-- else gets a nickname only, which is how a guest joins a Kahoot.
create or replace function quiz_join(p_code text, p_nickname text)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  room quiz_rooms%rowtype;
  player quiz_players%rowtype;
  nick text := left(trim(p_nickname), 20);
begin
  select * into room from quiz_rooms
  where upper(code) = upper(trim(p_code)) and state <> 'finished';
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_room');
  end if;
  if nick = '' then
    return jsonb_build_object('ok', false, 'error', 'no_nickname');
  end if;

  -- rejoining after a dropped connection keeps the score
  select * into player from quiz_players
  where room_id = room.id and (pupil_id = ll_me() or nickname = nick);

  if found then
    update quiz_players set nickname = nick, pupil_id = coalesce(ll_me(), pupil_id)
    where id = player.id returning * into player;
  else
    insert into quiz_players (room_id, pupil_id, nickname)
    values (room.id, ll_me(), nick)
    returning * into player;
  end if;

  return jsonb_build_object('ok', true, 'room_id', room.id,
                            'player_id', player.id, 'state', room.state,
                            'score', player.score);
end;
$$;

-- Answering.
--
-- The client never sends its own timing or its own score. It sends the
-- choice; the server reads asked_at, works out how long that took, and
-- decides. Otherwise the first child to open the console posts ms = 0
-- and wins every round for the rest of the term.
create or replace function quiz_answer(p_player uuid, p_choice int)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  player quiz_players%rowtype;
  room   quiz_rooms%rowtype;
  q      quiz_questions%rowtype;
  took   int;
  right_answer boolean;
  earned int := 0;
begin
  select * into player from quiz_players where id = p_player;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_player'); end if;

  select * into room from quiz_rooms where id = player.room_id;
  if room.state <> 'asking' or room.asked_at is null then
    return jsonb_build_object('ok', false, 'error', 'not_asking');
  end if;

  select * into q from quiz_questions
  where set_id = room.set_id and ord = room.current_ord;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_question'); end if;

  took := greatest(0, (extract(epoch from (now() - room.asked_at)) * 1000)::int);
  if took > q.seconds * 1000 + 1500 then     -- 1.5s of grace for the network
    return jsonb_build_object('ok', false, 'error', 'too_late');
  end if;

  right_answer := (p_choice = q.answer);
  if right_answer then
    -- Kahoot's shape: everyone who is right gets half, and the other
    -- half decays with how long they took. Being fast is worth
    -- something; being right is worth more.
    earned := 500 + (500 * greatest(0, 1 - (took::numeric / (q.seconds * 1000))))::int;
  end if;

  insert into quiz_answers (room_id, question_id, player_id, choice, ms, correct, points)
  values (room.id, q.id, player.id, p_choice, took, right_answer, earned)
  on conflict (question_id, player_id) do nothing;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'already_answered');
  end if;

  update quiz_players set score = score + earned where id = player.id;

  -- what it was worth, but NOT whether the answer was right: the reveal
  -- belongs to the host, and a client that learns the answer early can
  -- show it early
  return jsonb_build_object('ok', true, 'ms', took);
end;
$$;

-- The leaderboard, safe to hand to every player in the room.
create or replace function quiz_board(p_room uuid)
returns table (nickname text, score int, place bigint)
language sql stable security definer set search_path = public, pg_temp as $$
  select p.nickname, p.score,
         rank() over (order by p.score desc, p.joined_at)
  from quiz_players p
  where p.room_id = p_room
  order by p.score desc, p.joined_at
  limit 50;
$$;

-- ---------- what the anon key may call ----------
revoke all on function claim_pupil(text, uuid, text) from public;
revoke all on function class_roster(text) from public;
revoke all on function set_pupil_pin(uuid, text) from public;
revoke all on function quiz_join(text, text) from public;
revoke all on function quiz_answer(uuid, int) from public;
revoke all on function quiz_board(uuid) from public;
revoke all on function points_balance(uuid) from public;

grant execute on function class_roster(text) to anon, authenticated;
grant execute on function claim_pupil(text, uuid, text) to anon, authenticated;
grant execute on function set_pupil_pin(uuid, text) to authenticated;
grant execute on function quiz_join(text, text) to anon, authenticated;
grant execute on function quiz_answer(uuid, int) to anon, authenticated;
grant execute on function quiz_board(uuid) to anon, authenticated;
grant execute on function points_balance(uuid) to authenticated;

-- ---------- an adult signing up ----------

-- The school enters its staff and parents on the roster first, with an
-- email and no account. When that person later signs up, this matches
-- them to the row that is already waiting rather than creating a
-- second, empty one — so a parent who registers is immediately linked
-- to their children instead of seeing an empty app and wondering why.
--
-- No match means no profile, which is the safe direction: a stranger
-- who signs up gets an account that can see nothing at all.
create or replace function ll_link_new_user() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update profiles
     set auth_uid = new.id
   where email is not null
     and lower(email) = lower(new.email)
     and auth_uid is null
     and role <> 'student';
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function ll_link_new_user();
