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

**Before running 0004, change the three email addresses in it** to ones you can
receive at. They are how your admin, teacher and parent accounts get matched to
the roster rows when you sign up.

## 2. Turn on anonymous sign-in

**Authentication → Providers → Anonymous sign-ins → enable.**

This is what lets a child have a session without an email. It is not a way in on
its own: an anonymous user can read nothing until `claim_pupil` checks their
class code and PIN and attaches the session to a pupil.

While you are there, **Authentication → Providers → Email**: turn *Confirm email*
off for now, or your own first sign-in will wait on an email.

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

- **Project URL** — Settings → API → Project URL
- **Anon public key** — Settings → API → `anon` `public`

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

`./tools/testdb.sh` runs all five migrations against a throwaway Postgres in
Docker and then tries to break them — a child reading another child's garden, a
teacher opening a class they do not teach, a player reading the answer key, a
parent giving points to somebody else's child, a home parent enumerating a
school, a child session trying to add a child, a parent approving their own
request for a class. 74 assertions, and it needs to stay green.

It found two real holes when it was written, both the same shape: a `for all`
policy meant for management also grants `select`, and permissive policies are
OR'd together, so one careless management rule quietly opened every child in the
school to every teacher. That is not visible from inside the app, which is why
the tests exist.

## What is not done yet

- The app still **reads** from localStorage. The sync layer pushes the garden and
  practice up and pulls them back on a new device, but the screens have not been
  repointed at the server's copy of homework, attendance and points.
- No realtime yet. The quiz tables and scoring are in and tested; the live room
  needs the client half.
- Nothing has run against a real project — only against Postgres in Docker.
  **Google and Facebook sign-in cannot be tested there at all**, because the
  provider handshake happens between the browser, the provider and your live
  Supabase project. That part is untested by definition until you do step 3.
