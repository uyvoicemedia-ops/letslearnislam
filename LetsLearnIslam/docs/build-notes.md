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
- `tools/testdb.sh` — applies the twenty-six migrations to postgres:16 in Docker, then 695 RLS
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

## Noticed outside the garden (garden-UI session, not touched)
- Phone width: the top menu row is cut off ("My garde…"), and the connection chip shows only an empty dot with no label.
- Phone width: the page title wraps to "My / garden" beside the coins and buttons.

## Garden UI, direction A "Pocket Camp" — (a) HUD and shop chrome (block GARDENUI)
- Adds class `gui` to `.garden-wrap` and `gui-head` to the header (student only), then `guiEnhance` (a mount job) moves the existing `.deeds` and `.needs` elements onto the canvas as a floating HUD (ids and handlers unchanged) and splits each tab's emoji into icon-over-label. `render` is wrapped only to set `body.gui-garden`.
- Tabs are a fixed bottom dock at <=1000px, a tile grid beside the garden on desktop. Shop items are cards with a coin-tag price; zoom and "Move things" are 44px; "Move things" moved bottom-left so it no longer covers buildings.
- **Trap:** the page entrance animation (`fadeUp ... both`) leaves an identity `transform` on `main > .garden-wrap`, and a transformed ancestor turns `position:fixed` into `absolute`, which hid the dock below the page. Fixed with `animation-fill-mode: backwards` on `.gui`.
- Checked at 390, 820 and 1440 wide; Plant tab and picking an item still work, no page errors. Not yet measured: frame time (comes with block b).

## Garden UI — (b) lighting and ambient life (block GARDENLIGHT)
- A layer of plain elements (`.gl-fx`) above the canvas: warm light + vignette (cool moonlight at night, orange at sunset), three drifting cloud shadows, twelve dust motes by day and fireflies by night. All CSS: a gradient plus `transform`/`opacity` animations the compositor runs off the main thread. The garden's frame loop is untouched. Hidden inside buildings; `prefers-reduced-motion` keeps the light and removes everything that moves; not part of "Save a picture".
- **Night follows `skyIsNight(style.sky)`, not `g.night`** — the canvas decides from the chosen sky, and the two can disagree.
- **Why not on the canvas:** the first version drew the light and motes in `gardenFrame`. With the canvas flushed each frame (a 1px `getImageData` forces the raster) it cost +5-7ms on an 800px garden, of which the static light blit alone was 1.5-3.5ms. Without the flush a canvas timing is meaningless: it only measures queueing (0.15ms for a whole frame).
- Measured after the move (headless, software raster, flushed): 2.3ms at 370px, 6.2ms at 796px, 6.9ms at 828px, the same as before the change. Those are laptop numbers, not tablet numbers. `?perf=1` shows the garden's own frame time on screen; use it on the device.
- Not done in (b): per-object ambient shadows and grass sway. They would mean patching individual item drawers, which are many and chained; left for a later pass if wanted.

## Garden UI — (c) placement (block GARDENPLACE)
- Outdoors only (indoor furniture is unchanged). A ghost of the item follows the mouse/finger, snapped to a square, green if free and red with a cross if not (`isoWalkable` decides; a building or solid thing blocks, flowers do not). Placing on a taken square is now refused with a toast.
- Touch: the first tap only stages the ghost; a "Place here / Cancel" bar commits. Mouse: click commits. `gardenPlaceHere` is wrapped, snapping `p.u/p.v` and registering an undo.
- Undo lasts 9s and refunds the FULL price (selling still refunds half). It does not refund the energy `needsSpend` took.
- **Found while testing:** the original pointer handlers never pan while `Garden.placing` — a finger drag only moves the hover. And a pan, when it does happen, eases home the moment you let go (the follow-camera skips easing only while `Garden.panning`). So "keep the pan" meant: two-finger pan/pinch while placing, camera held via `GP.hold` (frame wrapper sets `Garden.panning` for the duration of one frame) and an accessor on `Garden.cam2` that ignores the original's delayed `cam2 = null`.
- Pinch zoom scales the camera offset with the zoom so the middle of the view stays put (the old `isoZoom` recentred on the character). Ctrl/Cmd+wheel zooms; a bare wheel still scrolls the page. Pinch handlers are capture-phase and `stopImmediatePropagation()` so the garden's own tap logic never sees a pinch; the first finger is cancelled by calling `canvas.onpointercancel()` (otherwise lifting the fingers places an item).
- Tests (stubbed in-page, synthetic PointerEvents for pinch): 28 checks, all passing.

## Garden UI — (d) delight (block GARDENJOY)
- Coins fly from the HUD pill to the placed spot on a curve, a ring ripples there, "−25" floats up, the counter counts down, one short chime. Reduced motion: only the "−25" fades in place and the number updates at once. A tick sounds for each new square while the ghost moves (<=8/s). One-time tip (`ll_gj_tip1` in localStorage, yes/no only).
- Phone garden canvas is now ~square (was 52% of the width, ~230px): `gardenRedrawAt` after `gardenMount` at <=700px.
- Student tour text for the garden now says you see where it will go and can take it back (the guide must not describe things that are not there).

## Garden UI — Step 4 accessibility (block GARDENA11Y)
- **Measured, not guessed.** An audit of text contrast against the real background and the size of everything pressable, over every garden tab at phone and desktop width. Found: the brand green #268c73 under white is 4.13:1 (needs 4.5); grey notes 4.47; red prices 3.96; salah "Tick" 34px and Girl/Boy 33px tall. Fixed inside the garden only: green -> #1f7a62 (5.3:1), notes -> #5d6470, prices -> #b3342f, min-height 44px. Re-run: 0 small targets, 0 contrast failures except a decorative lock emoji (1.97, `aria-hidden` candidate). The brand green itself is used app-wide and was NOT changed outside the garden.
- Keyboard: while placing, arrows move the ghost along the squares (grid axes, not screen directions), Enter places, Escape cancels; Ctrl/Cmd+Z undoes; +, -, 0 zoom and centre. Buttons keep their own keys, and typing in a field is left alone. The window listener is capture-phase with `stopImmediatePropagation()` so the old arrow-key walking does not also fire.
- Screen readers: canvas has `role=img` and a summary label; zoom buttons are named; the menu is a labelled group; a polite live region (`#gaLive`) announces ghost square and free/taken, placed, taken back, cancelled.
- Reduced motion: the canvas scenery stands still by wrapping the drawers that take a time argument (`GD2.sky`, `GD.sky`, `GD.river`, `IB.mosque/school/house/tree/item`) to pass `t = 0`. **The character still animates and walks**, because the garden derives movement `dt` from `t` differences in its frame; freezing `t` globally makes the child unable to move (a real trap — do not do that). Verified: idle garden differs between frames in 215 px (the child) vs 708 px with motion on.
- Forced-colours (Windows high contrast): controls keep a 2px border; selected ones use Highlight.
- The three items first listed here as "not done" were then done (see "Remainders" below).

## Garden UI — remainders (GARDENPLACE / GARDENA11Y / GARDENJOY)
- **Indoors now has the ghost, snap, confirm and undo.** `gpOn()` replaces the outdoors-only test: true outdoors, or inside any building drawn from a plan (`planActive()`). Indoor squares are half-size; "taken" = outside a built room (`planRoomAt`) or within 0.45 of other furniture. Built-in fixtures (the sofa) are NOT detected: their positions are box corners, not centres, so a distance test would be wrong; the picture draws them in order. Undo now remembers the LIST it went into (`g.planFurn` is swapped per building) and only shows where it was placed.
- **Move placed things with the keyboard.** Tab to the garden (canvas is `role=application`, focusable), `[`/`]` choose, arrows move one square (half a square indoors), Escape lets go. Selection re-renders the page, so a `refocus` flag puts focus back on the new canvas. The house and big buildings are still drag-only.
- **A hidden list says what is there** (`#gaList`, after the stage, rebuilt on mount and after each keyboard move): "Date palm, square 4 across, 3 down"; indoors "Rug in the hallway, ...".
- **Found by testing:** the "Tap where the X should go" pill sat over the small indoor canvas and swallowed the mouse, so no ghost appeared beneath it. It is now `pointer-events: none` except its Cancel button.
- Burst/coins now land on the square the thing really went to (read from the undo record), not the raw tap.
- Tests: 21 checks for these (SR list, pick/move/edge/blocked, indoor ghost/place/undo/keyboard), plus all earlier garden suites re-run green; whole-app smoke clean in and out of test mode.

## Backups (tools/backup.sh, tools/restore.sh, tools/backup-selftest.sh, docs/restore.md)
- `backup.sh run` = `pg_dump` in a throwaway postgres container (nothing installed on the Mac) of the `public` schema plus `auth.users`/`auth.identities`, encrypted (age if installed and a recipient is set, else openssl AES-256-CBC/PBKDF2 with a passphrase file), written outside any git repo (refused otherwise), mode 600, with a checksum, read back to prove it is whole, then pruned to the newest 14. Secrets only from mode-600 files, never printed.
- **The self-test found a real hazard:** a plain restore into a Supabase-like database made tables with the default grants (`alter default privileges ... grant all` to anon/authenticated) and the dump only ADDS grants, so `anon` ended up with table rights the migrations had revoked (the 0016/0017 holes, reopened). `restore.sh` switches the default grants off while the tables are created and puts them back after; the self-test compares every table, function and sequence permission and fails if they differ (mutation-checked: removing that step fails two checks).
- Other traps hit: `pg_dump --schema=public` emits `CREATE SCHEMA public`, which fails because it already exists (stripped at dump time); `grep -q` in a pipe under `pipefail` reads as a failure when the dump is large (used one-pass `awk`); `pg_dump --table=auth.identities` aborts if the table is missing (the test stub gained a minimal `auth.identities`); a test comparing two query results must fail on a SQL error rather than treat "both empty" as equal.
- Restore refuses a non-empty target, runs in one transaction, and keeps triggers off while old rows load (so append-only logs, guards and sign-up linking do not fire on history).
- Not proved: a backup of a real Supabase project (the test stubs Supabase's roles and `auth` tables), and the `age` path (age is not installed here). Do the first real run on a fresh project, not in an emergency.

## Child progress report (0019 + CHILDREPORT block)
- `pupil_report(pupil, from, to)` returns one jsonb: attendance (counts, percentage excluding excused days, up to 60 missed/late dates), practice by module, books, homework with status and the teacher's note to the child, and coin TOTALS by kind. It is **SECURITY INVOKER** (it can show only what the caller could already read through RLS) plus an explicit `ll_can_see_pupil()` check; "not yours" and "does not exist" give the identical `{error: not_allowed}`. Range at most 400 days; lists capped. It never selects `points.reason` or `points.given_by`.
- **Honest finding from the mutation checks:** removing the explicit `ll_can_see_pupil()` check is NOT caught by any test, because the invoker's own RLS already makes the profile lookup return nothing, so the answer is identical. The check is belt-and-braces; RLS is what does the work. The other three breakages (leaking coin reasons, letting `anon` execute, switching to security definer) are each caught.
- The Report card page needs a connected project and says so offline rather than inventing numbers. The teacher's comment is typed on the page and printed, **not saved** (no table for it; a note about a child should not be kept somewhere nobody chose). Printing is not written to the report log yet.
- Found by testing: seeded children have no `auth_uid` until they claim, so a "the child asks about themself" test must give one a session first; the seed already has a `reading` row for `qaida-1`, so a test needs its own book id.
- Not done: the parent's own "Progress" page still shows the demo's fixed numbers (the new Report card is the real one); printing is not logged; no per-term dates (presets are 30/90 days, this school year from 1 Sept, or custom).

## Client error log (0020 + ERRLOG block)
- `log_client_error(message, source, stack, page, version, browser)` is the only way into `client_errors`. It is a deliberately PUBLIC door (errors happen before sign-in), so it is bounded and silent: 30 reports/hour per signed-in person, 60/hour for all signed-out visitors together, 1,000/hour for the project, 500 different errors per school per day; past a limit it still answers `{ok:true}`. Same error + same school + same London day is one row with a count. 30-day purge (opportunistic, 2% of calls, plus `client_errors_purge()` by hand). Admins read their own school's rows through RLS; reports from before sign-in have no school and are for the project owner (SQL editor). Nobody can write the table directly (revoked, no policies).
- **What is stored:** when, school, role (never who), message (300), source (80), stack (1200), page (letters/digits only), version, coarse browser ("Chrome/macOS"). There is no column that could say who. **Everything text is scrubbed in the database** by `ll_scrub()` whatever the app sent: emails, JWTs, `sb_publishable_`/`sb_secret_`/`sbp_` keys, `name=value` secrets (password, pin, token, apikey, bearer...), URL queries and fragments (a recovery link keeps its token there), UUIDs, and any 4+ digit run not preceded by a colon (line:column survive). The browser's `elScrub()` mirrors it, without look-behind (older Safari refuses the whole script).
- **Tuning traps:** a bare space is NOT a separator for the secret-word rule (first version turned "token expired" into "token <redacted>"); the `Uncaught ` prefix is dropped so repeats dedupe; "ignore" must be judged on the full filename before it is shortened to a basename (or `chrome-extension://` is lost); `LLC` is a top-level `const`, so `window.LLC` is undefined (use `typeof LLC`).
- Client side: window `error` and `unhandledrejection`; ignores "Script error.", ResizeObserver, extension errors, failed resource loads; a repeat is sent once per 10 min; max 15 per page load; failures of the report itself are swallowed (no loop); nothing is sent offline or with no project connected; a device can switch itself off (`ll_errlog_off`). Admin "App problems" page lists, expands a stack, copies a report for support, sends a test report. 58 SQL checks (mutation-checked: no scrubbing, no rate limit, anon read, any-admin read, callable purge, no daily cap, unscrubbed stack are each caught) and 34 browser checks.
- **Two real bugs this turned up and fixed:** (1) the CLASSREQ block was inserted BEFORE the AUTH block that defines `llaBody`, so it died at load with `ReferenceError: llaBody is not defined` and its whole client side (a parent asking for a class, the teacher's "Waiting for you" card) had never run in any browser; it now loads after AUTH. It also wrapped the bare `pageDash` and overwrote `PAGES.dash`, throwing away every wrapper added to `PAGES.dash` since (it had hidden the PIN-reset dashboard card); it now wraps `PAGES.dash`. (2) PINRESET's dashboard asked again whenever it painted and treated a FAILED request as "not loaded yet", so one failed request became an endless retry loop that froze the tab and hammered the database; a failure now counts as an attempt and is retried after 30 s. Both would have shown up in this log within minutes.
- Not done: no scheduled purge job (opportunistic only); no alerting; the log cannot say how many distinct children were affected (by design).

## Parent emails (0021, supabase/functions/notify-send, NOTIFY block, docs/notifications.md)
- **Database half decides, a separate function sends.** Triggers on attendance (absent, today/yesterday only), homework (not already past), class_sessions (future only) and fee_charges (pending, and failed) write to `notify_outbox` via `ll_notify_enqueue`, which requires THREE yeses (`ll_notify_ok`): school switch, parent's per-kind opt-in, confirmed matching address. Defaults are all off. Re-checked at claim time. Cap 8/day/parent, quiet hours 21:00-07:00 London (send_after 07:30), one email per (parent, event key). Triggers swallow every exception so a queue failure can never stop the register or homework (tested by adding a failing CHECK to the outbox).
- **The outbox holds no address.** `notify_claim_batch` (service_role only) joins to `profiles.email` at send time. Parents read their own history through column grants (no `unsub_token`, no `body`). Admins get counts/failures via `notify_school_status`, never rows.
- **One-click unsubscribe** (`notify_unsubscribe`, callable by anon): 64-hex token per email, answers `{ok:true}` for good and bad tokens alike, switches only that kind off for that parent. The link is `APP_URL/#unsubscribe=TOKEN`; the NOTIFY block handles the hash, strips it from the address bar at once, and waits up to 6 s for the connection.
- **Sign-up linking now waits for a confirmed email** (`ll_link_new_user` returns early if `email_confirmed_at` is null; a new trigger fires when it first becomes non-null). That closes the open follow-up where typing a parent's email at sign-up made you that parent. **It only bites once Confirm email is ON**: with it off Supabase confirms at insert. The test stub's `auth.users` gained `email_confirmed_at default now()` (= Confirm off) and `auth.identities` earlier.
- **Sender (`lib.ts` + `index.ts`)**: dry run unless `NOTIFY_LIVE` is exactly `yes`; `NOTIFY_ALLOWLIST` limits real sends; a live run refuses to start (before claiming) if `MAIL_FROM`, `RESEND_API_KEY` or an https `APP_URL` is missing; secret header compared in constant time and the function refuses to run with no/short `NOTIFY_SECRET`; one recipient per request, no cc/bcc; addresses with commas/newlines are failed, never sent; stored error text never contains an address; logs are counts only; no pixel, no remote image, escaped markup. `deno check index.ts` passes (supabase-js pinned 2.45.4).
- **Tests**: 105 SQL checks (12 breakages caught, incl. every one of the yeses, the daily cap, the last-moment re-check, a meeting link in the body, unsubscribe doing nothing, the claim grant, link-on-unconfirmed, a blocking trigger, the token column grant, a surname in the subject), 23 Deno tests (7 breakages caught), 34 browser checks.
- **Real bugs found by the tests**: a first draft treated a bare space as a separator in the secret-word scrubber (earlier, errlog); in this piece my `MAIL_FROM` regex rejected `Name <a@b.co>` (display names have spaces); the admin page wiped an action's own error message when it refreshed the status straight after; the browser "history escaped" check matched the bold subject itself.
- **Not proved**: a real Resend call or delivery, a real scheduled run, DNS/SPF/DKIM/DMARC, deliverability, any real Supabase project. The old "Notifications" page (a mock list) is untouched and is a different thing. Overdue-fee reminders, digests, SMS and push are not built.
- Test-writing trap (garden placement tests): a tap computed from canvas coordinates can land on the sticky header if the page has scrolled (clicking a shop item scrolls it). The intermittent "silent" garden test failures were this, not the product. Scroll to the top and recompute the tile position immediately before each tap.

## Server-held coins, stage 1: the ledger (0022 enum, 0023 ledger)
- **The rule: a child must never be able to give themselves coins.** `points` is now the single ledger; nobody signed in or out can insert, update, delete or truncate it (the old "adults give points" policy is dropped and table privileges revoked; a CHECK keeps `spend` negative and every earning positive, so even the owner cannot write a row the wrong way). The only writers are functions.
- **`ll_mint`** (internal, callable by nobody but the owner): idempotent on (pupil, kind, ref) via a partial unique index, refuses test students and adults, refuses spend/refund/non-positive/over-100,000, takes a per-pupil advisory lock. **`coins_spend`** (child): under that lock, never below zero, idempotent on its reference (a retry cannot charge twice), refuses zero/negative/null/enormous amounts and malformed references, note cleaned and cut to 60. **`coins_refund`** (child): half (rounded down) of a spend that child really made, once per spend, never of a refund. A forty-spend/twenty-sell loop (each sell tried twice) leaves the child with less, never more. **`points_give`** (adult): 1-100, only to a child `ll_can_see_pupil` allows and who is a real (non-test) pupil, 200/day per giver per child and 1,000/day per giver overall (one stolen adult login cannot mint without limit), reason cleaned of links.
- `reward_rates` holds the amounts the rules will use (welcome 100, present 5, on time 10, camera 5, dhikr 10 x 3/day, reading 15, practice 10, activity cap 40/day); closed to everyone signed in or out.
- **`garden.spent` was a hole**: the old `points_balance()` subtracted it and a child writes it, so LOWERING it would have raised their balance. The balance is now the ledger alone and a trigger lets a client only raise `spent` (it clamps rather than errors, so the app's upsert keeps working). `pupil_report` now counts coins EARNED only (not spends or refunds); done by rewriting the function body in a `DO` block, since it was defined in 0019.
- Test hygiene: **a function's effects are not visible to a query in the same statement**, so `ll_mint(..) = 10 and ll_balance(..) = n` must be two statements; helpers `ll_*` are not callable as `authenticated`, so read balances as the owner or through `coins_wallet`; flipping `profiles.is_test` needs `t_be(null)` (the guard looks at the session).
- 79 checks in `0240_coin_ledger_tests.sql`; 12 breakages caught (test students minted, overdraft, a full refund, a second refund, no gift cap, any adult gives, direct insert restored, `spent` can fall, the report counting spends, `ll_mint` reachable, parent gifts to any child). A missing lock is NOT tested (it needs two sessions at once).
- **Nothing in the app changes yet.** The garden still keeps its balance on the device; stages 2 (the earning rules, server-side) and 3 (the client cut-over) follow. Until stage 3 a child can still edit their device-side coins.

## Server-held coins, stage 2: how coins are earned (0024 enum, 0025 rules)
- **What the server can prove and what it cannot.** It can prove a teacher marked a register or homework and that a child joined a class: those pay with no claim from the child. It cannot prove a child practised, read, said dhikr or prayed: those are CLAIMS, made hard to farm rather than impossible, and the real bound is one shared daily ceiling (40 coins, `reward_rates.activity_day_cap`) across practice, reading, dhikr and prayer. The most a child can get by lying about everything is 40 a day. (Sleep and club coins are gone: sleep was self-reported and unbounded, club paid for social farming.)
- **Welcome** (trigger on `enrolments`): 100 coins once per pupil EVER (the reference is just `welcome`, so another class, leaving and rejoining, or an admin moving them pays nothing more); test students get none.
- **The register**: nothing pays when a mark is made. `register_finish(class, date)` (teacher or admin of the class; today or yesterday only) pays came-to-class 5, on-time +10 (present, not late), camera +5 (ticked per child by `attendance_set_camera`, only for present/late). Each part is its own reference, so pressing Finish again pays only what is new and a mark changed to absent afterwards takes nothing back (no clawback; documented, not hidden).
- **Marked homework** (trigger on `submissions.marked_at`): 15 / 10 / 5 by score (80+, 50+, below), once per piece, ceiling 45 a day. The idempotent reference is what really stops a second payment on re-marking; the "first marking only" condition in the trigger is belt-and-braces (removing it is an equivalent mutant).
- **Claims**: `earn_practice(id)` must point at the child's OWN practice row made in the last 15 minutes, never twice, at least 60 s after the previous practice reward, 10/6/3 by score; `earn_dhikr(1..3)` in order, a minute apart, once each a day; `earn_salah(prayer)` once per prayer a day, +20 for all five (cut short by the ceiling); `earn_reading(book)` needs a reading row of 3+ pages touched in the last 15 minutes, once per book per day. All answer `{ok, minted, capped, balance}`.
- **Traps**: enrolling now pays, so any test that adds a pupil to a class gives them 100 coins (the old coin tests had to stop assuming a classmate has none); a test that relies on "coins today" must clear that day's rows first; test students are refused by `ll_child()` itself (`ll_real_pupil`).
- 67 checks in `0250_earning_rules_tests.sql`; 12 breakages tried, 10 caught (no ceiling, no spacing, anyone's practice, old practice, test students, welcome per class, register for any class, unbounded register date, dhikr out of order, camera for absent). The two not caught are equivalent mutants: re-marking homework (the idempotent reference covers it) and revoking a trigger function (a trigger function cannot be called directly anyway).
- **Not built**: missions, quiz coins, streak coins. Nothing in the app calls any of this yet: the garden still earns and spends on the device. Stage 3 is that cut-over.

## Server-held coins, stage 3: the app uses them (0026, WALLET and ATTREG blocks, docs/coins.md)
- **WALLET** (`blocks/wallet.html`): for a connected child (not a test student, not test mode) `gardenState().deeds` becomes a property. The getter is the server balance plus whatever is still queued; lowering it is a spend, raising it is a refund request; the server clamps both. So the two dozen existing buy/sell paths were NOT rewritten: they still do `g.deeds -= cost` and `g.deeds += floor(cost/2)`. A queue (saved in localStorage, idempotent references) survives being offline; a spend the server cannot cover is refused and the display put right with one plain message; a garden document pulled from the server is merged WITHOUT its `deeds`.
- **Earners**: practice (records the row, then asks `earn_practice(id)`, once more after 62 s if it was too fast), dhikr sets, prayer ticks go to the server; `llRecord`, `duaSaid`, `roomSleep/Wake/Read/StudyHere`, `prFinish`, `qzcPay` still run (their other effects stand) but are wrapped in a mute so they add no coins; `gardenConvert/Collect` only explain; `gardenConvertCard` becomes a wallet card; the "+N coins" and "N coins for the garden" tails are cleaned from the old toasts. Anything I missed that tries to add coins is only ever a refund request, which the server caps.
- **ATTREG** (`blocks/attreg.html`): "Finish register" and a per-child "Camera on" tick (teacher/admin, live school only, today or yesterday); the camera tick is a note only, the code never touches a camera.
- **Traps found by tests:** (1) `tmOn()` calls `gState()`, which is wrapped, which asks `walActive()`, which calls `tmOn()`: infinite recursion that froze the tab; `walActive` now has a re-entrancy guard (found with the DevTools protocol's `Debugger.pause`, which prints the stack of a hung page). (2) Some blocks keep their own reference to `gardenState`, so wrapping it alone attaches the property only sometimes: `gState` is wrapped too, plus a timer and the sign-in pull. (3) **Re-running `llinsert` on an EARLY block moves it to the END of the file** and changes load order (it would have moved CLOUD after WALLET and broken it); patch such blocks in place in `index.html` (and in `blocks/` to match). I have also re-inserted GUIDE, GARDENUI and CLASSREQ this way, deliberately or not; all suites pass in the new order. (4) A name clash `AR` caught by llcheck.
- **0026**: `coins_refund_pool(amount, ref)`; refunds in total never exceed half of all spending, and `coins_refund(ref)` obeys the same total. A 60-round mixed buy/sell loop leaves the child poorer.
- **Also fixed**: the PIN-audit test grepped whole rows for a PIN and failed whenever a random UUID happened to contain 7391 (rare, "for no reason"); it now checks the schema and the free-text columns only.
- Tests: 79 + 67 + 21 SQL checks for the three stages, 33 browser checks for the wallet (fake server with the same rules) and 15 for the register screen; mutations caught in each.
- **Not done**: quiz coins, missions, streak coins; a teacher-facing "give coins" screen (the server function `points_give` exists); a screen for the child showing their coin history; two-session concurrency test of the lock; nothing applied to a real project.
