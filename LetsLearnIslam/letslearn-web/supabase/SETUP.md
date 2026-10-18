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
| `migrations/0010_timetable_and_classes.sql` | the weekly timetable (no double-booked class, room or teacher), and admin functions to create a class, move a pupil, assign a teacher |
| `migrations/0011_test_student.sql` | a flagged Test Student account, for trying the garden |
| `migrations/0012_teacher_hours.sql` | teacher hours (from the timetable), frozen rates, admin-only pay |
| `migrations/0013_reports.sql` | report recipients and an append-only log of what was downloaded or printed |
| `migrations/0014_pupil_books.sql` | which books each pupil has been given |
| `migrations/0015_homework.sql` | setting, handing in and marking homework, through school-checked functions |
| `migrations/0025_earning_rules.sql` | **how coins are earned, by server rules**: a welcome, the register (paid when the teacher finishes it, with a camera tick), marked homework, and the claims a child can make (practice, dhikr, prayer, reading) under one daily ceiling. Needs 0023 and 0024 first |
| `migrations/0024_points_enum2.sql` | one more kind of coin entry (salah); run by itself before 0025 |
| `migrations/0023_coin_ledger.sql` | **the foundation of server-held coins**: the points table is the one ledger, only functions can change it, a child can spend and take half back but never mint. Needs 0022 applied FIRST and on its own (it adds enum values) |
| `migrations/0022_points_enum.sql` | four new kinds of coin entry (welcome, mission, spend, refund); run it by itself before 0023 |
| `migrations/0021_parent_notifications.sql` | emails to parents, three yeses (school, parent, confirmed address), sent by a separate function that is a dry run until switched live; also: sign-up links to the roster only once the email is confirmed. Read `docs/notifications.md` first |
| `migrations/0020_client_errors.sql` | a scrubbed, minimal log of app errors (no user ids, 30-day retention, admin-only read) |
| `migrations/0019_pupil_report.sql` | the data behind the Report card: a read-only, security-invoker progress report for one child |
| `migrations/0018_pin_reset.sql` | forgot-my-PIN: a child asks, a teacher/parent/admin issues a temporary number (shown once, 7 days), the child chooses their own; easy PINs (1234, 0000…) refused; audit log |
| `migrations/0017_cross_school.sql` | **security fix, apply with 0016:** one school can no longer reach into another (families, class teachers, enrolments, registers, class requests) |
| `migrations/0016_profiles_lockdown.sql` | **security fix, apply first:** nobody can change their own role or PIN hash, or create a profile, from the app |

The app needs **all twenty-five**, 0001 to 0025. Skipping one does not fail at sign-up;
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

`./tools/testdb.sh` runs all twenty-five migrations against a throwaway Postgres in
Docker and then tries to break them — a child reading another child's garden, a
teacher opening a class they do not teach, a player reading the answer key, a
parent giving points to somebody else's child, a home parent enumerating a
school, a child session trying to add a child, a parent approving their own
request for a class. 695 assertions, and it needs to stay green.

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

## Classes and the timetable

**Classes** and **Timetable** are on every role's menu (parents and pupils get a
read-only "My class" and their class's week).

- **Only an admin edits the timetable.** Teachers see the whole school's week, with
  their own lessons outlined, because choosing a room means seeing who has it. Pupils
  and parents see only their own class.
- **The database refuses a clash.** The same class, the same room (any case, any
  padding) or the same teacher in two lessons that overlap. Back-to-back is fine.
  Rooms are per school.
- Times are wall-clock (`time`), not timestamps: 4pm stays 4pm when the clocks change.
- **Creating a class, moving a pupil and assigning a teacher go through three admin
  functions** (`class_create`, `class_move_pupil`, `class_set_teacher`), each checking
  the school. They exist because the older policies they would otherwise use are not
  school-scoped for admins (see `docs/build-notes.md`).

## A test student for the garden

As an admin, open **Classes** and press **Create a test student** (migration 0011).
It makes **Test Student** in a **Test Class** of its own and shows you the class code
and PIN (**1234**). Sign out, choose **I have a class code**, type the code, tap Test
Student and enter the PIN.

Test mode then switches on by itself — unlimited coins, rest and food — and a badge
says **TEST ACCOUNT**. The coins are the device's, not the database's: nothing is written
to `points`, so the record of real children stays real. Calling it again returns the
same student. Do not put a real child in the Test Class, and change the PIN if the
project is ever shared (`select set_pupil_pin('<id>', '7391');`).

## Checking everything: one command

```
./tools/check-all.sh           # llcheck, the dua recording names, every migration and RLS test (Docker), and the live check
./tools/check-all.sh --quick   # same, skipping the database tests (no Docker needed)
```

It stops at the first failure and tells you what to do. A step it skips is announced in capitals and counted,
so "skipped" is never mistaken for "green". Exit codes: 10 llcheck, 20 database tests, 30 Docker not running,
40 live check, 50 recording names.

**The live check** (`tools/livecheck.py`) looks at your real project using ONLY the public anon key. It writes
nothing, signs nobody in, prints no key or response, and refuses a service_role or secret key. It checks that with
the public key every table shows nothing, the PIN columns cannot be selected and the security functions refuse an
anonymous caller, and it tells you **which migrations are applied** (a missing table or function is reported as
"NOT applied"). To use it, put the two values in your own shell for that run only, never in a file in the repo:

```
LL_URL=https://<your-ref>.supabase.co LL_ANON_KEY=<the legacy anon key> ./tools/check-all.sh
```

It cannot see permission-only migrations (0016, 0017) with the public key: confirm those with the query in the
"Apply 0016" steps. A later version, with a test child and test staff signed in, can attack as each role.

## Forgotten passwords

Adults (parents, teachers, admins) can reset their own password from the app: **Continue with an email,
then Forgot your password?**. Children have no password; a grown-up gives them a new PIN.

For the link to land in the app you need three things set in the Supabase dashboard:

- **Site URL** (Authentication → URL Configuration) must be **exactly the address the app is served
  from**, e.g. `http://localhost:8765`. Supabase sends the reset link there. If the app is on a different
  port or address, the link opens somewhere that is not connected. Add the same address under Redirect URLs.
- **Email sending.** Supabase's built-in sender is for testing only: it allows just a few emails an hour,
  and a busy morning of resets would hit the limit. Set up your own under Authentication → SMTP Settings
  before real families use this.
- **Confirm email** should be ON (see HANDOFF).

The reset screen says the same thing whether or not the address has an account, so it cannot be used to find
out who is registered. A new password must be at least 10 characters, must not be a well-known one, and must
not be built from the email address. Setting it signs the person out of their other devices.

If an admin ever locks themselves out and cannot receive the email, the SQL route still works: see "Reset the
admin password" in `docs/build-notes.md`.

## Homework

On the **Homework** screen a teacher presses **Set new homework** (class, title, what to do,
an optional practice to link, an optional due date), and pupils in that class see it at once on
**My homework**. A pupil hands a piece in by finishing the linked practice (it hands in by itself,
and keeps the better score), or by pressing **I have done it** when there is no practice. A teacher
presses **Mark** on a row, gives each pupil a score (it starts as their practice score) and a short
note, and the pupil and their parent can read both. Once marked, a pupil can no longer change it.
Deleting a piece also removes everyone's hand-ins and marks; the screen says how many first.

All of it goes through functions that check the class (`homework_set`, `homework_update`,
`homework_delete`, `homework_hand_in`, `homework_mark`). 0015 also **replaces three old rules**:
any teacher could update any submission, and an admin at one school could read and change another's
homework. A child's re-do could not raise their score before; it can now. Until 0015 is applied to
your project, the screens still work for pupils (the old hand-in path is unchanged) but staff cannot
set or mark homework.

## Uploading a quiz, and giving pupils their books

**Upload a quiz** (teachers and admins, on the Quiz screen). Save a spreadsheet as **CSV UTF-8**
with the columns `question, answer 1, answer 2, answer 3, answer 4, correct, seconds` (the
**Download a template** link shows them), or paste rows straight from a spreadsheet. `correct` is
1-4, A-D, or the text of the right answer; `seconds` is optional. It shows what it understood and
which rows it could not use, then opens the quiz in the normal editor to read through and Save.
Limits: 100 questions, 1 MB, 300 characters a question, 100 an answer. Excel's own `.xlsx` cannot
be read; the page says how to save as CSV. Uploaded quizzes are marked "please read it through
before a class plays it".

**Pupils' books** (migration 0014; on the menu for teachers and admins). Pick a class and tick
which books each pupil has: a column per book (Qaida Levels 1-4, Elementary Books 1-4), a row per
pupil. A row has "Qaida up to Level 2"-style quick choices, a column has **all** / **none** for the
class, and the **Whole class** menu sets a level for everyone at once. A teacher can choose only for
pupils they teach; an admin for the whole school. **A pupil sees only the books they were given.**
A pupil given nothing yet sees the first book of each series. **This decides what a child is shown
in the app; it does not lock the book files**, which are static and lightly obfuscated (the Books
code says it is "NOT DRM"). Real protection is a server that checks the licence and streams a page
at a time.

## Teacher hours, and Reports & email

**Teacher hours** (migration 0012). An admin presses **Generate from timetable** for a week once
the lessons have happened, then removes a lesson that did not run or adds cover. Set each
teacher's hourly rate under **Hourly rates**.

- A rate is copied onto each hour row when it is made, so changing it later never rewrites a
  week that has been paid. Rows made before a rate was set are filled in when you set it.
- A class with two teachers credits both; remove a row where that is not right.
- Lessons that have not happened yet are skipped. Run it again after the week.
- **A teacher sees their own hours, never a rate or a pay figure.** The rate column is not
  readable by them at all. Nobody at another school, no pupil, no parent sees anything.

**Reports & email** (migration 0013). Build the salary, fees, Direct Debit and attendance
reports; **Download CSV**, **Print**, or **Open email draft** (your own mail app, attach the
download). Every one is logged as what actually happened. **It does not send email by itself**,
and it never says "delivered": sending on a schedule needs an email provider (Resend, Postmark,
SendGrid or SES), your domain verified (SPF, DKIM, DMARC) and a scheduled job, which only the
madrasah can set up. The CSV escapes any cell that starts with `=`, `+`, `-` or `@`, so a name
typed as a spreadsheet formula cannot run when an accountant opens the file.

## 7. Fees by Direct Debit

**Where this stands.** The code is all here (migration 0007, the edge function, the parent and
admin screens) and 0007 is applied to your project. **None of it has run against GoCardless,
not even their sandbox**, and you have to do these before it can: open a GoCardless *sandbox*
account; make an access token and a webhook endpoint there; set the four secrets below;
deploy the function with `--no-verify-jwt`. Then a parent presses **Set up a Direct Debit**
(Direct Debit menu), is sent to GoCardless's own page, and the status changes when their signed
webhook arrives. The admin presses **Check**, then types COLLECT.

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
