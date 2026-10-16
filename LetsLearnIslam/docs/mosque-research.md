# LetsLearn — what the real mosques actually look like

Researched building by building so the garden's drawings stop being generic.
Full working notes live in `letslearn-web/DESIGN.md` §6g; this is the summary a
future session needs before touching `MOSQUE_LIST` or `MQ_REAL`.

## The pool rule

**No mosque in the app has an open pool.** A blue disc in the courtyard read as
a swimming pool and was, for nearly every one of these buildings, simply wrong:

- Kairouan drains rain off a paved impluvium into an **underground cistern**.
- Bukhara (Kalyan), Samarkand (Bibi-Khanym, Sher-Dor), Djenné and Bobo have
  **nothing at all**. Bibi-Khanym's courtyard centrepiece is a marble Quran
  lectern, not water.
- Quba, Nabawi, al-Haram, the Dome of the Rock, Demak, Larabanga, Faisal,
  Baitul Mukarram and Sheikh Lotfollah: **none**.
- Istanbul and Cairo have a **şadırvan** — a stone ablution fountain. Roofed at
  the Blue Mosque, Süleymaniye, Muhammad Ali, Ibn Tulun, Sarajevo and the
  Umayyad Mosque. Famously **unroofed at Selimiye**, where Sinan left it open so
  it would not break the dome's outline.
- Where a genuine open tank exists — Badshahi, Jama Masjid, Wazir Khan, Shah
  Isfahan — it is a **plain stone tank**, drawn as a basin, never a blue pond.

In the code: `sp.fountain` is `"covered"`, `"open"` or `false`, and `mqFountain`
draws a stone octagon with a spout. `mqHasPool()` now returns false always.

## Facts the spec had wrong (all fixed in the `MQ_REAL` block)

| Mosque | Was | Is |
|---|---|---|
| Blue Mosque | azure walls, 4 minarets | **grey-buff stone, lead-grey dome, 6 minarets** — the blue is ~21,000 Iznik tiles *inside* |
| Grand Mosque of Kuwait | azure, tiered minaret | **sand stone, one square Andalusian minaret** |
| Dome of the Rock | a gold building | **gold dome on a blue-tiled octagon** (Suleyman's 1550s Iznik revetment) — needed a new `iznik` palette |
| Hazrat Sultan, Astana | turquoise dome | **white marble dome** |
| Ibn Tulun | had a dome | **no dome over the prayer hall** — the only dome is the fountain kiosk's |
| Cambridge Central | had a minaret | **no minaret** (the mosque's own FAQ says so) |
| Bibi-Khanym | no main dome | **great ribbed turquoise dome** restored |
| Sheikh Lotfollah | had a courtyard | **no courtyard** — one domed room behind a bent corridor (`sp.yard === false`) |
| Jama Masjid | pointed arches | **cusped (multifoil)** — the Shahjahani signature |
| Muhammad Ali | pointed arches, white domes | **round arches, lead-grey domes**, alabaster walls |
| Baitul Mukarram | pointed | **horseshoe** porticoes |
| Shah Jahan, Woking | 2 minarets | **two little turrets**, ogee arches |
| Auwal, Cape Town | had a dome | **no dome** — a converted warehouse in a terraced street |

Minaret counts corrected throughout: Quba 4, Nabawi 4 shown (10 in reality),
Zayed 4, Selimiye 4 identical round the prayer hall, Umayyad 3 all different,
Wazir Khan 4, Badshahi 4+4, Abuja 4, Astana 4, Bibi-Khanym 4, Brunei 5,
Larabanga 2, Baitul Mukarram 2, Cape Town 1.

## Sources

Wikipedia and the Madain Project for Arabia and the Levant; Smarthistory and
Turkish Archaeological News for Sinan; Archnet for the Mughal mosques; the
mosques' own sites for Sheikh Zayed (SZGMC) and Cambridge Central; Historic
England for Woking.

Where sources disagree — Nabawi's sliding-dome count (24 vs 27), al-Haram's
minaret total (9, 11 or 13 depending on expansion phase), Selimiye's dome
diameter to the centimetre — the difference does not reach a drawing at this
scale, and the spec takes the commonest figure. The thinnest-sourced entries are
**Abuja National Mosque** and **Baitul Islam, Toronto**; treat their details as
unverified.
