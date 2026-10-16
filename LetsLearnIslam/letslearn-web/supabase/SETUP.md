# Wiring the app to your Supabase project

Twenty minutes, most of it waiting for the SQL editor.

## 1. Run the migrations, in order

Supabase dashboard → **SQL Editor** → paste each file, run, check it says success
before moving on. Order matters: 0001 turns row-level security on, so between
0001 and 0003 the database is deliberately closed.

| file | what it does |
|---|---|
| `migrations/0001_schema.sql` | tables, and RLS switched on |
| `migrations/0002_functions.sql` | sign-in, scoring, and the helpers RLS needs |
| `migrations/0003_rls.sql` | who may read and write what |
| `migrations/0004_seed.sql` | Al-Noor Madrasah, so the app has something to show |
| `migrations/0005_families.sql` | households, parents signing themselves up, class requests |
| `migrations/0006_quiz_sets.sql` | quiz sets held by the school, and opt-in sharing |
| `migrations/0007_fees.sql` | fee plans, Direct Debit mandates and charges (§7) |
| `migrations/0008_pgcrypto_search_path.sql` | lets the PIN functions find `crypt()` on Supabase |
| `migrations/0009_class_sessions.sql` | online class sessions with a meeting link, and the approved-platform list |

The app needs **all nine**, 0001 to 0009. Skipping one does not fail at sign-up;
it fails later, on whichever screen uses the missing piece.

**Before running 0004, change the three email addresses in it** to ones you can
receive at. They are how your admin, teacher and parent accounts get matched to
the roster rows when you sign up. Do this in a copy kept **outside the repo**
(for example `~/ll-local/`) and paste that copy into the SQL Editor, so your real
addresses are never committed.

### Why 0008 exists

Supabase installs extensions, pgcrypto included, into a schema called
`extensions`, not `public`. Our security-definer functions pin
`search_path = public, pg_temp` on purpose (see the comment in 0002), so inside
them `crypt()` and `gen_salt()` do not exist, and a child's PIN sign-in fails with
`function crypt(text, text) does not exist`. 0008 adds `extensions` to the path of
every `public` security-definer function that calls them. It is safe to re-run.

Plain Postgres puts pgcrypto in `public`, which is why this only showed up on a
real project. `supabase/test/0000_supabase_stub.sql` now installs it into
`extensions` as well, so `testdb.sh` catches the same mistake.

If you add a security-definer function that uses `crypt()` or `gen_salt()`, either
put `extensions` in its `set search_path` or schema-qualify the calls
(`extensions.crypt(...)`).

## 2. Turn on anonymous sign-in

**Authentication → Providers → Anonymous sign-ins → enable.**

This is what lets a child have a session without an email. It is not a way in on
its own: an anonymous user can read nothing until `claim_pupil` checks their
class code and PIN and attaches the session to a pupil.

While you are there, turn *Confirm email* off for now, or your own first sign-in
will wait on an email. In the current dashboard it is under
**Authentication → Sign In / Providers → User Signups** (older dashboards had it
under Providers → Email).

## 3. Google and Facebook sign-in

Both are for **adults only** — a parent or a teacher. A child never gets one.
That is not a technical limit, it is the point: an under-13 should not have to
hold a Google or Facebook account to read Qaida. `ll_adult_session()` in 0005
enforces it by reading `auth.users.is_anonymous`, so a child's session can never
start a household or add a child even if someone calls the function by hand.

**Your callback URL, which both consoles need:**

```
https://<your-project-ref>.supabase.co/auth/v1/callback
```

It is shown on each provider's page in the Supabase dashboard — copy it from
there rather than typing it, so a typo in the project ref cannot cost you an
afternoon.

### Google

1. [Google Cloud Console → Clients](https://console.cloud.google.com/auth/clients)
   → create an OAuth client ID → type **Web application**.
2. **Authorised JavaScript origins**: the address you serve the app from.
   For testing off `llserve.py` that is `http://localhost:8765` — and note that
   Google will not accept a bare LAN address like `http://172.20.10.2:8765`, so
   test social sign-in on `localhost`, not on the wifi address you give a class.
3. **Authorised redirect URIs**: the callback URL above.
4. Copy the Client ID and Client Secret into
   **Supabase → Authentication → Providers → Google**, and enable it.

### Facebook

1. [developers.facebook.com](https://developers.facebook.com) → My Apps →
   Create App → add the **Facebook Login** product.
2. Facebook Login → Settings → **Valid OAuth Redirect URIs**: the callback URL.
3. Use Cases → check that **public_profile** and **email** both say
   *Ready for testing*.
4. App ID and App Secret into
   **Supabase → Authentication → Providers → Facebook**, and enable it.

**Two things about Facebook that will bite otherwise:**

- While the app is in development mode **only people with a role on it —
  admin, developer, tester — can sign in.** Everyone else gets an error that
  looks like a bug in your code and is not. Public sign-in needs Facebook's App
  Review, and a review of an app aimed at children is not a same-week thing.
  Get Google working first and treat Facebook as a later switch-on.
- **Facebook does not always return an email**, even with the permission set —
  the user may not have confirmed one. That is why 0005 decides who is an adult
  from `is_anonymous` rather than from having an email, and why `family_open()`
  falls back to the name you pass it. A parent with no email from Facebook still
  gets a working household; they just cannot be auto-matched to a roster row the
  school entered by email.

### Where people land afterwards

**Authentication → URL Configuration**: set **Site URL** to where you serve the
app, and add anything else you use to **Redirect URLs**. OAuth comes back to the
callback and is then bounced to one of these; an address that is not listed is
dropped, silently, and looks like the login "did nothing".

## 4. Point the app at it

Open the app, click **This device only** in the header, and paste:

- **Project URL** — shown on the project's home page, and under the Connect button
- **Anon public key** — **Project Settings → API Keys**, on the **Legacy API Keys**
  tab, the one labelled `anon` `public`

The dashboard now leads with the newer *publishable* and *secret* keys. The app
expects the legacy `anon` key, so use that tab. Never paste the `service_role` or a
`secret` key into the app: unlike the anon key, those bypass every rule in 0003.

That key is meant to be public and ships in every Supabase web app. What protects
the data is the rules in `0003_rls.sql`, not the secrecy of the key. Leave both
boxes empty and press Connect to go back to working offline.

## 5. Make your own account

Click the chip again → **Teacher or parent** → **Create account** with the email
you put in the seed file → then **Sign in**. A trigger matches you to the roster
row already waiting, so you land with your classes attached rather than in an
empty app.

## 6. Try a child

Sign out, then **I'm a student** → code `QAIDA1` → pick a name → PIN `1234`.

**Every seeded pupil's PIN is 1234.** That is fine on your desk and nowhere else.
Set real ones before a child touches this:

```sql
select set_pupil_pin('<pupil uuid>', '7391');
```

## Checking it yourself

`./tools/testdb.sh` runs all nine migrations against a throwaway Postgres in
Docker and then tries to break them — a child reading another child's garden, a
teacher opening a class they do not teach, a player reading the answer key, a
parent giving points to somebody else's child, a home parent enumerating a
school, a child session trying to add a child, a parent approving their own
request for a class. 184 assertions, and it needs to stay green.

It also checks that the Supabase rules hold on plain Postgres: pgcrypto sits in an
`extensions` schema there, as on a real project.

After the migrations, run this in the SQL Editor; it should return no rows
(a public table without row-level security is open to anyone with the anon key):

```sql
select tablename from pg_tables
where schemaname = 'public' and not rowsecurity;
```

It found two real holes when it was written, both the same shape: a `for all`
policy meant for management also grants `select`, and permissive policies are
OR'd together, so one careless management rule quietly opened every child in the
school to every teacher. That is not visible from inside the app, which is why
the tests exist.

## Class sessions and meeting links

Teachers (and admins) put a dated session on a class and attach the link to an
online meeting; the class's pupils, their parents and the staff press **Join**.
It is under **Class sessions** on every role's menu. Migration 0009 is the whole
backend.

- **Only people who run the class write.** A teacher of the class, or an admin of
  the same school. A pupil or a parent cannot, even from the console.
- **Only people connected to the class read.** An enrolled pupil, a parent of one,
  that class's teachers, the school's admins. Not another school, not another class,
  not an anonymous session.
- **Links come from an approved list.** `school_link_hosts` starts as `zoom.us`,
  `meet.google.com`, `teams.microsoft.com`, `teams.live.com`. A subdomain of one
  (`us02web.zoom.us`) is accepted, a lookalike (`zoom.us.evil.example`,
  `https://zoom.us@evil.example`) is not. An admin edits the list on the Class
  sessions page, under **Approved meeting platforms**. http and https both pass the
  format check; only the approved hosts get through the second.
- A school made after 0009 gets the starting list automatically.

Join opens the link in a new tab with `rel="noopener noreferrer"`, and only when the
link is a plain http(s) address.

## 7. Fees by Direct Debit

This is the only part of the app that moves real money, so read the whole
section before you set any of it up.

**The app never sees a bank detail.** The parent types their sort code and
account number on GoCardless's own page, on GoCardless's domain. What comes
back here is a customer id and a mandate id. There is no form in this app
that asks for bank details, and there must never be one — if you are ever
asked to add one, something has gone wrong.

### What you need from GoCardless

From the GoCardless dashboard, in **Developers**:

1. **An access token.** Create one. Use the **sandbox** one first — sandbox
   and live are separate dashboards at separate URLs, and a live token
   collects real money from real people on your first test.
2. **A webhook endpoint**, pointed at
   `https://<your-project>.supabase.co/functions/v1/gocardless/webhook`.
   Creating it gives you an **endpoint secret**. Copy it then; it is not
   shown again.

### Setting the secrets

```bash
supabase secrets set GC_ACCESS_TOKEN=...        # from step 1
supabase secrets set GC_WEBHOOK_SECRET=...      # from step 2
supabase secrets set GC_ENVIRONMENT=sandbox     # "live" when you are ready
supabase secrets set APP_URL=https://your-app/index.html
```

`APP_URL` is where a parent lands when they come back from GoCardless. It
has to be a real address they can reach — not `127.0.0.1`, which means the
computer they are not holding.

### Deploying the function

```bash
supabase functions deploy gocardless --no-verify-jwt
```

`--no-verify-jwt` is required and is the one thing here worth understanding.
GoCardless's webhook is not a signed-in user and carries no Supabase JWT, so
with JWT verification on, every webhook is rejected and nothing ever updates.
The `/start` and `/collect` routes check the caller themselves — they read
the Authorization header, ask Supabase who it belongs to, and refuse anyone
who is not the right person — so turning the gateway's check off does not
leave them open. The `/webhook` route is protected by the HMAC signature
instead, which is the only thing that could protect it.

### Add what the madrasah charges

As an admin, in SQL or in the app:

```sql
insert into fee_plans (school_id, name, amount_pence, interval)
values ('<your school id>', 'Monthly tuition', 3500, 'monthly');
```

Amounts are in **pence**. 3500 is £35.00. That is also what the GoCardless
API takes, which is why it is stored that way.

### Trying it, in this order

1. In sandbox, sign in as a parent and press **Set up a Direct Debit**. You
   land on GoCardless's page. Use their test bank details — they publish a
   set; do not use a real account.
2. Come back. The screen will say it is checking. That is correct and it is
   not being coy: the redirect proves nothing, and the status only changes
   when the signed webhook arrives. In sandbox that is usually seconds.
3. As an admin, open **Direct Debit** and press **Check**. It tells you how
   many families *would* be charged. Nothing is sent.
4. Only then type COLLECT and run it.

**Step 3 is not optional ceremony.** A collection cannot be undone from this
app. Once a payment is submitted to Bacs, cancelling it is something you do
in the GoCardless dashboard, quickly, and a payment that has already been
taken is somebody's grocery money until it is refunded.

### What is deliberately missing

- **No teacher sees any of this.** Not who pays, not who is behind. If the
  madrasah wants that changed it is one policy in `0007_fees.sql`, and it
  should be a decision somebody takes out loud.
- **Nobody can mark a charge paid from the app.** Not a parent, not an admin.
  Those statuses are written only by the edge function, only in response to
  a signed webhook. There are assertions in the test suite for each of
  those, because an admin who could type `confirmed` could show a term's
  fees collected without a penny moving.
- **No refunds, no retries of a failed payment, no plan per family.** A
  failed charge shows as failed and somebody deals with it by hand. Those
  are the obvious next pieces.

## What is not done yet

- No realtime yet. The quiz tables and scoring are in and tested; the live
  room needs the client half.
- Migrations 0001 to 0007, anonymous sign-in, admin sign-in and the child PIN flow
  have now run against a real project (16 Oct 2026). Everything else here has only
  run against Postgres in Docker.
  **Google and Facebook sign-in cannot be tested there at all**, because the
  provider handshake happens between the browser, the provider and your live
  Supabase project. That part is untested by definition until you do step 3.
  The same is true of everything in step 7: the payment code has been tested
  against hand-built stand-ins for the GoCardless API, which proves the
  shapes and the ordering and proves nothing about the provider.
