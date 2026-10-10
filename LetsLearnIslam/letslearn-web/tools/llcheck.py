#!/usr/bin/env python3
"""Static checks for the single-file prototype.

Three faults have each cost an hour of silent breakage, and none of them
announce themselves usefully:

  1. A syntax error anywhere in a <script> kills that whole block. The
     browser reports it, but the app just quietly loses a feature.
  2. Two top-level const/let/class of the same name in DIFFERENT blocks
     is a load-time SyntaxError, because classic scripts share one global
     lexical environment.
  3. Assigning to a name declared const in an earlier block throws at
     load and kills the REST of that block, so everything after the
     assignment silently never runs.

Run after every insert. Exits non-zero if anything is wrong.
"""
import re, os, sys, subprocess, collections, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DOC = os.path.abspath(os.environ.get("LL_DOC") or os.path.join(HERE, "..", "index.html"))

src = open(DOC, encoding="utf-8").read()
blocks = re.findall(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", src, re.S)
print("blocks:", len(blocks))

problems = 0
lex = collections.defaultdict(list)
assigns = collections.defaultdict(list)
have_node = subprocess.run(["which", "node"], capture_output=True).returncode == 0

for i, b in enumerate(blocks):
    if have_node:
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as fh:
            fh.write(b); path = fh.name
        r = subprocess.run(["node", "--check", path], capture_output=True, text=True)
        os.unlink(path)
        if r.returncode:
            first = (r.stderr.strip().splitlines() or ["?"])[:4]
            print("SYNTAX ERROR in block %d:\n    %s" % (i, "\n    ".join(first)))
            problems += 1
    for m in re.finditer(r"^(?:const|let|class)\s+([A-Za-z_$][\w$]*)", b, re.M):
        lex[m.group(1)].append(i)
    for m in re.finditer(r"^([A-Za-z_$][\w$]*)\s*=[^=]", b, re.M):
        assigns[m.group(1)].append(i)

for name, where in sorted(lex.items()):
    if len(where) > 1:
        print("DUPLICATE lexical global: %s declared in blocks %s "
              "-> load-time SyntaxError, kills those scripts" % (name, where))
        problems += 1

consts = {}
for i, b in enumerate(blocks):
    for m in re.finditer(r"^const\s+([A-Za-z_$][\w$]*)", b, re.M):
        consts.setdefault(m.group(1), i)

for name, at in sorted(consts.items()):
    later = [j for j in assigns.get(name, []) if j != at]
    if later:
        print("ASSIGN TO CONST: %s is const in block %d, assigned in %s "
              "-> throws at load and kills the rest of that script" % (name, at, later))
        problems += 1

print("problems:", problems)
sys.exit(1 if problems else 0)
