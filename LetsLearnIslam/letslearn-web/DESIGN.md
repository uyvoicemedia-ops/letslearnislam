# LetsLearn — design context

Read this before touching anything. It exists so the same decisions are not made
twice and the same bugs are not written twice.

Keep it current. When something here turns out to be wrong, fix the line rather
than adding a contradicting one further down.

---

## 1. What this is

A madrasah app for teaching Qaida and Nazira. Two halves:

- `LetsLearn.xcodeproj` — SwiftUI iOS app
- `letslearn-web/index.html` — the working prototype, **one self-contained file,
  no build step**. This is where the design gets decided.

The prototype is where features are proven. It has to keep running from a plain
static server with no network, because that is how it gets shown to people.

## 2. Non-negotiables

These are settled. Do not reopen them without being asked.

**Religious care**

- Characters are faceless.
- Mosques are labelled "inspired by" a real mosque, never presented as a picture
  of it.
- The garden is never called a picture of Jannah. It is a garden.
- Decorative bands are geometric strapwork only. **Never letter-like shapes** —
  garbled pseudo-Arabic is worse than no writing at all.
- Duas use well-known authentic texts with the source shown. **A teacher must
  check the Arabic before any classroom use.** This is still outstanding.
- Worship is never gated. Dhikr, salah, duas, books and homework are always
  available whatever the energy bar says. Only the building game waits.

**Books**

- PDFs must not be downloadable, printable, shareable, or savable to Drive.
- Children and teachers may write and draw on the pages.

**Data**

- Children have no email. Class code + PIN, picking their name from a list.
- Adults use email and password.
- Row-level security is what protects children's data, not obscurity. See
  `supabase/` and its own notes.

## 3. The prototype's shape, and the traps in it

One HTML file, ~19k lines, ~56 `<script>` blocks. New work is appended as a
marked block before `</body>` and overrides earlier top-level `function`
declarations by reassigning them.

**Run `python3 tools/llcheck.py` after every insert.** It catches the three
faults below, none of which announce themselves usefully in a browser.

1. **Duplicate top-level `const`/`let`/`class` across blocks** is a load-time
   SyntaxError that silently kills whole scripts. Classic scripts share one
   global lexical environment.
2. **Assigning to a name declared `const` in an earlier block** throws at load
   and kills the *rest* of that block — so everything after the assignment
   silently never runs.
3. A plain syntax error kills its whole block and the app just quietly loses a
   feature.

**Extending a catalogue:** `GARDEN_ITEMS`, `TOYS`, `ROOM_ITEMS`, `PLAN`,
`MOSQUES` are `const`. Mutate the array (`TOYS.push(...)`) and every existing
lookup picks it up for free. To change a `const` *function*, patch the source in
place instead of reassigning.

**Reassigning a page function is not enough.** `PAGES.garden` holds its own
reference. Change `pageGarden` and you must also set `PAGES.garden = pageGarden`
or nothing happens. This has cost time twice.

**`gardenMount`'s animation loop closes over `W` and `H`.** Resizing the canvas
afterwards means replacing the loop, not nudging it: bump `Garden.gen` (which
stops the old one) and start a fresh loop.

## 4. The isometric world

```
isoPt(u,v,W,H) -> x = W/2 + (u-v)*tw/2*z - cam.x
                  y = H*0.42 + (u+v)*th/2*z - cam.y
ISO = { tw: 68, th: 34 }
```

- Equal steps in u and v move **straight down the screen**. This is why a shadow
  offset equally in both directions is invisible under its own object — `SUN`
  is `{du: 0.6, dv: -0.16}` for that reason.
- The two visible faces of a box are `v = v0+d` (lower-left) and `u = u0+w`
  (lower-right). A box that draws only one of them has a hole in it.
- **Everything is painted far-to-near.** Sort by `u+v`. A near wall painted
  before the thing behind it draws straight through it.
- A span drawn along u leans down-right. For something that should read flat and
  symmetric — a gateway arch — put its ends on `(u-d, v+d)` and `(u+d, v-d)`.
- Place things on **footprint corners**, not on positions taken from elevation
  drawings. Minarets scattered across the grass came from confusing the two.
- Anything drawn on a building's front face should be positioned by walking the
  face in world coordinates and lifting with `isoH`, not by nudging pixels from
  a centre point. Pixel offsets drift and the thing ends up floating beside the
  building.

**Indoors:** house walls are `WH = 1.15`. Nothing indoors may be taller.
Furniture at 1.7–2.0 is what made the interiors read as concrete slabs.
Wall-mounted things hang below the wall top, not above it.

## 5. Design language for the garden

- **An upgrade adds a part; it does not scale the part.** Four tiers — plain,
  better, fine, beautiful. A bigger bench is not a better bench. Scale moves ~5%
  per tier at most; detail carries the difference.
- **Selling refunds half of everything that went in**, including upgrades. Half
  the sticker price punishes anyone who improved something and changed their mind.
- Ground texture is seeded off tile coordinates so it is stable between frames.
  Random per frame crawls and looks like static.
- Night is not "the same thing, darker". Lights glow, windows warm, shadows go
  cool rather than blue. `mqShade(col, f)` with `f < 1` must not push blue —
  that is what made all the furniture look grey-lilac.

## 6. Mosques — how they should actually look

The app carries ~48 mosques as pure data (`spec`), read by both `MQ.draw`
(elevation) and `IB.mosque` (isometric). The regional styles already exist
(`pagoda`, `torons`, `tiered`, `mud`, …). What follows is what those styles are
supposed to be showing, so the specs can be checked against something real.

**Ottoman (Türkiye).** A central dome carried on **semi-domes** — the cascade is
the whole point, not one dome on a box. Pencil-thin minarets, usually 2, 4, or
famously 6 at Sultan Ahmed. Rectangular courtyard in front with a portico and a
fountain. Lead-grey domes, stone walls, İznik tile in blues and whites.

**Timurid / Persian (Iran & Central Asia).** **Onion domes on a tall cylindrical
drum** — bulging at the sides, pointed on top, often fluted or ribbed, and
**turquoise**. Four iwans around a courtyard, with a big pointed portal iwan
dominating the front. Thin symmetrical minarets flanking the portal. Tile
everywhere on the *outside*, because tile survives weather.

**Sudano-Sahelian (West Africa).** Mudbrick and adobe plaster. **Toron** — palm
stakes projecting from the wall face, which are permanent scaffolding for
re-plastering, and are the single most recognisable feature. Tapering buttresses
with cone-shaped tops. Minarets square at the base, stepped or pyramidal.
Earth-brown; the Volta Basin sub-style is white and black.

**Sino-Islamic (China).** Often **no minaret and no dome at all**. A timber hall
under a tiled hip roof with painted dougong brackets; the tower that replaces
the minaret is an **octagonal pagoda**. Several courtyards in a row on an
east–west axis, laid out like a Chinese garden. Turquoise roof tiles, timber and
carved stone. Xi'an is the exemplar — drawing it with a dome would be wrong.

**Id Kah, Kashgar** — the fourth great mosque in this app. **Yellow/golden
brick**, not sand. A tall gate tower with **two asymmetric flanking minarets**
(~18m) and **a third minaret behind on a large arch**. Crescent finials.
Courtyards on both sides of the prayer hall. Its style is Central Asian with
some Chinese influence, which is why it does not look like anything else here.

Sources: [Sudano-Sahelian architecture](https://en.wikipedia.org/wiki/Sudano-Sahelian_architecture) ·
[Ottoman architecture](https://en.wikipedia.org/wiki/Ottoman_architecture) ·
[Timurid architecture](https://en.wikipedia.org/wiki/Timurid_architecture) ·
[Great Mosque of Xi'an](https://en.wikipedia.org/wiki/Great_Mosque_of_Xi%27an) ·
[Id Kah Mosque](https://en.wikipedia.org/wiki/Id_Kah_Mosque)

### Why they do not look like the real thing — the actual cause

Measured, not guessed. There are two renderers reading the same `spec`:

| | reads | misses |
|---|---|---|
| `MQ.draw` — the shop preview | 17 fields | — |
| `IB.mosque` — **what is in your garden** | 10 fields | `arch`, `iwan`, `windows`, `winN`, `door`, `h`, `tree` |

So the shop preview of Id Kah has its gate portal, its turquoise banding and its
proportions; the one you build has none of them. The isometric renderer never
asks for:

- **`iwan`** — the great portal. This is *the* identifying feature of Persian and
  Timurid mosques and of Id Kah's gate tower. Nothing in the garden draws one.
- **`arch`** — pointed, round, horseshoe, multifoil. One of the strongest
  regional tells, and every mosque in the garden gets the same arcade.
- **`h`** — the body proportion. Every mosque is therefore the same height ratio,
  which is why a squat mud mosque and a tall Ottoman one read as the same mass.
- **`windows` / `winN` / `door`** — Djenné has `windows:false` and still gets a
  row of glazed windows, which no mud mosque has.

On top of that the courtyard wall, the arcade and the pool are added by the
generic ladder to everything alike, so the parts that ARE per-mosque get buried
under a set of identical parts.

Fixing the look therefore is not a drawing job on 48 buildings. It is: teach
`IB.mosque` to read the rest of the spec it is already being handed, and move
the shared furniture out of the ladder and into each mosque's own list.

**The upgrade ladder is generic and that is the outstanding problem.** Features
unlock at fixed fractions of the way to the ceiling — a pool at 0.3, yard trees
at 0.42, a tiled band at 0.48 — regardless of which mosque it is. That turns 48
distinct buildings into one building in different colours. The pool is now
gated on `mqHasPool(spec)`, which is the first step; the rest still needs
pulling apart into per-mosque paths, so that a level on the Ottoman adds a
semi-dome and a level on Djenné adds toron.

**Upgrade ceilings scale with size.** A village masjid is finished at 4 levels;
a big one takes 12; the four great mosques — Makkah, Madinah, Jerusalem and
Kashgar — go to 20. Every level must add something visible, inside and out.

## 6a. What an upgrade buys

Levels used to change only the jewellery: a gold line, a merlon, a pool.
The building stood in exactly the same place at level 1 and level 20, so
two thousand points bought a necklace rather than a mosque. Three rules
now:

1. **It gets bigger.** `mqSize(def, lvl)` is the single source of the
   footprint — up to 32% larger when the ladder is finished — and
   `mqBodyH(sp, grow)` raises the walls with it, at about two thirds of
   the rate so it does not read as a zoom. All four places that draw or
   test a mosque call it, **including `isoSolidBoxes`**: if the drawn
   edge and the walkable edge come apart, children walk through walls.
   The footprint can now overrun a tight neighbour slightly. That reads
   as a dense complex rather than a bug, and the collision boxes agree
   with the picture, so it is left alone deliberately.
2. **It gains places, not decoration.** Paved sahn (tier 0.3), riwaq —
   the arcade you can walk under — (0.45), corner kiosks (0.62), a
   canopy over the fountain (0.72). `mqRiwaq`, `mqKiosk`, `mqPave` and
   `mqCanopy` live in the MQGRAND block; the far runs are called from
   inside `IB.mosque` where the far walls are painted, the near ones
   after the building, because a wrapper can only ever paint last.
3. **Only the traditions that have them.** Every one of the above is
   gated on `mqFeat(sp)`. Djenné has no arcade of arches and never had
   a gilt cornice; a Chinese mosque has a garden where the sahn would
   be; a tented modern mosque has no courtyard wall at all.

Because a mosque grows, a child standing on grass can find a wall around
them. The movement code therefore allows **every** move when the current
square is already solid — otherwise the test that keeps you out keeps you
in, and the only way out is a reload.

## 6b. The inside grows with the outside

The masjid and madrasah plans are fourteen tiles wide, not ten, and the
rooms at the far end are gated on how far the building itself has been
taken: `need` on a room is a **tier**, not a level, because a village
masjid tops out at level 4 and the Haram at level 20 — everything must be
reachable for every mosque, it just takes the whole ladder. `planTier()`
reads the best building of that kind the child owns.

New rooms: sisters' hall and imam's room in the masjid, qaida room and
assembly hall in the madrasah — each with its own fixtures, because a
room with nothing in it is a coloured rectangle.

The furnish list used to ask for `where: "house"` whatever building you
were standing in, so a mosque could be furnished with cushions and a low
table and never with its own mihrab. It asks the plan now.

## 6c. Decorations

Twelve things whose only job is to be beautiful — six outdoors under
their own heading in the Plant tab (`deco: 1` on the item), six indoors
filtered by building. All tiered, and the tier rule is the same as the
rest of the catalogue: **each level adds a part, it does not scale the
same part up.**

`decoStar` draws the eight-point star the tile panels and the pierced
lanterns are built from. It is pure geometry on purpose — see §2 on
decorative bands. Nothing here may resemble letters.

## 6d. Roofs, and why the domes used to float

A domed mosque is not a box with a dome balanced on it. It is a stepped
mass: lead-roofed aisles round the outside, a raised masonry block in the
middle, and the dome rising out of *that*. The old renderer drew one flat
deck in wall colour and put every dome on a thin drum a third of a tile
above it, which is why the top of every mosque read as a grey terrace
with balloons parked on it.

`mqRoof` now paints the deck (lead is grey whatever the walls are made
of), the four pitched aisles, the raised block with its own windows and
cornice, and the weight turrets at its corners — and **returns the height
the domes sit at**, so that number is decided in one place. `mqDomePlan`
puts the largest dome on the block and the rest a step down over the
aisles, which is the real massing and stops them overlapping.

Two things were shouting over the architecture and have been quietened:
the parapet was a third of a tile tall with a solid gold top (a wall
standing on the wall), and every courtyard wall's coping was painted in
`P.trim`, turning the whole garden into gold ribbon. Both are stone now,
with the trim as a line rather than a slab. The tiled frieze moved from
half-transparent across the middle of the wall — where the windows were
then drawn on top of it — to a framed band above the window heads, which
is where it belongs on the buildings this is drawn from.

## 6e. Interiors: paint order, not coordinates

Fixtures looked mis-aligned because every fixture in the building is
painted in one depth-sorted pass **after all the walls**, so a bookcase
near a wall painted straight over it and read as sticking through into
the next room. The coordinates were mostly fine; the paint order was not.
Each fixture is now drawn inside a clip of its own room's clear volume —
the floor rectangle inset by the wall thickness, swept up to head height,
which is a hexagon in this projection (`planRoomClip`).

Room names had the same class of bug twice: drawn with the floors they
were eaten by the walls, drawn after the walls they were eaten by the
furniture. They go on last, on a soft plate, on the open front edge.

## 6f. Practising the ibadah

This is what the app is for. A child walks into the washroom and
practises wudu step by step; walks into the prayer hall and is taken
through a rak'ah. `PRACTICE` holds wudu, miswak and salah; each step has
what to do, a picture of **where**, the words if there are words, and a
repeat counter the child taps — so they are doing it, not reading it.

Rules the content follows, and must keep following:

- **Only short, universally agreed Arabic is printed**, with its source.
  Al-Fatihah, the opening supplication and the tashahhud are deliberately
  NOT printed: they are long, they belong to the Qaida and the teacher,
  and a half-remembered rendering would be worse than none.
- Every card carries the teacher-check line. The wudu card carries a
  second line saying schools differ on the head and the ears.
- The transliteration uses a plain apostrophe for ayn. The modifier
  half-ring `ʿ` is missing from the UI font and rendered as a blank, so
  "A'la" came out as "A la".
- Nothing here is gated by the energy system.

Completing one sets `g.ibadah[id]` and, for wudu, `g.wuduOn` — the hook a
future prayer-hall feature can read to say "you already have wudu".

## 6g. Researched against the real buildings — and no pools

Every mosque in the list was checked against sources building by
building. Two kinds of change came out of it.

**No pools.** A blue disc in the courtyard was a swimming pool, and
almost none of these mosques has open water in the sahn. Kairouan drains
rain off a paved impluvium into an underground cistern. Bukhara,
Samarkand, Djenné and Bibi-Khanym have nothing at all — Bibi-Khanym's
courtyard centrepiece is a marble Quran lectern. What Istanbul and Cairo
have is a **şadırvan**, a stone ablution fountain: roofed at the Blue
Mosque, Süleymaniye, Muhammad Ali and Sarajevo, and famously *unroofed*
at Selimiye, where Sinan left it open so it would not break the dome's
outline. So `sp.fountain` is `"covered"`, `"open"` or `false`, and
`mqFountain` draws a stone octagon with a spout — never a pond. Even
where a real open tank exists (Badshahi, Jama Masjid, Wazir Khan) it is
a plain stone tank and is drawn as a basin.

**Facts the spec had wrong.** The big ones, all now fixed in `MQ_REAL`:

- **The Blue Mosque is not blue outside.** Grey-buff cut stone with a
  lead-grey dome; the blue is ~21,000 Iznik tiles *inside*. And it has
  six minarets, which is its whole claim to fame.
- **Kuwait's Grand Mosque** is sand-coloured stone with one square
  Andalusian minaret. It was an azure mosque with a tiered minaret.
- **The Dome of the Rock** is a gold dome on a *blue-tiled octagon* —
  Suleyman's 1550s Iznik revetment. It was a gold building. Needed a new
  palette (`iznik`), because every blue in the set was a dome on a cream
  wall and there were no blue WALLS.
- **Hazrat Sultan's dome is white marble**, not turquoise.
- **Ibn Tulun has no dome over the prayer hall at all** — the only dome
  is the one on the fountain kiosk.
- **Cambridge Central Mosque has no minaret**; the mosque's own FAQ says
  so. It had one.
- **Bibi-Khanym was missing its great ribbed turquoise dome** entirely.
- **Sheikh Lotfollah has no courtyard** — it is one domed room behind a
  bent corridor — hence `sp.yard === false`.
- Minaret counts corrected: Quba 4, Nabawi 4 equal (10 in reality),
  Zayed 4, Selimiye 4 identical round the prayer hall, Wazir Khan 4,
  Badshahi 4+4, Abuja 4, Astana 4, Bibi-Khanym 4, Brunei 5, Larabanga 2,
  Baitul Mukarram 2, Umayyad 3 all different, Woking two little turrets
  rather than minarets, Cape Town one and no dome.
- Arch forms corrected: Jama Masjid is **cusped**, Muhammad Ali **round**,
  Baitul Mukarram **horseshoe**, Woking **ogee** (drawn as a keel).

Sources: Wikipedia and the Madain Project for the Arabian and Levantine
buildings; Smarthistory and Turkish Archaeological News for Sinan;
Archnet for the Mughal mosques; the mosques' own sites for Sheikh Zayed
(SZGMC) and Cambridge. Where sources disagree — the Nabawi sliding-dome
count, al-Haram's minaret total, Selimiye's dome diameter to the
centimetre — the difference does not reach this drawing, and the spec
takes the commonest figure.

## 6h. What else can be upgraded

The house always had five levels and the tiered items — clock tower,
bridge, market stall, shop, and nearly everything you plant — always had
four steps each. What they lacked was any way to *find that out*: you had
to tap the thing on the canvas and notice the pips. "What you have built"
now lists every placed kind that can still be improved, with its level
and the price of the next step, and improving one improves the plainest
one you own first.

The madrasah genuinely could not be upgraded far: it stopped at level 3
and looked much the same at 3 as at 1. It now runs its own ladder — six
levels for the small one, ten for the academy — with `schoolMaxLevel`,
`schoolTier` and `schoolSize`, and it grows and gains a swept yard, a
portico, trees, a yard wall, a working clock over the door, a bell
cupola and a flag. `isoSolidBoxes` uses `schoolSize` too, for the same
reason the mosques do. It also has its own ladder of words
(`SCHOOL_STEPS`) — a madrasah does not gain minarets or a gilded drum.

The growth is applied by scaling the canvas about the plot's own ground
point before calling the inner renderer. That is the honest way to grow
art written for one fixed size; the alternative is four renderers that
disagree with each other.

## 6i. Playing the quiz on more than one device

`python3 -m http.server --bind 127.0.0.1` serves the file to that one
computer and to nobody else — 127.0.0.1 *means* "this machine". And
BroadcastChannel, which the quiz used, carries messages between TABS of
one browser and no further: not to a second browser on the same Mac, and
certainly not to a phone. Those two facts together were the whole limit.

`tools/llserve.py` (and `start.command`, which just runs it) replaces the
static server. Standard library only, one file, nothing to install:

- binds every interface and **prints the wifi address** to give the class;
- relays quiz messages between whoever is connected, over plain HTTP
  long-polling — `POST /api/quiz/<ROOM>` to say something,
  `GET /api/quiz/<ROOM>?since=N&src=ID` to wait for the next thing, held
  open for 25 seconds so it feels instant;
- answers `GET /api/ping`, which is how the page knows the relay is there;
- sends `Cache-Control: no-store`, so a reload really does pick up new
  code — which is worth having on its own.

Transport order in `QuizNet.open`: a real Supabase project if one is
configured, then the local relay, then BroadcastChannel, then nothing.
Every client stamps its messages with a `src` and the relay never sends a
message back to its author — BroadcastChannel excludes the sender for
free and a relay does not.

The host lobby now prints the address to type as well as the room code,
and says something useful when it cannot: on `127.0.0.1` it tells you to
reopen on the wifi address, and with no relay at all it tells you to run
the server.

**This is a local-network relay, not the internet.** Everyone has to be
on the same wifi. Rooms live in memory, are forgotten after two hours
idle, and vanish when the server stops. Going further than one room needs
the Supabase path, which is already written and has never been run
against a real project.

Note that the "This device only" chip in the header is about something
else — it means no school account is connected, so progress is saved in
that browser and syncs nowhere. A LAN quiz does not change that.

## 6j. The quiz: speed, monsters, podium

**Speed.** Every message called `render()`, which rebuilds the whole
page. Twenty-five children answering inside two seconds meant
twenty-five full page rebuilds on the teacher's laptop, and the answer
grid being thrown away and remade under a child's finger. Three changes:

- `quizPaint()` coalesces renders to one per animation frame.
- An answer no longer repaints the host at all. It writes the
  "12 of 25 have answered" counter straight into the DOM
  (`quizTouchCount`). **Measured: asking a question plus 25 answers is
  now 1 full render and 8 ms, where it was 26 renders.**
- Ten children joining at once used to send ten full state broadcasts.
  `quizTellSoon()` debounces them into one.

Also: when everyone in the room has answered, the host reveals after
700 ms instead of sitting out the rest of the clock; the countdown bar
only ticks while a question is live rather than every 250 ms forever;
and a `judged` message mid-question updates the child's score line
in place instead of re-rendering the answer grid they are touching.

**Monsters.** Twelve of them, drawn on a canvas from blobs, horns,
spots and arms, and cached as data URLs per (monster, size, mood) so a
leaderboard of twelve costs one rasterisation each and nothing after.
Three moods: idle, win (eyes up, big smile, sparkles) and sad. The
child's choice lives in `localStorage` under `ll.qz.avatar` and travels
with the `join` message as `av`, so the host can put it on the board.

These are imaginary creatures, not people. The faceless rule in section
2 is about depicting human beings — the child in the garden still has no
face. If that reading is wrong for this community the eyes and mouths
come out of `qzDrawMonster` and nothing else changes.

**Podium.** Second, first, third, with the blocks rising and the
monsters popping in after them, a crown on the winner and medals on the
blocks. Everyone below third is listed underneath. Each child also sees
their own line — "You came 4th" — with their own monster and their
medal if they got one. `quizCheer()` fires three confetti bursts rather
than one puff, and a child who finishes in the top three gets the full
cheer.

Layout note: each podium column is its own flex box pushed to the
bottom, so the blocks sit on one line whatever height the monsters and
names above them come to. With a fixed `min-height` on the row instead,
the blocks were clipped by the card.


## 6k. The quiz sets

Nineteen sets now, grouped in the picker by a new `group` field on each set.
The picker wrapper builds one `<optgroup>` per group; a set with no group
falls into "Starter sets", which is where the three original sets sit.

| Group | Sets |
| --- | --- |
| Starter sets | the three that were already there |
| The alphabet | `abc1` ا–ص, `abc2` ض–ي, `abcall` a mixed quick round |
| Joining | `joinstart`, `joinmid`, `joinend` — 10 each |
| Reading words | `word1`–`word3` plain, `hrk1`–`hrk3` with the harakat |
| The deen | `qwudu`, `qsalah`, `qpillars`, `qiman` |

Writing the joined forms: a joined letter is written with a tatweel, U+0640.
`بـ` is the beginning form, `ـبـ` the middle, `ـب` the end, `ب` on its own.
Six letters never join forward — ا د ذ ر ز و — and the `joinstart` set asks
that as its last question.

Two bidi traps, both hit and both fixed:

- A set title that **ends** in Arabic drags the " — 14 questions" the picker
  appends into the right-to-left run, so it came out as
  "The alphabet — ا to 14 — ص questions". The wrapper now closes the title
  with a left-to-right mark (U+200E) before the dash.
- A prompt that ends "…on the ب?" is fine as it stands — the question mark
  resolves against the paragraph direction, which is left-to-right. Do not
  "fix" that one; check it on screen first.

The Arabic in the questions and answers is set in Noto Naskh Arabic at
25px (prompt) and 36px (answer) — `.qz-big` and `.qz-ans`. The harakat are
too small to read at the old sizes.

The four deen sets carry a `note`, shown in the host lobby before the game
starts, saying a teacher should read them through first. The wudu one adds
that schools differ a little on the head and the ears. That note is not
decoration — the wudu order, the number of washes and the wording of the
tasbih in ruku and sujud are all things a madrasah will want to check
against what it teaches before a class sees them.

Nothing in these sets prints al-Fatihah, the opening supplication or the
tashahhud; the salah set asks *which* surah is read, not the words of it.

## 6l. Thirty monsters

Twelve was thin for a class of twenty-five — several children ended up
as the same creature, which is the thing the monsters existed to stop.

The new eighteen are not recolours. `qzDrawMonster` gained a body
`shape` (blob, tall, wide, egg — a table of `rx`/`ry` plus where the
feet, eyes and mouth sit), four more head pieces (antenna, ears, tuft,
curl), three more markings (patch, star, swirl), an optional `tooth`
and an optional `tail`. Two creatures of the same colour still read as
different animals across a classroom.

**Append only.** A child's choice is stored as an INDEX — in
localStorage as `ll.qz.avatar` and in `profiles.avatar.monster` — so
inserting or reordering anything at or below id 11 silently turns
somebody's creature into a stranger's. Every default in the new drawing
reproduces the original twelve exactly; that was checked, not assumed.

Two details the drawing needed:

- **Two different tops, four pixels apart.** The body's own apex is
  `cy - ry - 6`; the head pieces sit at `cy - ry - 10`. Collapsing them
  into one variable moved every horn on the first twelve.
- **The pale belly is painted after the markings**, which is right for
  dots and stripes and wrong for a patch — it turned the one bold
  marking into a smudge. The patch goes on last, still inside the clip.

A tail that curls up off the side reads as a mug handle rather than an
animal. It hangs down and finishes in a tuft.

Thirty will not fit in a dialog, so `.qz-mongrid` and `.lla-mongrid`
cap at 232px and scroll.

## 7. Testing

- `python3 tools/llcheck.py` — static checks on the single file. Always.
- `./tools/testdb.sh` — applies all four Supabase migrations to a throwaway
  Postgres in Docker and then tries to break the security rules. 34 assertions.
- Serve with `python3 -m http.server 8765` and drive it in Chrome.

**Two test artefacts that are not bugs:**

- `requestAnimationFrame` pauses when the tab is hidden, so scripted probes see
  a frozen clock. Step frames by hand with `gardenFrame(ctx, W, H, t)` — note
  the signature. Passing a timestamp as the first argument corrupts the frame
  and blanks the canvas.
- `render()` replaces the canvas, so cached element references and
  `getBoundingClientRect()` go stale.

## 7a. Walking

`isoWalkable(u, v)` is the single answer to "can the character stand here".
Buildings block their footprint **inset by 0.2** so you can brush along a wall
instead of catching on it — the drawn edge and the walkable edge are deliberately
not the same line. Items block a circle, radius per type in `SOLID_R`.

Movement slides: if the diagonal is blocked, try each axis alone. Stopping dead
at a corner makes the game feel broken rather than solid.

What does **not** block is as deliberate as what does. You walk through an
archway, because that is what an archway is for. You stand in the sandpit, walk
along the bridge, cross the road, step over a prayer mat. Blocking those would be
consistent and would feel wrong.

Footprints are cached in `Garden._solids` and cleared on `llSave`.

## 7b. One plan system, three buildings

The house, the mosque and the madrasah all use the same floor-plan code.
`PLAN` is a `const` array holding **whichever building you are standing in** —
`planUse(kind)` empties it and pushes that layout in, then points `g.planRooms`
and `g.planFurn` at that building's own lists. Every helper reads `PLAN` fresh,
so routing, collision, dragging and buying all carry on unaware. Same aliasing
trick as `g.interiors`.

Two traps this hit:

- **Do not swap the layout in `gardenEnter`.** It returns while the dua is still
  on screen; `Garden.inside` is only set once the child says they have read it.
  The swap happens on the first frame that actually draws inside.
- `PLAN_HALL` used to capture `PLAN[0]` once. Every use now reads `PLAN[0]`
  fresh, or it points at the last building you were in.

## 7c. The live quiz

Host-authoritative. The host owns the clock, decides the scores, and tells
everyone what to show; players only report which button they pressed. **The host
stamps each answer with its own receive time** — nothing a player sends is used
for scoring, so a fabricated `ms: 0` changes nothing, and a second answer for the
same question is ignored. The answer key is never broadcast while a question is
live, only at the reveal.

One interface, two transports: `BroadcastChannel` between tabs on this machine,
a Supabase realtime channel when a project is configured. Same twelve messages
either way, so a class works with no network at all.

Answer tiles are sized for an Arabic glyph, not for the English words that
sometimes share them — reading the letter *is* the question.


## 8. Getting in, and who you are

### 8a. The two front doors

Before this, the only way to be somebody was the role switch in the
header — a reviewer's shortcut, never a login. Now there is a gate in
front of the app, and it has two doors that meet in the middle.

**Grown-ups sign in**: Google, Facebook, or an email and password. That
is a parent or a teacher. **Children never sign in**: they tap a face on
a picker and type a PIN. An under-13 should not have to hold a Google or
a Facebook account to read Qaida, so the rule is enforced in the
database rather than in the UI — `ll_adult_session()` reads
`auth.users.is_anonymous`, and a child's session (which is anonymous)
can never start a household or add a child however the function is
called.

The gate is `body.kid`-agnostic and lives in one overlay, `#llaGate`. It
never touches the app's own layout, so taking the block out puts the
prototype back exactly as it was.

### 8b. Who's learning?

A profile picker, deliberately shaped like the ones children already
know from a television. Big round faces, a name, one word for the role.
Children get their quiz monster, drawn by `qzDrawMonster` at 96px, so
the creature a child picked for the quiz is the same creature that lets
them in. A child with no monster of their own gets a stable one hashed
off their id, so they are the same creature on every device.

**A button centres its content vertically.** One card whose name wraps
to two lines therefore drags its own face out of line with the rest of
the row — the same bug as the quiz podium. Every card is
`display:flex; flex-direction:column; justify-content:flex-start`.

Tapping an adult goes straight in. Tapping a child goes to a PIN pad
with 74px keys, four dots, and no keyboard.

### 8c. Households

`families` is a household. A parent who signs in and is on nobody's
roster gets one, plus a `parent` profile with **no school**, and may add
their own children to it. `profiles.school_id` is nullable now, and
`profile_belongs_somewhere` makes sure nobody floats free.

A child added at home can read, practise, pray and garden from the first
minute. Joining a class is a separate thing and the school owns it: the
parent asks with the class code (`family_request_class`), a teacher of
that class answers (`class_request_decide`), and **approving is the only
thing that writes an enrolment or stamps a school onto a child.**

Two consequences worth keeping:

- A stranger who signs in with Google becomes a **parent of an empty
  household**, never a teacher and never an admin. The worst case is
  somebody using the app at home alone, which is not a breach.
- A teacher can see the *name* of a child being offered to their class
  before they decide, and nothing else, and only while the request is
  pending — `ll_offered_to_me()`. It is `security definer` so the
  profiles policy can call it without reading `class_requests` through
  that table's own policy, which would recurse.

Adding a child goes through `family_add_child()` and there is
deliberately **no insert policy on `profiles` for parents**, so a parent
cannot hand-write a row with role `admin`, somebody else's `school_id`,
or no PIN.

### 8d. It still works with no backend

The whole gate runs on `localStorage` when no project is connected:
`letslearn.people.v1` holds the household, seeded on first run from the
four demo people so the picker is never an empty room. Google, Facebook
and email are shown but disabled, with a line saying why. The classroom
demo must never depend on a network, and this does not.

### 8e. The student screens

`body.kid`, set whenever `role === "student"`, and **CSS only**. Every
student screen is built by a different function, several wrapped many
times over; rewriting that markup to make the buttons bigger would be a
large change with a large blast radius for a small gain. One class on
`<body>` reaches all of them and can be removed by deleting the block.

What it changes: nothing below a 52px touch target; one clear size
ladder so a heading looks like a heading; module tiles become coloured
picture buttons with a real button at the bottom instead of a `Start →`
text link a small finger has to hit; a colour each, so a child navigates
by colour before they can read; and the letter grid goes to 42px glyphs.

**Admin, teacher and parent screens are untouched on purpose.** They are
dense because an adult works through them for an hour at a time, and
blowing the type up there would only mean more scrolling.

### 8f. Test mode

`g.noLimits`. Rest, food and study held at 100, needs never spent, and
coins pinned to 999999. **The switch is the yellow chip in the header** —
"Test mode" off, "∞ Test mode" on — and it is the same `llUnlimited()`
the needs bar's "turn it off" button already called.

Two things were wrong with it before and are worth not reintroducing.

It could only be turned **off** from the UI. The only way to turn it on
was `llUnlimited(true)` in a console, which means the tool did not exist
for anybody who was not reading the source.

Worse, it wrote 999999 straight into saved state and kept no record of
what had been there. Switching it off left that number behind for good,
and on a connected project `llcPushGarden` sends the whole `g` blob, so
a made-up balance would have gone up to the server as a real one. The
real total is now put aside in `g.deedsReal` on the way in and handed
back on the way out.

The order matters: the `llSave` and `render` wrappers in the FURN block
set `g.deeds = 999999` every time they run, so the real total has to be
captured **before** the flag goes on, or it is already gone. Turning the
switch off when `deedsReal` is missing — which is what a garden saved by
the older code looks like — resets to 40 and says so, because anything
is better than leaving an invented balance in place.

A balance frozen at switch-on is the deliberate behaviour: coins earned
while test mode is on are not kept, since the top-up overwrites them.

## 8g. What an upgrade buys on the ground

Until now an upgrade bought a taller building standing on the same patch
of grass. A real mosque or a real house has GROUNDS, so a level now buys
a **place** and not only a wall: a lawn with a paved path to the door,
flower beds, a car park with marked bays, and a corner with a swing, a
slide and a sandpit in it.

They unlock on `tier`, which runs 0 at level one to 1 when the building
is finished, so the same ladder reads for a five-level house and a
twenty-level great mosque:

| tier | what appears |
|------|--------------|
| 0.12 | lawn, path to the door, flower beds, a tree |
| 0.38 | the car park, with a car in it |
| 0.62 | the play area: swing and slide |
| 0.85 | the finished estate: hedge, second car, sandpit, bench |

**Where a thing goes is not a matter of taste.** In this projection
screen x runs with `(u - v)` and screen y with `(u + v)`, so the corner
where both are small sits straight behind the building and nothing put
there is ever seen. Hence: the car park down the left flank (small u,
large v), the beds in an L down the right (large u, small v), the path
and the play area at the front (both large), and only the hedge and one
tree behind — both tall enough to show over the roof.

**Painting order is the whole trick.** Grounds are flat and must lie
UNDER the building, so an ordinary wrapper — which can only ever paint
last — is no use. The GROUNDS block *replaces* `IB.mosque`, `IB.school`
and `IB.house`: it lays the ground and everything standing behind or to
the left first, delegates to the original, then paints what stands in
FRONT (the play area), which the building would otherwise cover.

The apron grows with the building as well as with the level
(`m = max(0.44 + tier*0.78, (0.26 + tier*0.3) * max(w, d))`, capped at
2.1 tiles) or a great mosque four tiles wide ends up with a suburban
front garden. Grounds are decoration only: `isoWalkable` is untouched,
so a child can walk across the car park and the play area.

### And they can play on it

The garden already knew how to put a child on a swing — PLAY holds
`Garden.ride`, the phase clock, the faceless rider and the "Play on the
swing" button. All that was missing was somewhere to stand.

The three toys on a building's grounds are **not** items in `g.items`:
they belong to the building, not to the child's inventory, so they are
never bought, moved or sold. `llgSpots()` gives them the shape
`playNear` expects and a wrapper hands them to it; a bought toy still
wins if it is nearer. `playPhase` is keyed by a **string**
(`house:home:4.00,3.20:swing`) rather than an item index, so a ride on a
building's swing can never be confused with a ride on a bought one — an
index and a key can never compare equal.

`llgPlay()` is the single place that decides where the three toys stand,
and both the drawing and the spot you walk up to read it, so they cannot
drift apart. Verified by instrumenting `playRider` and reading its
coordinates back at four phases: the swing swings, and the slide climbs
the ladder for the first third of a go and then runs down the chute.

## 8h. A picture on every quiz question

A four year old cannot read *"How many times do we wash the face in
wudu?"* — but they can see a tap with water running and know at once
what is being asked. So every question now carries a picture above it,
on the teacher's board and on the child's phone alike.

Three ways one is chosen, in this order:

1. **The teacher picked one.** A dropdown in the quiz editor, with a
   live preview; `none` means they asked for none.
2. **The question has Arabic in it.** The longest Arabic run is shown on
   a big flash card — which is exactly the picture a Qaida child needs.
   101 of the 184 built-in questions take this path.
3. **The words of the question choose a drawing.** A keyword table, most
   specific first: `rak` has to be tested before `how many`, or "how
   many rak'ah is Fajr" gets a picture of counters instead of a mat.

Twenty drawings: mat, water, miswak, hands, kaaba, moon, sun, clock,
book, mosque, pillars, coin, count, compass, speak, dots, harakat, join,
abc, star. All 184 built-in questions get one, checked by walking every
set. They are inline SVG — nothing is loaded from anywhere, they are
sharp at any size, and there are no faces and no photographs in them.

Two things had to be worked around. The relay sends a question as
`{p, a, s}`, so a picture the teacher chose by hand would have been left
behind on the host — `QuizNet.send` puts it back rather than rewriting
`quizTell`. And the editor builds its whole form in one string, so the
chooser is appended to each question box after `qaPaint` has run instead
of by rewriting it.

Two drawings were redrawn after seeing them: a curved stroke with dots
above read as a **smiley face**, which is both wrong for this app and
not what the question is about, and the first masjid came out as a green
blob on a stick.

## 8i. The monsters: no hands, and nothing clipped

Two corrections, and neither is a redraw.

**No arms.** The stickers Yusuf sent are heads, so these are heads. Every
version of the drawing gates its arms on `m.arms >= 1`, so setting `arms`
to 0 across the catalogue takes them off whichever drawing function
happens to be last — and there are three of them chained.

**Nothing clipped.** Horns, ears, antennae and tufts are drawn above the
body at fixed offsets, and on the taller shapes the tips ran past the top
of the 100x100 box: **eight of the thirty came out with a slice missing**
(Ember, Nabeel, Pearl, Bolt, Sana, Wisp, Pom, Nur). Rather than nudging
thirty sets of coordinates — and having the next horn shape break it
again — each creature is now MEASURED and then fitted: drawn once into an
oversized canvas with all three moods on top of each other, the pixels
read back to find what it actually covers, and that box scaled and
centred into the real one with a little air round it. Any horn added
later fits by itself.

The faint ground shadow is ignored when measuring (an alpha threshold,
not "any pixel") because it is wider than the creature and would shrink
the head for nothing. Checked by rendering all thirty and asserting no
solid pixel touches the frame: none do, and each fills 84–94 of the 100.

## 8j. Who played, and what they scored

The report so far answered *which sets get used*. What a teacher and a
parent actually want is the **sitting**: on Saturday at 21:41 Mauluda ran
"Harakat" with Qaida 1, it took under a minute, two children played, and
here is what each of them scored.

All of that was already in `QZ` when the game ended — it was being thrown
away in the roll-up. So a **session record** is written alongside the old
log (`ll.qz.sessions.v1`) rather than replacing it: the existing "Who
wrote what / Every set" report keeps working and nothing already saved is
disturbed.

### Joining as somebody the register knows

A report is only worth reading if the names in it are real. A child used
to type whatever they liked, so "Aisha", "aisha" and "Aisha K" were three
children and none of them was a pupil on the books.

The join screen now shows the **class list**: tap your class, tap your
face. The score comes out attached to a pupil id. A signed-in child skips
it — if the register knows the name on the gate they are picked already.
Typing is still there behind "My name isn't here", for a visitor or a
class not yet entered; those play normally and appear in the report as a
guest.

Two traps this had to avoid, both already paid for once:

- **It must not call `render()` to refresh the picker.** That wipes the
  code the child has already typed — the exact bug QZFIX was written to
  fix. The picker repaints its own box and puts the code back.
- **`#qzNick` has to stay in the DOM**, because the QZFIX validation
  reads it. It becomes a hidden input carrying the chosen name.

The pupil id reaches the host by adding it to the `join` message in a
`QuizNet.send` wrapper, the same trick the question pictures use — the
message is built inside `quizJoin` and rewriting that function to add one
field would mean copying the rest of it. The same wrapper counts right
answers, because `judged` is the only place that knows whether one was.

### Three readers, three views

| Reader | Sees |
|--------|------|
| Teacher | their own sittings, newest first, each opening up to who played, how many they got right, and their score; plus a per-child total |
| Admin | the same for the whole madrasah |
| Parent | **their own child only** — date, quiz, right out of asked, score, and place ("1st of 2") |

The parent view names no other child and shows no other child's score.
Place is the only comparison, because that is what a parent asks and it
identifies nobody. Checked, not assumed: with two children in the sitting,
the other child's name appears nowhere in the parent's rendered page.

A parent has no Quiz screen, so it lives on **Progress**, which is where
they go to ask how their child is getting on.

"Print this report" opens a plain page of its own rather than printing the
app around it, and forces every `<details>` open first — a closed one
prints blank. This is a report, not one of the books; the no-printing rule
is about the Qaida PDFs.

### Not for children

Admin, teacher and parent see quiz reports. A child sees the game and
their own garden, and that is all. No student screen ever built a report
— what was left open was the way **in**, and there were two:

1. **The role switch in the header.** It is a reviewer's shortcut: four
   buttons that turn you into anyone. Since the gate decides who you are,
   a child signed in on a laptop could press "Teacher" and read the whole
   madrasah's scores. It is now emptied and hidden whenever the person who
   came through the gate is a child. (On a phone the MOBILE block was
   already hiding it — exactly the kind of accident that should not be the
   thing protecting a child's data.)
2. **The builders themselves.** Guarding a call site guards one screen;
   guarding the function guards every screen anyone adds later. So
   `qsSessionsHtml`, `qsChildHtml`, `qaReportHtml` and `qsPrint` return
   nothing while a child is signed in — **whatever `role` says**, because
   the gate outranks a variable anyone can assign to. A parent may also
   only render or print one of their own children; an id typed by hand
   gets nothing back.

Checked with a child actually signed in through the gate and the PIN pad,
not by setting `role`: every page in `PAGES` was rendered and none of the
report's text appeared on any of them, and all four builders returned an
empty string under all four roles. Then each adult signed in again and got
their own view back.

None of this is security. It is one HTML file, and a determined adult can
read anything the browser holds; the database is where this is actually
enforced, in the RLS in `0005_families.sql`. This is about the app not
putting other people's children in front of a child who taps the wrong
button.

### Still missing

The class is **derived** from the children who played (one class if they
all agree, "Mixed" if not) because the teacher never says which class a
room is for. A sitting is only recorded when the teacher reaches the last
question — stopping a room early records nothing, which is deliberate but
worth knowing. And it is all `localStorage`, so a report only covers games
run on that one device until quizzes come from Supabase.

## 8k. Winning waters the garden

The quiz score and the garden had nothing to do with each other: a child
could win every round and go back to the same empty patch of grass.
Coming top now pays coins.

The garden runs on a scale where a dua is 2 coins, a day's practice about
12, and the next piece of land 150 and rising. So:

| | |
|---|---|
| first | 15 coins |
| second | 10 |
| third | 6 |
| played and answered | 3 |

Winning is worth about a day's practice — worth chasing, not a shortcut
past the whole game. Everyone who took part leaves with something, so the
child who never comes first still has a reason to play.

The rules round the edges are where this sort of thing goes wrong:

- **You must have answered at least one question.** Sitting in the room
  pays nothing.
- **Alone in a room you are not "first", you are taking part** — 3 coins.
  Otherwise a child learns to open a room by themselves and farm it.
- **A tie shares the better place**, counted as "how many scored more than
  me" rather than by position in a sorted list.

It runs on the child's own device when the host says the game is over —
the teacher's machine must not be paying coins into somebody else's
garden — and the answer count comes from the `judged` messages addressed
to this player, which only the host decides. Paid once per room, so a
re-render, a reconnect or a repeated "done" cannot pay twice.

**Test mode had to be handled.** While it is on, `g.deeds` is a made-up
999999 and the real balance is parked in `g.deedsReal`; paying the visible
one would be thrown away the moment the switch goes off.

The line on the finished screen anchors on the podium, because QZPOD
rebuilt that screen and the old "You scored" paragraph is not there any
more — with a fallback through the older shapes rather than an assumption
about any one of them.

## 8l. What a report is for

Not scores. A quiz score is 500 for a right answer plus up to 500 for
being fast, so it measures reflexes as much as knowing the answer, and
printing it ranks children by something that is half reaction time. What a
teacher and a parent actually need is: **did they turn up, how long did it
take, and did they know the answers.**

So every report carries time spent, quizzes played and right-out-of-asked,
and no points anywhere — the old "Who has been playing" table of best and
total scores has gone from the sets report too.

Placing stays. It is the one comparison a parent actually asks for, it
names nobody else, and the garden pays coins on it.

**Time spent** is time in the room, first question to last, on the host's
clock. A child who was in the room was there for all of it, so their time
is the sitting's time; a teacher's is the same figure summed over the
sittings they ran. That is honest about what it measures — it is not time
with a finger on the screen, and the report says so on the page.

### The ordering trap that ate the guards

`llinsert.py` is idempotent by stripping a block and re-appending it at
the END of the file. So **editing an earlier block moves it after a later
one.** Editing the sittings report moved QZSESS behind QZLOCK; QZLOCK's
wrappers were left holding functions that did not exist yet, its whole
script died on the ReferenceError, and the child-safety guards silently
vanished — the report came back for a signed-in child, with nothing in the
console and a clean `llcheck`.

Caught by re-running the check that had passed before, not by reading the
code. QZLOCK now installs its wrappers on `DOMContentLoaded`, by which
time every block has run and whatever it wraps is the final version,
whatever order the file ended up in. **Any block whose whole job is to
wrap what other blocks define should do the same.**

## 9. Open, and known wrong

- The mosque upgrade ladder is still generic — see section 6. That is the
  biggest remaining piece of the "make mosques match the real thing" job.
- Screens still read homework, attendance and points from localStorage. The sync
  layer pushes and pulls but the UI has not been repointed at the server.
- Quiz sets live in the file — 19 of them now. When a project is connected they
  should come from `quiz_sets`, and final scores should be written back to
  `points`.
- The four deen quiz sets have not had a teacher's eye on them yet.
- Nothing has been run against a real Supabase project.
- Duas still need a teacher's check — including the new one after wudu.
- Still open from the earlier list: separating mosques from town items in the
  Build tab, alignment guides for laying roads, and mouse-drag movement with a
  locate-me button. Clothing in Me is done — see the wardrobe.
- The monster artwork is still the two sheets Yusuf sent. They look like stock
  illustration: fine for a prototype, but a licence or a commissioned set is
  needed before this is released.
