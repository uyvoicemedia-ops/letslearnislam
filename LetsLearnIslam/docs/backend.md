# LetsLearn — the backend

Supabase. Files in `letslearn-web/supabase/`, setup steps in `supabase/SETUP.md`.
Run `./tools/testdb.sh` after any change to the SQL — it applies all seven migrations to a
throwaway Postgres in Docker and then tries to break them. **91 assertions.**

## How people sign in

Two front doors that meet in the middle.

**Grown-ups** — parents and teachers — use Google, Facebook or an email and password.
**Children** never sign in. They have no email, are mostly under 13, and get a class code
or a household plus a PIN instead.

Social sign-in is for adults only, and that is a rule about children rather than about
plumbing: an under-13 should not have to hold a Google or Facebook account to read Qaida.
`ll_adult_session()` enforces it by reading `auth.users.is_anonymous`, so a child's session
can never start a household or add a child however the function is called.

The child flow looks like a detour and isn't. Verifying a PIN has to happen where the
client cannot see the hashes; minting a session normally needs the service-role key, which
must never reach a device. So: the browser calls `signInAnonymously()`, which mints a real
JWT client-side, then calls `claim_pupil()` (class code) or `claim_child()` (household),
which check the PIN and point the pupil's profile row at that anonymous uid. Every policy
afterwards keys off `auth.uid()` exactly as it does for an adult. No service key on the
device, no edge function.

Both doors share one brute-force guard, `ll_pin_ok()` — five wrong goes and the account
rests fifteen minutes.

Re-claiming from a second device with the correct PIN is allowed on purpose — the PIN is
the credential, so a child who moves to a new tablet should get their garden back.

## Households, and who may make a child (0005)

`families` is a household. A parent who signs in and is on nobody's roster gets one via
`family_open()` — idempotent. `profiles.school_id` is nullable; `profile_belongs_somewhere`
stops anyone floating free.

- A parent adds their own children with `family_add_child()`. They start with a family and
  **no school**, and can read, practise, pray and garden at home immediately.
- Joining a class is the school's decision. The parent asks with the class code
  (`family_request_class`), a teacher answers (`class_request_decide`), and **approving is
  the only thing that writes an enrolment or stamps a school onto a child.**
- A stranger who signs in with Google becomes a **parent of an empty household** — never a
  teacher, never an admin, attached to no school.
- There is deliberately **no insert policy on `profiles` for parents**. Adding a child goes
  through the security-definer function, so a parent cannot hand-write a row with role
  `admin`, somebody else's `school_id`, or no PIN.

## Sharing a quiz set (0006)

`quiz_sets` is readable across the school; `quiz_questions` was readable only by the set's
owner. So every teacher could SEE a colleague's set in the picker, choose it, and start a
game with nothing in it.

The tempting fix — let all staff read all questions — turns a passing security test red:
*"a colleague cannot read someone else's answer key"*. So sharing became a decision:
`quiz_sets.shared`, default false, which is exactly the old behaviour. A teacher ticks it to
hand their set to the madrasah, and only then can a colleague read its questions.

**A child cannot read the questions of a shared set either** — there is an assertion saying
so. Every new policy requires an adult role, and the answer key lives in the row.

0006 also adds `quiz_sets.grp` (picker heading), `quiz_sets.note` (the warning shown in the
host lobby) and `quiz_questions.pic` (a teacher's explicit picture choice).

## Fees (0007)

See `docs/payments.md`. The short version: no bank detail ever reaches this database, and
clients write nothing to `mandates` or `fee_charges` — only the edge function does, only in
response to a signed webhook.

## Traps this hit, all worth remembering

**A `for all` policy also grants `select`, and permissive policies are OR'd.** One
"staff manage their school" rule quietly handed every teacher every child in the building,
while the narrow read policy sat right above it looking correct. Reading a person and
managing a person are separate policies now. The same shape was lurking in `enrolments`,
`quiz_sets` and `quiz_questions` — three times.

**A column-level revoke does nothing against a table-level grant.** `revoke select
(pin_hash)` left the hashes readable, because Supabase grants table-wide `select` on new
public tables. The fix is to revoke the table grant and re-grant an explicit column list —
which also means a column added later is invisible until someone deliberately adds it.

**A policy that reads a table whose policy reads back recurses.** A teacher must see the
*name* of a child offered to their class before deciding, so the `profiles` policy consults
`class_requests` — and `class_requests`' own policy consults `profiles`. The way out is
`ll_offered_to_me()`, `security definer`, which reads the table without RLS.

Neither of the first two is visible from inside the app. Both were caught by the test suite,
which is the argument for having one.

## Quiz scoring is server-side

`quiz_answer()` takes only the choice. The server reads `asked_at`, works out the elapsed
time itself and decides the points. If the client sent its own timing, the first child to
open the console would post `ms: 0` and win every round for the rest of term.

## The client layer

Six blocks in `index.html`: `CLOUD` (connection and sync), `AUTH` (the gate), `LIVE` (the
screens), `QZDB` (quiz sets), `PAY` (fees), `QZFX`/`SOLOQZ` (the quiz UI).

The rule they obey: **with no keys set, nothing changes.** `CLOUD` wraps `llSave` and
`llRecord` rather than replacing them, localStorage stays what the app reads from, and the
network is a background errand that can fail silently.

**`LIVE` is what finally made the backend do anything.** `DB` is a `const` binding but a
mutable object, so `llvAdopt()` replaces `DB.classes`, `DB.students`, `DB.homework` and the
`HOMEWORK` array with server rows, and every existing screen renders live data unchanged.
`me()` becomes the signed-in profile. The register upserts on `(pupil_id, on_date)`.

A banner on every records screen says whether it is the school or the demo.

## Running it in a classroom with no Supabase at all

`tools/llserve.py` (or `start.command`), **port 8765**. Standard library only:

- binds every interface and prints the **wifi address** to give the class;
- **relays the quiz between devices** over HTTP long-polling — `POST /api/quiz/<ROOM>` with
  `{src, m}`; `GET /api/quiz/<ROOM>?since=N&src=ID` held open 25s. **The payload key is `m`**
  — a POST with the message under any other key is accepted, stored and delivered as null;
- answers `GET /api/ping`; sends `Cache-Control: no-store`.

**The printed address goes stale when the Mac changes network** — this has cost time twice,
both times looking exactly like the page being broken. Check `ipconfig getifaddr en0` first.

## Not done

- **Never run against a real Supabase project** — only Postgres in Docker. The client side of
  `LIVE`, `QZDB` and `PAY` was proved against hand-built fixtures standing in for PostgREST,
  which catches shape and ordering bugs and cannot catch an RLS surprise. **Google and
  Facebook sign-in cannot be tested in Docker at all.**
- Realtime over Supabase: tables, scoring and the client half are written, only the LAN relay
  has been run.
