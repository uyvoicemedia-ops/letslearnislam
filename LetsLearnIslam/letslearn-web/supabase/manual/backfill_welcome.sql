-- Run ONCE, by hand, in the SQL editor, after migrations 0022 to 0026 are applied, IF your school already
-- has pupils enrolled: the welcome coins are paid by a trigger when someone is enrolled, so pupils who
-- joined a class before it existed have not had theirs.
--
-- It is safe to run twice: the welcome is paid once per pupil ever (the reference is just 'welcome').
-- It skips test students and anyone not in a class. It shows how many pupils it paid.
select count(*) filter (where ll_mint(p.id, 'welcome', ll_rate('welcome'), 'welcome', 'Welcome to the class') > 0) as pupils_paid,
       count(*) as pupils_checked
from profiles p
where p.role = 'student' and coalesce(p.is_test, false) = false
  and exists (select 1 from enrolments e where e.pupil_id = p.id);
