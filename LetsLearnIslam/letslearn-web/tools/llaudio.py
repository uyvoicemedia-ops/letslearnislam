#!/usr/bin/env python3
"""The recording list for dua audio, and a check that nothing has drifted.

    python3 tools/llaudio.py list        what to record, and what is already in audio/
    python3 tools/llaudio.py check       the file names still match the app's own data
    python3 tools/llaudio.py selftest    llserve.py serves audio the way Safari needs

The app shows a play button only where audio/<slug>.mp3 (or .m4a) exists, so
adding a recording is: put the file in audio/, reload. There is no list to edit.

The Arabic printed by `list` is read out of index.html — the same strings the
app shows — so the reciter is given exactly what the child will see. Nothing
here is typed from memory.

Standard library only.
"""
import os, re, subprocess, sys, tempfile, time, urllib.request, urllib.error, socket, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
DOC = os.path.join(ROOT, "index.html")
AUDIO = os.path.join(ROOT, "audio")
BLOCK = os.path.join(ROOT, "blocks", "duaaudio.html")
EXTS = (".mp3", ".m4a")


def kebab_id(i):                       # masjidIn -> masjid-in, same rule as the client
    return re.sub(r"([A-Z])", lambda m: "-" + m.group(1).lower(), i).lower()


def kebab_text(s):                     # "Allahu Akbar" -> allahu-akbar
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def region(text, start_pat, end_pat):
    a = re.search(start_pat, text, re.M)
    if not a:
        return ""
    b = re.search(end_pat, text[a.end():], re.M)
    return text[a.start(): a.end() + (b.start() if b else len(text))]


def load():
    text = open(DOC, encoding="utf-8").read()
    items = []                         # (slug, kind, what, arabic)

    duas = region(text, r"^const DUAS = \{", r"^\};")
    for m in re.finditer(r'^  (\w+): \{\s*\n\s*when: "([^"]*)",\s*\n\s*ar: "([^"]*)"', duas, re.M):
        items.append(("dua-" + kebab_id(m.group(1)), "dua", m.group(2), m.group(3)))
    # duas added by later blocks: DUAS.wuduAfter = { when:, ar: }
    for m in re.finditer(r'^DUAS\.(\w+) = \{\s*\n\s*when: "([^"]*)",\s*\n\s*ar: "([^"]*)"', text, re.M):
        items.append(("dua-" + kebab_id(m.group(1)), "dua", m.group(2), m.group(3)))

    prac = region(text, r"^const PRACTICE = \{", r"^\};")
    heads = [(m.start(), m.group(1)) for m in re.finditer(r"^  (\w+): \{$", prac, re.M)]
    for m in re.finditer(r'\{ t: "([^"]+)",[^{]*?say: \{ ar: "([^"]+)"', prac):
        mod = [h for pos, h in heads if pos < m.start()][-1]
        items.append((None, "practice", mod + "|" + m.group(1), m.group(2)))

    dh = region(text, r"^const DHIKR = \[", r"^\];")
    for m in re.finditer(r'\{ ar:"([^"]+)",\s*say:"([^"]+)"', dh):
        items.append(("dhikr-" + kebab_text(m.group(2)), "dhikr", m.group(2), m.group(1)))

    sal = region(text, r"^const SALAH = \[", r"^\];")
    for m in re.finditer(r'\{ id:"(\w+)",\s*name:"([^"]+)",\s*ar:"([^"]+)"', sal):
        items.append(("salah-" + m.group(1), "salah", m.group(2), m.group(3)))
    return items


def practice_slugs():
    """The module|title -> slug table the client carries, read from its block."""
    if not os.path.exists(BLOCK):
        return {}
    t = open(BLOCK, encoding="utf-8").read()
    body = region(t, r"const DA_PRACTICE = \{", r"^\};")
    return dict(re.findall(r'"([^"]+\|[^"]+)":\s*"([a-z0-9-]+)"', body))


def resolved():
    table = practice_slugs()
    out, problems = [], []
    for slug, kind, what, ar in load():
        if kind == "practice":
            slug = table.get(what)
            if not slug:
                problems.append("practice line '%s' has Arabic but no slug in DA_PRACTICE" % what)
                continue
        out.append((slug, kind, what, ar))
    known = {s for s, *_ in out}
    for k, v in table.items():
        if v not in known:
            problems.append("DA_PRACTICE has '%s' -> %s but the app has no such line" % (k, v))
    slugs = [s for s, *_ in out]
    for s in {x for x in slugs if slugs.count(x) > 1}:
        problems.append("slug %s is used twice" % s)
    return out, problems


def files_for(slug):
    return [slug + e for e in EXTS if os.path.isfile(os.path.join(AUDIO, slug + e))]


def cmd_list():
    items, problems = resolved()
    have = 0
    kinds = {"dua": "Duas", "practice": "Practice steps", "dhikr": "Dhikr", "salah": "The five prayers (the name)"}
    print("Put recordings in:  %s%s" % (AUDIO, os.sep))
    print("Name them exactly as below, .mp3 (or .m4a). Mono, 96-128 kbps, silence trimmed, one clip each.\n")
    for kind in ("dua", "practice", "dhikr", "salah"):
        print(kinds[kind])
        for slug, k, what, ar in items:
            if k != kind:
                continue
            f = files_for(slug)
            have += bool(f)
            print("  %s %-34s %s" % ("✓" if f else "·", slug + ".mp3", what.split("|")[-1]))
            print("      %s" % ar)
        print()
    print("%d of %d recorded." % (have, len(items)))
    for p in problems:
        print("PROBLEM:", p)
    return 1 if problems else 0


def cmd_check():
    items, problems = resolved()
    slugs = {s for s, *_ in items}
    if os.path.isdir(AUDIO):
        for f in sorted(os.listdir(AUDIO)):
            base, ext = os.path.splitext(f)
            if f.startswith(".") or f.lower().startswith("readme"):
                continue
            if ext.lower() not in EXTS:
                problems.append("audio/%s is not .mp3 or .m4a, so the app will never find it" % f)
            elif ext != ext.lower() or base not in slugs:
                near = [s for s in slugs if s == base.lower()]
                problems.append("audio/%s matches nothing%s" % (
                    f, " (file names are lower-case: did you mean %s%s?)" % (near[0], ext.lower()) if near else
                    ": see `llaudio.py list` for the exact names"))
    print("%d recordable lines, %d problem(s)" % (len(items), len(problems)))
    for p in problems:
        print("PROBLEM:", p)
    return 1 if problems else 0


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def cmd_selftest():
    tmp = tempfile.mkdtemp(prefix="llaudio-")
    os.makedirs(os.path.join(tmp, "audio"))
    blob = bytes(range(256)) * 40                      # 10240 bytes, every byte value
    for n in ("clip.mp3", "clip.m4a"):
        open(os.path.join(tmp, "audio", n), "wb").write(blob)
    open(os.path.join(tmp, "index.html"), "w").write("<p>hi</p>")
    port = free_port()
    env = dict(os.environ, LL_ROOT=tmp)
    proc = subprocess.Popen([sys.executable, os.path.join(HERE, "llserve.py"), str(port)], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    base = "http://127.0.0.1:%d" % port
    bad = []

    def get(path, headers=None, method="GET"):
        req = urllib.request.Request(base + path, headers=headers or {}, method=method)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read()
        except urllib.error.HTTPError as e:
            return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()

    def ok(cond, what):
        print("  %s %s" % ("ok  " if cond else "FAIL", what))
        if not cond:
            bad.append(what)

    try:
        for _ in range(50):
            try:
                get("/api/ping"); break
            except Exception:
                time.sleep(0.1)
        s, h, b = get("/audio/clip.mp3")
        ok(s == 200 and b == blob, "a plain GET returns the whole file")
        ok(h.get("accept-ranges") == "bytes", "it advertises Accept-Ranges: bytes")
        ok(h.get("content-type") == "audio/mpeg", "mp3 is audio/mpeg (got %s)" % h.get("content-type"))
        ok(h.get("cache-control", "").startswith("public"), "audio may be cached (got %s)" % h.get("cache-control"))
        s, h, b = get("/audio/clip.m4a")
        ok(h.get("content-type") == "audio/mp4", "m4a is audio/mp4 (got %s)" % h.get("content-type"))
        s, h, b = get("/audio/clip.mp3", {"Range": "bytes=0-1"})
        ok(s == 206 and b == blob[0:2] and h.get("content-range") == "bytes 0-1/10240",
           "bytes=0-1 -> 206 with the first two bytes (what Safari asks first)")
        s, h, b = get("/audio/clip.mp3", {"Range": "bytes=100-199"})
        ok(s == 206 and b == blob[100:200] and h.get("content-length") == "100", "a middle range")
        s, h, b = get("/audio/clip.mp3", {"Range": "bytes=10000-"})
        ok(s == 206 and b == blob[10000:] and h.get("content-range") == "bytes 10000-10239/10240", "an open-ended range")
        s, h, b = get("/audio/clip.mp3", {"Range": "bytes=-16"})
        ok(s == 206 and b == blob[-16:], "a suffix range (the last 16 bytes)")
        s, h, b = get("/audio/clip.mp3", {"Range": "bytes=10-99999"})
        ok(s == 206 and b == blob[10:] and h.get("content-range") == "bytes 10-10239/10240", "an end past the file is clamped")
        s, h, b = get("/audio/clip.mp3", {"Range": "bytes=20000-30000"})
        ok(s == 416 and h.get("content-range") == "bytes */10240", "a start past the end is 416")
        s, h, b = get("/audio/clip.mp3", {"Range": "bytes=0-1,5-6"})
        ok(s == 200 and b == blob, "several ranges are ignored, whole file returned")
        s, h, b = get("/audio/nope.mp3", {"Range": "bytes=0-1"})
        ok(s == 404, "a missing file is still 404 under a Range request")
        s, h, b = get("/audio/nope.mp3", method="HEAD")
        ok(s == 404, "HEAD on a missing recording is 404 (this is how the app asks)")
        s, h, b = get("/audio/clip.mp3", method="HEAD")
        ok(s == 200 and h.get("content-type") == "audio/mpeg", "HEAD on a real one is 200 audio/mpeg")
        s, h, b = get("/index.html")
        ok("no-store" in h.get("cache-control", ""), "everything else is still no-store")
        s, h, b = get("/../../etc/passwd", {"Range": "bytes=0-5"})
        ok(s in (404, 400, 403) or b"root:" not in b, "a Range request cannot read outside the root")
    finally:
        proc.terminate()
        proc.wait(timeout=5)
        shutil.rmtree(tmp, ignore_errors=True)
    print("selftest: %s" % ("FAILED" if bad else "passed"))
    return 1 if bad else 0


if __name__ == "__main__":
    cmds = {"list": cmd_list, "check": cmd_check, "selftest": cmd_selftest}
    if len(sys.argv) != 2 or sys.argv[1] not in cmds:
        sys.exit(__doc__)
    sys.exit(cmds[sys.argv[1]]())
