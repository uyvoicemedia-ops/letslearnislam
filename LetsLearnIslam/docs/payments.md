# LetsLearn — fees and Direct Debit

Built 10 Oct 2026.

## The rule everything else follows from

**No bank detail ever reaches this database.** Not a sort code, not an account number, not
an account holder's name typed into a form in this app. The parent types them on
GoCardless's own page, on GoCardless's domain. What comes back here is a customer id and a
mandate id: two opaque strings, useless to anyone who steals them, because collecting
against a mandate needs the API key, and that lives in the edge function.

Storing bank details means Bacs obligations; storing card numbers means PCI scope. The whole
point of using a provider is to not be the one holding the data. **There is no form in the
app that asks for bank details, and there must never be one.**

## Who may write what

Clients write **nothing** to `mandates` or `fee_charges`. Not a parent, not an admin. Those
rows are written only by the edge function with the service-role key, only in response to a
signed webhook. So a status in those tables always means GoCardless said so.

An admin **does** write `fee_plans` — what the madrasah charges is the madrasah's business.

**Teachers see none of it.** Who is behind on their fees should not colour how a child is
treated in class. If the madrasah wants that changed it is one policy in `0007_fees.sql`,
and it should be a decision somebody takes out loud rather than a default nobody chose.

## The tables (0007)

- `fee_plans` — what the school charges. `amount_pence`, because money in a float is a bug
  waiting for a rounding, and because pence is what the GoCardless API takes.
- `mandates` — one per payer per school. `gc_customer_id`, `gc_mandate_id`,
  `gc_billing_request_id`, a status, and nothing from the bank.
- `fee_charges` — what was collected and what happened. **Unique on
  `(payer_id, plan_id, period)`**, the guard against a retried October run billing twice.
- `webhook_events` — every delivery, once. GoCardless delivers at least once and does not
  retry automatically, so the handler writes the event id first and skips a duplicate key.
  It is also the audit trail: when a parent says they were charged twice, this answers.
- `fee_status()` — one security-definer function giving the parent's screen the mandate and
  what is outstanding.

## The edge function — `supabase/functions/gocardless/index.ts`

Three routes, one secret.

- `POST /start` — creates a billing request and flow, writes a `pending` mandate row, hands
  back `authorisation_url`.
- `POST /webhook` — verifies `Webhook-Signature`, an HMAC-SHA256 of the **raw** body,
  compared in constant time, **before** parsing the JSON — re-serialising changes the bytes
  and the signature stops matching. Returns 498 on a mismatch.
- `POST /collect` — admin only. Dry-runs by default. Writes the charge row *before* calling
  the API, so a payment that succeeds at GoCardless and then fails to reach us is visible
  rather than silently lost. Pins each payment with an `Idempotency-Key`.

API shape as of Oct 2026: `GoCardless-Version: 2015-07-06`, bearer token,
`https://api.gocardless.com` and `https://api-sandbox.gocardless.com`.

**Deploy with `--no-verify-jwt`.** The webhook carries no Supabase JWT; with verification on,
every webhook is rejected and nothing ever updates. `/start` and `/collect` check the caller
themselves, and `/webhook` is protected by the signature.

## The redirect is not evidence

A parent comes back with `#dd-done` in the URL. Anybody can type that. The screen says
*"we are checking with your bank"* and the status arrives later from the signed webhook.

## The collection run

The admin screen sends nothing until a dry run has said how many families it would charge,
and then only if somebody types COLLECT. A payment submitted to Bacs is somebody's grocery
money; cancelling it is something you do in the GoCardless dashboard, quickly.

## Tested, and not tested

14 assertions of the 91. The ones that matter are the negatives: a payer cannot mark their
own bill paid, cannot invent a charge, cannot forge a mandate id; a teacher cannot see who
has a Direct Debit; an admin cannot mark a charge collected; a child cannot read any of it;
not even an admin reads the webhook log.

The client half was proved against a hand-built stand-in for the GoCardless API. That catches
shapes and ordering and **proves nothing about the provider.** Nothing here has touched
GoCardless, not even sandbox.

## Next, in order

1. Sandbox end to end. **Sandbox is a separate account** from live — separate signup at
   manage-sandbox.gocardless.com, separate login, separate credentials. `SETUP.md` §7.
2. A failed charge shows as failed and somebody deals with it by hand. No retry, no dunning.
3. No refunds from the app — that is the dashboard.
4. One plan per school, not per family. A sibling discount has nowhere to live yet.
