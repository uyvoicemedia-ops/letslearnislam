#!/usr/bin/env python3
"""Insert (or replace) a marked block just before </body>.

    python3 tools/llinsert.py blocks/supabase.html SUPA

Idempotent: if a block with that tag is already present it is stripped
first, so re-running after an edit replaces rather than duplicates. Takes
a timestamped backup every time, because the whole app is one file.

The tag becomes <!-- SUPA-BLOCK-START --> ... <!-- SUPA-BLOCK-END -->.
"""
import shutil, sys, os, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
DOC = os.path.abspath(os.environ.get("LL_DOC") or os.path.join(ROOT, "index.html"))

if len(sys.argv) < 3:
    sys.exit("usage: llinsert.py <block file> <TAG>")

block_path = sys.argv[1] if os.path.isabs(sys.argv[1]) else os.path.join(ROOT, sys.argv[1])
tag_name = sys.argv[2].upper()
start = "<!-- %s-BLOCK-START -->" % tag_name
end = "<!-- %s-BLOCK-END -->\n" % tag_name
marker = "</body>"

block = open(block_path, encoding="utf-8").read()

# A block that opens more <script> tags than it closes does not fail any
# syntax check: the HTML parser simply swallows whatever follows it, and
# the whole block silently never runs. That is very hard to see from the
# outside, so it is caught here instead.
if block.count("<script") != block.count("</script>"):
    sys.exit("%s: %d <script> vs %d </script> — the block is unbalanced"
             % (block_path, block.count("<script"), block.count("</script>")))
src = open(DOC, encoding="utf-8").read()

backup = os.path.join(ROOT, "backups")
os.makedirs(backup, exist_ok=True)
shutil.copy(DOC, os.path.join(backup, "index.%s.%s.html" % (tag_name.lower(), time.strftime("%Y%m%d-%H%M%S"))))

if start in src:
    i = src.index(start)
    j = src.index(end, i) + len(end) if end in src[i:] else src.rfind(marker)
    src = src[:i] + src[j:]
    action = "replaced"
else:
    action = "inserted"

at = src.rfind(marker)
if at < 0:
    sys.exit("no </body> found in " + DOC)
open(DOC, "w", encoding="utf-8").write(src[:at] + start + block + end + src[at:])
print("%s %s (%d lines)" % (action, tag_name, block.count("\n") + 1))
