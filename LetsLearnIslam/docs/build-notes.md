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
- `tools/testdb.sh` — applies the nine migrations to postgres:16 in Docker, then 184 RLS
  assertions (91 in `0100_rls_tests.sql`, 93 in `0110_sessions_tests.sql`). Needs Docker Desktop running (`open -a Docker`, then ~20 seconds). Its
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

## The blocks that matter, newest first

| Block | What it does |
|---|---|
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
