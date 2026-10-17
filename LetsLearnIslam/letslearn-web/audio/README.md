# Dua recordings

Put one audio file per dua here. The app shows a play button **only** for a dua
that has a file, so you can add them one at a time. No list to edit: drop the
file in and reload (or just switch back to the window).

```
python3 tools/llaudio.py list       # exactly what to record, the Arabic as the app shows it,
                                    # and which files are already here
python3 tools/llaudio.py check      # catches a misspelt or wrongly-cased file name
```

**File names are exact and lower-case**, `.mp3` (or `.m4a`):
`dua-eat.mp3`, `dua-eat-after.mp3`, `practice-salah-sujud.mp3`, `salah-fajr.mp3` …
`llaudio.py list` has the full set of 30.

**Recording**: mono, 96–128 kbps, silence trimmed from both ends, one clip per file,
no music or effects. Short clips only: they are a phrase, not a lesson.

**Who records them**: the Arabic is the words of the Prophet ﷺ and the Qur'an. A
person who recites correctly records it, a teacher listens before a class hears it,
and it is a recording of a person. The app never reads Arabic aloud by machine.

**Serving**: `tools/llserve.py` serves this folder (with HTTP Range, which Safari
and iOS need). A plain `python3 -m http.server` does not, and audio will not play on
an iPhone from it.

**Offline**: the app has no service worker, so "offline" means the LAN server being
up. These files are not cached for use without it. If the app is ever hosted as a
static site or installed to a home screen, the audio folder needs adding to that
cache.
