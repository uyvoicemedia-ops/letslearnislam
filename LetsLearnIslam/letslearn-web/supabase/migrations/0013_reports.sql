-- ============================================================
-- LetsLearn — report recipients, and a record of what was done
-- ------------------------------------------------------------
-- Reports & email was a mock that said so ("Nothing sends in this
-- prototype"). Real sending needs an email provider and a verified
-- domain, which is an account only the madrasah can open, so this does
-- not pretend to send. What it does do is real:
--
--   * the addresses reports go to are kept here, once, by an admin, so a
--     mistyped accountant's address is not typed afresh every month;
--   * every time an admin downloads, prints or opens a report in their own
--     mail app, it is logged: who, when, which report, to whom. The status
--     is what actually happened ("downloaded", "printed", "mail draft
--     opened"), never "delivered", because nothing here can know that.
--
-- Salary and fee figures are in these reports, so all of it is admin-only
-- and the log cannot be edited or deleted: it is the answer to "did the
-- accountant get June's figures, and who sent them".
-- ============================================================

create table report_recipients (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references schools(id) on delete cascade,
  name        text not null check (length(btrim(name)) between 1 and 80),
  email       text not null check (length(email) <= 254 and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  role        text not null default '' check (length(role) <= 60),
  created_by  uuid references profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
create unique index report_recipients_email on report_recipients(school_id, lower(email));
alter table report_recipients enable row level security;
revoke all on report_recipients from anon;

create table report_log (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references schools(id) on delete cascade,
  report      text not null check (length(report) between 1 and 120),
  period      text not null default '' check (length(period) <= 60),
  recipients  text not null default '' check (length(recipients) <= 600),
  format      text not null check (format in ('csv', 'print', 'text')),
  action      text not null check (action in ('downloaded', 'printed', 'mail_draft')),
  by_id       uuid references profiles(id) on delete set null,
  at          timestamptz not null default now()
);
create index report_log_school on report_log(school_id, at desc);
alter table report_log enable row level security;
revoke all on report_log from anon;

create policy "admins read recipients" on report_recipients
  for select using (ll_role() = 'admin' and school_id = ll_school());
create policy "admins add recipients" on report_recipients
  for insert with check (ll_role() = 'admin' and school_id = ll_school());
create policy "admins remove recipients" on report_recipients
  for delete using (ll_role() = 'admin' and school_id = ll_school());

-- read and append only: there is no update or delete policy, so the log cannot be rewritten
create policy "admins read the report log" on report_log
  for select using (ll_role() = 'admin' and school_id = ll_school());
create policy "admins log a report" on report_log
  for insert with check (ll_role() = 'admin' and school_id = ll_school() and by_id = ll_me());
