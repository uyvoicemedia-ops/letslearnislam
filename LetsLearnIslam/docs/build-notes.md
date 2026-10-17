# LetsLearn — build notes

Single-file prototype: `letslearn-web/index.html` (~33,200 lines, 123 `<script>` blocks),
no build step. Everything is canvas 2D — no image assets, with one deliberate exception:
the quiz question pictures are inline SVG. New work is appended as a marked block before
`</body>` and overrides earlier top-level `function` declarations by reassignment.

**The long-form design context is in `letslearn-web/DESIGN.md`.** Read that before touching
the garden; this file is the short operational version.

## Running it

`python3 tools/llserve.py` — or double-click `start.command`. **Port 8765.**

## Tooling (in the repo, not /tmp)

- `tools/llinsert.py <block> TAG` — backs up, strips a prior copy by marker, inserts before
  `</body>`. Idempotent; refuses a block with unbalanced `<script>` tags.
- `tools/llcheck.py` — `node --check` per block, duplicate lexical globals, assign-to-const.
- `tools/testdb.sh` — applies the eighteen migrations to postgres:16 in Docker, then 601 RLS
  assertions (91 in `0100`, 93 in `0110_sessions`, 51 in `0120_timetable`, 21 in
  `0130_test_student`, 54 in `0140_hours`, 16 in `0150_reports`, 33 in `0160_books`, 54 in `0170_homework`, 32 in `0180_profiles_lockdown`, 30 in `0190_cross_school`). Needs Docker Desktop running (`open -a Docker`, then ~20 seconds). Its
  `supabase/test/0000_supabase_stub.sql` imitates Supabase, including pgcrypto living in an
  `extensions` schema. **When the test database and the real one differ, the test is wrong:
  fix the stub, then prove it fails without the fix.**

## Hard rules learned the hard way

- Top-level `const`/`let` share ONE lexical environment across classic scripts. A duplicate
  declaration is a load-time SyntaxError that silently kills the whole script. `llcheck`
  detects it.
- **A block file missing its closing `</script>` fails no syntax check at all** — the HTML
  parser swallows everything after it and the block silently never runs, with nothing in the
  console. `llinsert.py` refuses an unbalanced block. This cost an hour.
- `mqShade`, `storeDef`, `GARDEN_ITEMS`, `TOYS`, `ROOM_ITEMS`, `PLAN`, `QUIZ_SETS`,
  `MONSTERS` are `const`. To extend a catalogue, mutate the array. **`DB` is the same shape
  and that is now load-bearing**: the LIVE block swaps its arrays for Supabase rows and every
  screen renders live data with no change to the rendering.
- **Anything a user's choice is stored as an INDEX into is append-only.** `MONSTERS` is the
  live case: the pick lives in `ll.qz.avatar`, so reordering turns somebody's creature into a
  stranger's. `QUIZ_SETS` is keyed by id, so pushing into it is safe.
- `PAGES.garden` holds its own reference: reassigning `pageGarden` alone does nothing, you
  must also reassign `PAGES.garden`. Same for `PAGES.dash`. ~18 chained wrappers — patching an
  early one is patching dead code.
- **On Supabase, pgcrypto is in the `extensions` schema, not `public`.** Our security-definer
  functions pin `search_path = public, pg_temp`, so inside them `crypt()` and `gen_salt()` do
  not resolve — child PIN sign-in died with `function crypt(text, text) does not exist`.
  Migration 0008 adds `extensions` to every such function's path. Any new security-definer
  function that hashes needs `extensions` in its `set search_path` or `extensions.crypt(...)`.
  Plain Postgres hides this, which is why 91 green assertions missed it.
- **`ll_teaches()` is not school-scoped for admins.** Its `or ll_role() = 'admin'` passes for a
  class at ANY school, as do the `admins assign teachers` policy and any other
  `ll_role() = 'admin'` without a `school_id` check. Harmless with one school, a cross-school
  hole with two. 0009 avoids it with `ll_manages_class()`; the older ones still need their own
  migration and a second school in `0100`. Class sessions' tests already build a second school.
- **`profiles` has COLUMN-level select grants (0001, 0005) so the PIN hash can never be read.**
  A new column on `profiles` is invisible to the app until you `grant select (col)` — the symptom
  is "permission denied for table profiles", not a missing column.
- **A password-recovery link is a sign-in.** Supabase signs the person in with a recovery session as soon
  as the link opens, so the app must show "Choose a new password" BEFORE doing anything else (PWRESET wraps
  `llaBoot` for this), and must read the `#...type=recovery` token at page load, before the library
  swallows it. The link goes to the project's **Site URL**; a different port or address means it lands in an
  unconnected app. The "email sent" screen is deliberately identical for known and unknown addresses.
- **Reset the admin password without email (owner only, SQL Editor):**
  `update auth.users set encrypted_password = crypt('NEW-LONG-PASSWORD', gen_salt('bf')) where email = '…';`
  then clear the editor. `crypt` resolves in the SQL Editor because pgcrypto is in `extensions` (see 0008).
- **The coin economy is client-side, and that is the real problem.** `g.deeds` is saved on the device and
  pushed inside the garden blob that loads back over the balance, so a child can edit it. ECONFIX only closes
  the cheap exploits found by the audit (dhikr uncapped ~1,000/hour, salah tick/un-tick +20 per two taps,
  "Bring them across" paying 3/star on stars that already paid 4/star, sleep up to 80 for any nap, club
  likes/joins re-paying on every toggle, the unlimited-coins chip on every role). It cannot stop developer
  tools. Real fix = server-minted coins (ledger with a unique `(pupil, source, source_ref)`); design in the
  audit: G1 forgery-proof ledger, G2 server-held wallet and spending, G3 server inventory (not recommended).
- **A safety net must say what it did NOT check.** `check-all.sh` prints SKIPPED in capitals and counts
  skipped steps, and ends "that is not the same as everything being checked", because a green line after a
  silent skip is how a hole ships. `livecheck.py` was validated against a stand-in PostgREST in three modes
  (clean, leaky, an older project missing migrations) because the real project cannot be attacked from here.
- **Test helpers must pass their arguments.** `const E = (f) => p.evaluate(f)` silently dropped the second
  argument, so `sleep(8)` became `Date.now() - undefined` = NaN and passed in isolation but not in the suite.
- **`ll_teaches()` and "is this an admin?" are not school checks.** Reproduced: an admin at another school,
  with only a class code (which `class_roster()` gives to anyone), INSERTed a `guardians` row linking
  themselves to our child and could then read the child's profile, practice, attendance, garden and
  points. 0017 removes the direct-write rules on `guardians`, `class_teachers` and `enrolments` (the app
  only ever writes them through definer functions), scopes the register to "you run this class AND the
  pupil is in it", and moves `class_request_decide` / `ll_offered_to_me` / the request-reading rule to
  `ll_manages_class` (school-scoped). **Any new policy that says `ll_role() = 'admin'` or `ll_teaches(...)`
  with no school test is the same bug.**
- **RLS limits ROWS, never COLUMNS, and Supabase grants signed-in users every privilege on a new table.**
  `profiles` had "edit your own name and avatar" (own row only) and "staff edit people", but nobody
  had revoked table-level UPDATE/INSERT, so a child could `update profiles set role = 'admin'` on
  their own row, write their own `pin_hash`, and a teacher could write any pupil's `pin_hash` or
  INSERT a new admin profile. Reproduced against the test DB before it was fixed (0016: revoke
  INSERT/UPDATE, grant UPDATE only on `full_name, avatar`). **Any new table, and any table you did
  not revoke on, needs the same question asked: which columns can a signed-in user actually write?**
  `points`, `homework` and `submissions` were already safe; check `garden`, `practice`, `reading`
  and the club tables next.
- **Homework was a screen of placeholders, and the old rules were broader than they looked.** The
  `Set new homework` / `Mark` buttons had no handler; `staff mark work` let ANY teacher update ANY
  submission; the admin branch of `ll_teaches` let an admin at one school read and change another's
  homework; a child's re-do upsert failed silently (a child has no UPDATE right). 0015 replaces all
  three policies and routes every write through `homework_*` functions. The LIVE block's old hand-in
  upsert still fires first and is harmless; HWK's `homework_hand_in` does the real work.
- **Never store test state on `window.<name>` of something the app already defines.** A test that set
  `window.me = 'p1'` overwrote the app's own `me()` and failed three assertions later with
  `me is not a function`.
- **An upload feeds the editor, it does not save.** QZUP builds `QA.draft` and opens `qaPaint()`; the
  teacher reads it and Saves, so `qaSave` still validates and the school sync still wraps it. A
  second way of writing to the quiz store would have meant a second set of rules to keep in step.
- **Hiding a book is not locking it.** `pupil_books` + the filtered shelf decide what a child is
  shown. The `.llb` files are static and XOR-obfuscated; anyone told a path can fetch one. Do not
  describe this as protection.
- **Playwright's `check()` fails when the app correctly un-ticks a box** (an optimistic tick put
  back after the school refused). Use `click()` for refusal cases and assert the state yourself.
- **Salary data is protected in three layers.** `hours_log.rate_pence` is not granted to
  `authenticated` at all (column grants, as for `profiles`), `hours_week()` returns the rate and
  pay only to an admin, and the RLS policies let a teacher read only their own rows. A frozen rate
  on each row means a rate change can never rewrite a paid week. `hours_week` is a function, not a
  view, because the decision is per caller.
- **CSV injection.** Anything a person typed (a pupil's name) can start with `=`, `+`, `-` or `@`
  and run as a spreadsheet formula. `ofCell()` prefixes such cells with `'`; the browser test feeds
  it `=HYPERLINK(...)`.
- **PostgREST returns at most 1000 rows per request.** Reports page through with `.range()`
  (`ofAll`); a plain `select()` would silently drop attendance after a month in a big school.
- **The quiz block puts its own link on the menu** (`a[data-quiz]`, no `data-page`), so it is not in
  `NAV`. The guide special-cases it. If another block does the same, add it there too.
- **Help text is part of the product, and it must be true.** `GD_HELP` was written from what each
  screen really does, including what it does not. Reading the code first found that the teacher
  Homework screen's "Assign to whole class" and "Mark" buttons were placeholders (no handler; now built, see HWK), that
  attendance's Clear only resets the buttons (it does not unsave), and that there is no excused
  button. An earlier tour step claimed teachers could "set homework" and that marked work reached
  the parent; it was false and has been corrected. When a screen changes, change its `GD_HELP`.
- **The tour opens the screen by itself** (`gdArrive`): it navigates, lights the menu item, then
  rings a control found by `point: { sel | text }`. A screen may build itself after the school
  answers, so the control is looked for for ~4 seconds and, if it never appears (the demo shows
  different screens), nothing happens. The page is scrolled to it once per step, because the ring
  is re-applied on every `render()` and ticking a box must not yank the page about.
- **When replacing a slice of a block, grep what lived inside it.** The coach-card rewrite swallowed
  the Escape-key handler, and a follow-up `str.replace` that expected to find it matched nothing and
  said nothing. Assert the old text is there (`assert old in s`) every time.
- **`innerText` applies `text-transform`.** A heading styled uppercase reads "WATCH OUT" to a test.
- **A guide that names menu items must resolve them.** `GD_TOURS` finds each "Show me" target by its
  menu label; the browser test fails if any label is missing from that role's menu.
- **macOS `sed` has no `\b`.** `sed -E 's/\bGD\b/…/'` matches nothing and exits 0; use Python.
  `llcheck` caught a `const GD` that clashed with an existing global before it shipped.
- **Safari and iOS will not play audio from a server that ignores `Range`.** `python3 -m http.server`
  (and `llserve.py` until now) answer `Range: bytes=0-1` with a whole-file 200; Safari gives up and
  the clip never plays, while Chrome carries on and hides the bug. `llserve.py` now returns 206/416
  and `python3 tools/llaudio.py selftest` proves it. Audio is also the one path allowed to cache
  (`/audio/`, one hour); everything else stays `no-store`.
- **Dua audio is found, not listed.** A play button exists only if `audio/<slug>.mp3|m4a` answers
  `HEAD` with an `audio/*` type (a host that serves its home page for every missing path must not
  conjure buttons). The answer is cached and cleared on window focus, so dropping a file in shows
  up with no reload. Slugs: `dua-<kebab id>` for `DUAS`, `dhikr-<say>`, `salah-<id>`, and
  `practice-…` from the `DA_PRACTICE` table, which `llaudio.py check` compares to the practice
  data so a new step cannot be added without naming its recording. `llaudio.py list` prints the
  Arabic from `index.html`, never from anyone's memory.
- **Arabic appears in four places that are rebuilt differently** (the dua card replaces its HTML,
  the practice card replaces it per step, the dhikr word rewrites one text node, the salah list is
  a template). DUAAUDIO therefore does not wrap them; one `MutationObserver` + `daSync()` finds the
  Arabic on screen and keeps exactly the right button beside each. "Stops when the card changes" is
  just "the Arabic it belonged to is gone". While a card is open only its own Arabic counts, or a
  clip could be started from underneath a modal.
- **The eating duas already existed** (`DUAS.eat`, `DUAS.eatAfter`, with sources) and the kitchen's
  Eat button already runs before -> food -> after. The kitchen entry only OFFERS them, through
  `Garden.planWas`, the same room-change signal the washroom uses; it never touches `gardenEnter`
  (DESIGN.md 7b). A forced dua on entry was rejected: a child passing through would be asked, and the
  first-time-today +2 coins would be easy to farm.
- **Testing browser behaviour that needs files:** build a throwaway copy of the app in the scratchpad
  (`index.html` + generated mp3s via `ffmpeg`), serve it with `LL_ROOT=<dir> python3 tools/llserve.py
  <port>`, and drive it with Playwright. Never put test audio in `audio/`.
- **A statement cannot see its own volatile function's writes.** In a test, `perform
  t_assert(f() ->> 'ok' and (select … from t) = x)` reads `t` from the snapshot taken before
  `f()` ran. Call the function first, then assert in a second statement.
- **Drawing overlapping timed blocks needs lanes.** Different classes may legitimately run at
  the same time, so absolutely-positioned lessons must be split side by side (`scLanes`).
- **A browser to look with:** `npm i playwright` in the scratchpad (not the repo), serve the
  folder with `python3 -m http.server 8766 --bind 127.0.0.1`, and screenshot. A fresh browser
  has no Supabase config, so it runs in demo mode and touches nothing real. To exercise the
  live code paths, set `LLC.sb` to a chainable stub and `LLC.profile`, then `scPull()`.
- **Never put the `service_role` or a `secret` key in the app.** The client takes the project
  URL and the legacy `anon` key only. No key or password goes in the repo, a log or a commit;
  the seed with real emails (0004) is run from a copy outside the repo (`~/ll-local/`).
- **A function reference captured in an `onclick` does not follow a later reassignment.**
  But `onclick="mark(this,'p')"` resolves through `window` at call time, so reassigning
  `window.mark` IS enough — the two cases behave differently.
- **A wrapper that snapshots state before calling the original gets the unvalidated copy.**
  `qaSave` validates the draft IN PLACE. The QZDB wrapper copied it first and sent that to the
  database, so the school got empty answer tiles. Capture the id, call the original, read back.
- **Check whether a thing already exists before adding it.** QZFX added a streak the QZPOD
  block was already counting, and every child looked exactly twice as hot as they were.
- **Specificity beats later.** KIDUI sets sizes with `!important` at a higher specificity; a
  later `!important` at lower specificity loses. Spell out `body.kid` when overriding.
- Isometric: `isoPt(u,v,W,H)` → `x = W/2 + (u-v)*tw/2*z - cam.x`,
  `y = H*0.42 + (u+v)*th/2*z - cam.y`, `ISO = {tw:68, th:34}`. Paint far-to-near.
- **Screen x runs with `(u - v)` and screen y with `(u + v)`, so the corner where BOTH are
  small is straight behind a building and nothing put there is ever seen.**
- House walls are `WH = 1.15`. Nothing indoors may be taller.
- The modifier half-ring `ʿ` (ayn) is missing from the UI font. Use a plain apostrophe.
- **Mixing Arabic into an English string is a bidi hazard.** Close the Arabic run with a
  left-to-right mark (U+200E) before appending.
- **Media queries measure the viewport, not the container.** An
  `<iframe src="/index.html" style="width:390px">` is the only honest way to test the phone
  layout — drive it with `frame.contentWindow.eval("…")`.

## Before you commit

`./tools/check-all.sh` (add `--quick` without Docker) runs llcheck, the recording-name check and every database
test, and with `LL_URL` / `LL_ANON_KEY` set also checks the live project read-only. It stops at the first failure
and says loudly what it skipped. `tools/livecheck.py` needs only the public key and refuses a service_role key.

## The blocks that matter, newest first

| Block | What it does |
|---|---|
| `PWRESET` | adults reset a forgotten password from the sign-in screen (Supabase recovery link, neutral wording, new-password screen) |
| `HWK` | set / hand in / mark homework for staff, pupils and parents (0015) |
| `BOOKSEL` | the Pupils' books grid for staff; a pupil's shelf shows only the books they were given (0014) |
| `QZUP` | upload a quiz from a CSV or a paste; hands it to the normal editor and `qaSave` |
| `ECONFIX` | client-side patch for the cheapest coin exploits (dhikr cap, salah once a day, no practice double-pay, sleep cap, club once, no test chip for real children); all numbers in `EC` |
| `GUIDE` | a tour per role that opens each screen and rings the control by itself; "More about this"; a ? Help drawer on every screen with help (`GD_HELP`, richest for teachers); a Guide page; progress per device |
| `OFFICE` | Teacher hours and Reports & email on real data (0012, 0013) |
| `DUAAUDIO` | play button on every Arabic dua/step/dhikr/prayer name that has a recording; the eating-duas offer in the kitchen |
| `TESTSTU` | test student: admin button on Classes, badge, auto test mode for `is_test` pupils |
| `SCHED` | the Classes and Timetable pages (were `pageSimple` stubs); lanes for overlapping lessons |
| `SESS` | class sessions with a meeting link; new `sessions` page on every role's menu |
| `SOLOQZ` | the practice quiz on the live quiz's coloured tiles, 2×2 |
| `QZFX` | countdown, answer-distribution bars, points fly-up, rank arrows, 3-2-1 |
| `PAY` | the fees and Direct Debit screens |
| `GFIX` | wudu prompt, the practice log on Progress/Rewards, Build sub-tabs |
| `QZDB` | quiz sets from Supabase, with opt-in sharing |
| `LIVE` | every screen reads the school instead of the demo |
| `AUTH` / `CLASSREQ` | the sign-in gate, and asking a school for a place |
| `CLOUD` | the Supabase connection and sync |

## The quiz

Transport order in `QuizNet.open`: Supabase if configured → the LAN relay → BroadcastChannel
→ nothing. Each client stamps a `src` so the relay never echoes to its author. **The relay
payload key is `m`.**

Performance rules, because a class answers all at once:
- `quizPaint()` coalesces renders to one per frame. **Never call `render()` from a message
  handler.**
- An answer writes the counter into the DOM (`quizTouchCount`) rather than repainting.
- Measured: a question plus 25 answers = 1 render, 8 ms.

`quizTell` sets `q` to null once a question is over, so at reveal the player's phone has no
answer text — QZFX sends the texts along with the counts.

## Standing product constraints

- PDF books must not be downloadable, printable or shareable.
- Faceless human characters; mosques labelled "inspired by"; the garden is never called a
  picture of Jannah.
- Duas, practice steps and the deen quiz sets use well-known authentic texts with the source
  shown. **A teacher must check the Arabic and the order before classroom use.**
- Decorative bands are geometric strapwork, never letter-like.
- The energy/food gate never touches worship.
- **Children under 13 never get a Google or Facebook account for this.**
- **Nobody should be able to mistake the demo for the school.**
- No bank details, ever. See `docs/payments.md`.

## Testing loop

Write block → `python3 tools/llinsert.py blocks/x.html TAG` → `python3 tools/llcheck.py` →
reload → drive from the browser console → screenshot and zoom to judge.

Persistent test artefacts, not bugs:
- `requestAnimationFrame` pauses when the tab is hidden. Step frames with
  `gardenFrame(ctx, W, H, t)` — passing a timestamp first corrupts the frame.
- `render()` replaces the canvas, so cached element references go stale.
- **Query the DOM straight after the render you mean to inspect.**
- A cheap whole-app smoke test: loop every `role` and every `page` in `NAV`, call `render()`
  in a try/catch, collect what threw. Run it with test mode ON and OFF.
- **A hand-built stub standing in for PostgREST is worth the twenty lines.** The chainable
  `select().order().eq()` shape is easy to fake, and it caught both QZDB bugs and both PAY
  bugs without a project existing.
- There is no `go()` — set `role`/`page` and call `render()`. **`quizAsk()` increments
  `QZ.ord` itself**, so set `QZ.ord = n - 1` before calling it.

## State as of 16 Oct 2026

123 blocks, llcheck clean, 91 RLS assertions green, whole-app smoke test clean in and out of
test mode, the LAN relay round-tripping, and both quiz screens measured in a real 390px
iframe.

**First real Supabase project connected (project "letslearn", London).** Migrations 0001-0008
applied in the SQL Editor, the "no public table without RLS" check passed, anonymous sign-in
on, Confirm email off, Site URL and Redirect URL `http://localhost:8765`, app connected via
"This device only". Admin sign-in and the child PIN flow (QAIDA1) work.

First real-service bug, found within minutes: the pgcrypto search_path problem above. The
fixture-based tests could never have caught it; the stub now reproduces it.

Dashboard layout has moved: *Confirm email* is under Authentication → Sign In / Providers →
User Signups, and keys are under Project Settings → API Keys with a Legacy tab (the app wants
the legacy `anon` key). `supabase/SETUP.md` is updated.

**Still never run against GoCardless, not even sandbox,** and everything in the client that
touches the school beyond sign-in is still only proved against fixtures. Google and Facebook
sign-in are untested by definition.

## Forgot my PIN (0018 + PINRESET block)
- A child cannot reset their own number: they press "I forgot my number", which only tells a grown-up. The request call always answers ok, so it cannot be used to discover who exists.
- Adults (teacher of the child's class, linked parent, admin of the child's school) issue a temporary 4-digit number, returned once and never stored in clear. Signing in with it forces the child to choose their own (`pin_choose_new`).
- Easy numbers are refused in the database (`ll_pin_trivial`) and mirrored in the browser (`pnTrivial`). Keep the two lists identical.
- Existing seeded PINs such as 1234 are not changed automatically; flagging them is a manual step to be run by hand after review.
- Browser check: 52 stubbed-database assertions passed (child flow, adult page, temp number shown once and wiped, admin log, parent view).
