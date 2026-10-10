-- ============================================================
-- LetsLearn — fees, mandates and collections
-- ------------------------------------------------------------
-- THE ONE RULE: no bank detail ever reaches this database.
--
-- Not a sort code, not an account number, not an account
-- holder's name typed into a form in this app. The parent sets
-- the Direct Debit up on GoCardless's own hosted page, and what
-- comes back here is a customer id and a mandate id — two
-- opaque strings that are useless to anyone who steals them,
-- because collecting against a mandate needs the API key, which
-- lives in the edge function and never goes near a device.
--
-- That is not caution for its own sake. Storing bank details
-- means Bacs obligations and PCI scope; storing provider ids
-- means neither. The whole point of using a provider is to not
-- be the one holding the data.
--
-- WHO WRITES WHAT
--
-- Clients never write a mandate or a charge. Not the parent,
-- not an admin. Those rows are written by the edge function
-- using the service-role key, in response to what GoCardless
-- says over a signed webhook. An admin who could hand-write
-- `status = 'confirmed'` on a charge could mark a term's fees
-- paid without a penny moving, and the first person to notice
-- would be the treasurer in March.
--
-- An admin DOES write fee_plans — what the madrasah charges is
-- the madrasah's business, and nothing external depends on it.
--
-- TEACHERS SEE NONE OF THIS. A teacher teaches; who is behind
-- on their fees is not something that should colour how a child
-- is treated in class. If the madrasah wants that changed it is
-- one policy, and it should be a decision somebody takes out
-- loud rather than a default nobody chose.
-- ============================================================

-- ---------- what the madrasah charges ----------

create type fee_interval as enum ('monthly', 'termly', 'annual', 'one_off');

create table fee_plans (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references schools(id) on delete cascade,
  name          text not null,
  -- pence, because money in a float is a bug waiting for a rounding
  amount_pence  int not null check (amount_pence > 0),
  currency      text not null default 'GBP' check (currency = upper(currency)),
  interval      fee_interval not null default 'monthly',
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);
create index fee_plans_school on fee_plans(school_id);

comment on column fee_plans.amount_pence is
  'The lowest denomination, which is also what the GoCardless API takes.';

-- ---------- the Direct Debit itself ----------

create type mandate_state as enum
  ('pending', 'submitted', 'active', 'failed', 'cancelled', 'expired');

create table mandates (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references schools(id) on delete cascade,
  -- the grown-up who signed it. Not the child, and not the family:
  -- a Direct Debit is signed by a named person with a bank account.
  payer_id      uuid not null references profiles(id) on delete cascade,

  -- GoCardless's ids, and NOTHING ELSE from the bank
  gc_customer_id        text,
  gc_mandate_id         text unique,
  gc_billing_request_id text,

  status        mandate_state not null default 'pending',
  -- the reference the parent sees on their statement, from GoCardless
  reference     text,
  failed_reason text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  unique (payer_id, school_id)
);
create index mandates_payer on mandates(payer_id);
create index mandates_school on mandates(school_id, status);

comment on table mandates is
  'Provider ids only. If a column here ever holds a sort code or an
   account number, something has gone wrong upstream of this table.';

-- ---------- what was collected, and what happened to it ----------

create type charge_state as enum
  ('pending', 'submitted', 'confirmed', 'paid_out',
   'failed', 'cancelled', 'charged_back');

create table fee_charges (
  id            uuid primary key default gen_random_uuid(),
  school_id     uuid not null references schools(id) on delete cascade,
  payer_id      uuid not null references profiles(id) on delete cascade,
  -- which child this was for, when it is for one. Null for a family fee.
  pupil_id      uuid references profiles(id) on delete set null,
  plan_id       uuid references fee_plans(id) on delete set null,
  mandate_id    uuid references mandates(id) on delete set null,

  gc_payment_id text unique,

  amount_pence  int not null check (amount_pence > 0),
  currency      text not null default 'GBP',
  charge_date   date,
  period        text,                       -- 'Autumn 2026', 'Oct 2026'
  status        charge_state not null default 'pending',
  failed_reason text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  -- one charge per payer per plan per period: the guard against a
  -- retried collection run billing a family twice for October
  unique (payer_id, plan_id, period)
);
create index fee_charges_payer on fee_charges(payer_id, charge_date desc);
create index fee_charges_school on fee_charges(school_id, status);

-- ---------- every webhook delivery, once ----------
-- GoCardless delivers at least once and does not retry automatically,
-- so a handler has to be safe to run twice and must not drop a batch
-- halfway. Writing the event id first and skipping a duplicate key is
-- the cheapest honest way to get both.
--
-- It is also the audit trail. When a parent says they were charged
-- twice, this table is what answers.
create table webhook_events (
  id            text primary key,          -- GoCardless's own event id
  resource_type text,
  action        text,
  received_at   timestamptz not null default now()
);
create index webhook_events_at on webhook_events(received_at desc);

alter table webhook_events enable row level security;
-- No policy at all: nothing but the service-role key ever reads or
-- writes it, and an empty policy list means everybody else is denied.

alter table fee_plans   enable row level security;
alter table mandates    enable row level security;
alter table fee_charges enable row level security;

-- ---------- who may see it ----------

-- A parent sees their own Direct Debit and their own charges, and
-- writes neither. Reading and managing are separate policies
-- throughout this schema; there is no "manage" here at all for a
-- parent, which is the point.
create policy "a payer reads their own mandate" on mandates
  for select using (payer_id = ll_me());

create policy "a payer reads their own charges" on fee_charges
  for select using (payer_id = ll_me());

-- An admin sees their school's. Not a teacher: see the header.
create policy "an admin reads the school's mandates" on mandates
  for select using (ll_role() = 'admin' and school_id = ll_school());

create policy "an admin reads the school's charges" on fee_charges
  for select using (ll_role() = 'admin' and school_id = ll_school());

-- Fee plans are readable by everyone in the school who can see fees
-- at all — a parent should be able to see what they are being
-- charged — and written only by an admin.
create policy "read the school's fee plans" on fee_plans
  for select using (
    school_id = ll_school()
    or exists (select 1 from mandates m
               where m.school_id = fee_plans.school_id and m.payer_id = ll_me())
  );
create policy "an admin writes fee plans" on fee_plans
  for insert with check (ll_role() = 'admin' and school_id = ll_school());
create policy "an admin edits fee plans" on fee_plans
  for update using (ll_role() = 'admin' and school_id = ll_school())
          with check (ll_role() = 'admin' and school_id = ll_school());
create policy "an admin removes fee plans" on fee_plans
  for delete using (ll_role() = 'admin' and school_id = ll_school());

-- NOTE the absence. There is no insert, update or delete policy on
-- mandates or fee_charges for anybody. Both are written only by the
-- edge function with the service-role key, which bypasses RLS, and
-- only in response to a signed webhook from GoCardless. A status in
-- those tables therefore always means the provider said so.

-- ---------- what the parent's screen asks for ----------

-- The client needs to know whether this parent has a live Direct
-- Debit before it decides which button to show. It could read the
-- mandates table directly — the policy allows it — but then every
-- screen grows its own idea of what "set up" means. One function,
-- one answer.
create or replace function fee_status()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  me uuid := ll_me();
  m  record;
  owed int;
begin
  if me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select * into m from mandates where payer_id = me
   order by (status = 'active') desc, created_at desc limit 1;

  select coalesce(sum(amount_pence), 0) into owed
    from fee_charges
   where payer_id = me and status in ('pending', 'submitted', 'failed');

  return jsonb_build_object(
    'ok', true,
    'mandate', case when m.id is null then null else jsonb_build_object(
        'status', m.status, 'reference', m.reference,
        'since', m.created_at, 'reason', m.failed_reason) end,
    'outstanding_pence', owed
  );
end;
$$;

revoke all on function fee_status() from public;
grant execute on function fee_status() to authenticated;

-- ---------- keeping updated_at honest ----------

create or replace function ll_touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger mandates_touched before update on mandates
  for each row execute function ll_touch_updated_at();
create trigger fee_charges_touched before update on fee_charges
  for each row execute function ll_touch_updated_at();
