#!/usr/bin/env python3
"""A READ-ONLY check of the live Supabase project, using only the public (anon) key.

    LL_URL=https://<ref>.supabase.co  LL_ANON_KEY=<the legacy anon key>  python3 tools/livecheck.py

It answers two questions without changing anything:

  1. Is anything open that should be closed? With only the public key, every
     table must return nothing or be refused, the PIN columns must not be
     selectable, and the security-definer functions must refuse an anonymous caller.
  2. Which of the migrations are actually applied? A table or function that is
     missing is reported as "not applied" (information, not a failure).

What it will NOT do:
  * write, sign anyone up, or sign anyone in. It sends only GET requests and
    function calls that an anonymous caller is supposed to be refused;
  * print any key, token or response body. Only pass / fail lines are shown;
  * run with a service_role or secret key. It refuses: that key bypasses every
    rule, and a check made with it proves nothing.

Exit code 0 = nothing open. 1 = something is open or the check could not run.
Standard library only.
"""
import base64, json, os, sys, urllib.request, urllib.error

URL = (os.environ.get("LL_URL") or "").rstrip("/")
KEY = os.environ.get("LL_ANON_KEY") or ""

def die(msg, code=1):
    print("livecheck: " + msg)
    sys.exit(code)

if not URL or not KEY:
    die("set LL_URL and LL_ANON_KEY (the public anon key, never the service_role key)", 2)
if not (URL.startswith("https://") or URL.startswith("http://127.0.0.1") or URL.startswith("http://localhost")):
    die("LL_URL must be an https:// address (plain http is allowed only for localhost, for testing this tool)")

def role_of(key):
    if key.startswith("sb_secret_"):
        return "service_role"
    if key.startswith("sb_publishable_"):
        return "anon"
    try:
        body = key.split(".")[1]
        body += "=" * (-len(body) % 4)
        return json.loads(base64.urlsafe_b64decode(body)).get("role", "?")
    except Exception:
        return "?"

role = role_of(KEY)
if role == "service_role":
    die("that is a service_role / secret key. It bypasses every rule, so the check would prove nothing and could be dangerous. Use the anon (public) key.")
if role not in ("anon", "?"):
    die("that key's role is '%s', expected the public anon key" % role)

passed = failed = 0
def say(ok, what):
    global passed, failed
    if ok: passed += 1
    else: failed += 1
    print(("  ok    " if ok else "  FAIL  ") + what)

def call(method, path, body=None):
    req = urllib.request.Request(URL + path, method=method, data=None if body is None else json.dumps(body).encode(),
        headers={"apikey": KEY, "Authorization": "Bearer " + KEY, "Content-Type": "application/json", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        die("could not reach the project (%s)" % type(e).__name__)

def parsed(b):
    try: return json.loads(b or b"null")
    except Exception: return None

# (migration, table, why)
TABLES = [
  ("0001", "profiles", "children and staff"), ("0001", "points", "coins"), ("0001", "practice", "practice"), ("0001", "attendance", "registers"),
  ("0001", "garden", "gardens"), ("0001", "homework", "homework"), ("0001", "submissions", "marks and notes"), ("0001", "enrolments", "who is in a class"),
  ("0001", "guardians", "family links"), ("0001", "quiz_questions", "answer keys"), ("0005", "class_requests", "requests"),
  ("0007", "mandates", "Direct Debit"), ("0007", "fee_charges", "fees"),
  ("0009", "class_sessions", "meeting links"), ("0009", "school_link_hosts", "approved platforms"),
  ("0010", "timetable_slots", "timetable"), ("0012", "hours_log", "salary hours"), ("0012", "teacher_rates", "salary rates"),
  ("0013", "report_recipients", "report addresses"), ("0013", "report_log", "report log"), ("0014", "pupil_books", "books given"),
  ("0020", "client_errors", "app error log"), ("0020", "client_error_limits", "error log counters"),
]
print("== what the public key can read")
absent = []
for mig, t, why in TABLES:
    st, b = call("GET", "/rest/v1/%s?select=*&limit=1" % t)
    j = parsed(b)
    if st == 404 or (isinstance(j, dict) and j.get("code") in ("PGRST205", "42P01")):
        absent.append((mig, t)); continue
    leaked = st == 200 and isinstance(j, list) and len(j) > 0
    say(not leaked, "%-18s (%s) shows nothing to an anonymous visitor" % (t, why))

print("== the PIN columns")
for col in ("pin_hash", "pin_attempts", "pin_locked_until"):
    st, b = call("GET", "/rest/v1/profiles?select=%s&limit=1" % col)
    say(st in (400, 401, 403), "profiles.%-17s cannot be selected (got HTTP %d)" % (col, st))

# (migration, function, arguments)
FUNCS = [
  ("0010", "class_create", {"p_name": "x", "p_room": None}), ("0010", "class_move_pupil", {"p_pupil": "00000000-0000-0000-0000-000000000000", "p_class": "00000000-0000-0000-0000-000000000000"}),
  ("0011", "test_student_create", {}), ("0012", "hours_week", {"p_week_start": "2020-01-06"}), ("0012", "hours_set_rate", {"p_teacher": "00000000-0000-0000-0000-000000000000", "p_pence": 1}),
  ("0014", "pupil_books_set", {"p_pupil": "00000000-0000-0000-0000-000000000000", "p_books": []}),
  ("0015", "homework_set", {"p_class": "00000000-0000-0000-0000-000000000000", "p_title": "x", "p_details": None, "p_module": None, "p_due": None}),
  ("0015", "homework_mark", {"p_hw": "00000000-0000-0000-0000-000000000000", "p_pupil": "00000000-0000-0000-0000-000000000000", "p_score": 1, "p_feedback": None}),
  ("0015", "homework_hand_in", {"p_hw": "00000000-0000-0000-0000-000000000000", "p_score": None}),
  ("0019", "pupil_report", {"p_pupil": "00000000-0000-0000-0000-000000000000", "p_from": "2020-01-01", "p_to": "2020-01-31"}),
]
print("== functions an anonymous caller must be refused")
for mig, fn, args in FUNCS:
    st, b = call("POST", "/rest/v1/rpc/" + fn, args)
    j = parsed(b)
    if st == 404:
        absent.append((mig, fn + "()")); continue
    refused = st in (401, 403)
    say(refused, "%-20s refuses an anonymous caller (got HTTP %d)" % (fn, st))

print("== which migrations are applied (information)")
byk = {}
for mig, name in absent: byk.setdefault(mig, []).append(name)
for mig in sorted({m for m, *_ in TABLES} | {m for m, *_ in FUNCS}):
    print("  [info] %s %s" % (mig, "NOT applied (missing: %s)" % ", ".join(byk[mig]) if mig in byk else "applied"))
print("  [info] 0016 and 0017 change permissions only, so they cannot be seen with the public key: check them in the SQL Editor (SETUP.md)")

print("\nlivecheck: %d ok, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
