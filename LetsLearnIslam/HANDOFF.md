# LetsLearn — pick up here

A madrasah app for Qaida and Nazira teaching, for Karimia ("Let's Learn Islam") in
Nottingham. Two parts: a SwiftUI iOS app, and `letslearn-web` — a single-file, no-build web
prototype that is where all current work happens.

Git root is the **parent** directory (`repos/Claude-Repo`), not this folder. No remote yet.

## Read these first, in this order

1. `docs/build-notes.md` — how the file is structured, the tooling, and the traps. The
   "Hard rules learned the hard way" section will save you an afternoon.
2. `letslearn-web/DESIGN.md` — long-form design context. Read before touching the garden.
3. `docs/backend.md` — Supabase schema, RLS, and why the auth works the way it does.
4. `docs/payments.md` — fees and Direct Debit. Read before touching anything money-shaped.
5. `docs/mosque-research.md` — only if you are touching `MOSQUE_LIST` or `MQ_REAL`.

## The shape of the thing

`letslearn-web/index.html` is one file, ~33,200 lines, 123 `<script>` blocks, no build step.
You do not edit it directly. You write a block to `letslearn-web/blocks/<name>.html` and
insert it:

```bash
cd letslearn-web
python3 tools/llinsert.py blocks/mything.html MYTHING   # idempotent; re-run to replace
python3 tools/llcheck.py                                # must say "problems: 0"
python3 tools/llserve.py                                # port 8765
```

A block appends before `</body>` and overrides what came before it by reassignment. That is
the whole architecture: nothing is edited in place, everything is wrapped.

## Where it stands

Working and verified locally:

- the garden (isometric, 200 levels, buildings, interiors, rideable toys, practice)
- the live Kahoot-style quiz — room code, LAN relay, server-side scoring, podium
- the solo practice quiz, now on the same coloured tiles as the live one
- a sign-in gate with a child PIN flow
- Supabase schema: 7 migrations, 91 RLS assertions green against Postgres in Docker
- every records screen reads the school when connected, and says so when it doesn't
- fees by Direct Debit: schema, policies, edge function, parent and admin screens

**The one thing that gates everything:** none of the integration work has ever run against
a real service. Not Supabase, not GoCardless, not even sandbox. The client halves were
proved against hand-built fixtures standing in for PostgREST and the GoCardless API — which
caught four genuine bugs and tells you nothing about how the real APIs behave. Google and
Facebook sign-in are untested by definition, because the handshake needs a live project.

## Next, in rough priority order

1. **Connect a real Supabase project.** `letslearn-web/supabase/SETUP.md` §1–3. Everything
   below this line is guesswork until it happens.
2. **GoCardless sandbox end to end.** `SETUP.md` §7. Sandbox is a *separate account* from
   live — separate signup, separate login, separate credentials.
3. **The deen quiz sets need a teacher's sign-off** before classroom use. There is a review
   sheet with all 44 questions and 26 walkthrough steps, eleven flagged. Three of those
   flags are the app contradicting itself: the wudu walkthrough says "above the elbow" and
   "above the ankle" where the quiz answers say "to the elbow" and "to the ankle". Pick one
   wording and make both agree.
4. **Monster artwork** — `blocks/monart.html` is written but not inserted, and the sheets
   look like stock illustration. Needs a licence or a commission before release.
5. Parent-visible progress; data export and delete for a child (UK GDPR, needed the moment a
   real school uses this).
6. The prayer hall does not read `g.wuduOn` in every place it could.

Declined on purpose, do not redo without asking: **migrating the garden to Phaser/PixiJS.**
Considered 10 Oct 2026 and rejected — it is a ground-up rewrite of working code, and the
engine is not what holds the garden back.

## Things that will bite you

- **Never edit `index.html` by hand.** Write a block.
- `llcheck.py` must pass before you reload. A missing `</script>` fails no syntax check and
  silently kills everything after it.
- `backups/` and `index.html.bak-*` are gitignored — `llinsert.py` regenerates them and they
  were 121M of 182M.
- Reassigning `pageGarden` does nothing unless you also reassign `PAGES.garden`.
- Test the phone layout in a real 390px iframe. Media queries measure the viewport.
- Run the smoke test with test mode ON and OFF — the coin wrappers only fire in one.

## Content rules that are not negotiable

- Faceless human characters. Mosques labelled "inspired by". The garden is never described
  as a picture of Jannah.
- Only short, universally agreed Arabic is printed, with its source. Al-Fatihah, the opening
  supplication and the tashahhud are deliberately not printed.
- The energy and food gate never touches worship — dhikr, salah, duas, books and homework
  are always available.
- Children under 13 never get a Google or Facebook account for this.
- No bank details in the database, ever.
