#!/usr/bin/env bash
# One command that runs every check and stops at the first failure.
#
#   ./tools/check-all.sh           everything
#   ./tools/check-all.sh --quick   skip the database tests (no Docker needed)
#
# Steps, in order (cheapest first, so a typo is found in seconds, not minutes):
#   1. llcheck.py   every block parses, no clashing names     (seconds)
#   2. llaudio.py   the dua recording names match the app      (seconds)
#   3. testdb.sh    every migration + every RLS test in Docker  (about 90 s; needs Docker)
#      backup-selftest.sh  a backup made, damaged, and restored into an empty database (about 60 s; Docker)
#      notify-selftest.sh  the parent-email sender's logic, in Deno in Docker (about 20 s; first run downloads an image)
#   4. livecheck.py the LIVE project, read-only, public key only (only if LL_URL and LL_ANON_KEY are set)
#
# A skipped step is announced loudly and counted in the summary, so "skipped" is never mistaken for "green".
# Exit codes: 10 llcheck, 20 database tests, 30 Docker not running, 40 live check, 50 audio names, 60 backup self-test, 70 parent-email sender.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

RESULTS=()
SKIPPED=0
fail() { # <code> <message>
  echo; echo "STOPPED: $2"
  RESULTS+=("FAILED  $2")
  printf '\n%s\n' "${RESULTS[@]}"
  exit "$1"
}
step() { echo; echo "== $1"; }

step "1/4 llcheck (every block parses)"
python3 tools/llcheck.py || fail 10 "llcheck found problems, see above"
RESULTS+=("passed  llcheck")

step "2/4 llaudio check (recording names match the app)"
python3 tools/llaudio.py check || fail 50 "the dua recording names do not match the app, see above"
RESULTS+=("passed  llaudio check")

step "3/4 database tests (every migration and RLS test, in Docker)"
if [ "$QUICK" = 1 ]; then
  echo "SKIPPED (--quick): the database tests did NOT run."
  RESULTS+=("SKIPPED database tests (--quick)"); SKIPPED=$((SKIPPED+1))
else
  command -v docker >/dev/null 2>&1 || fail 30 "Docker is not installed. Install Docker Desktop, or use --quick to skip the database tests"
  docker info >/dev/null 2>&1 || fail 30 "Docker is not running. Start it with:  open -a Docker   (wait about 20 seconds), then run this again"
  ./tools/testdb.sh || fail 20 "the database tests failed, see above"
  RESULTS+=("passed  database tests (testdb.sh)")
  ./tools/backup-selftest.sh || fail 60 "the backup self-test failed, see above"
  RESULTS+=("passed  backup and restore self-test")
  ./tools/notify-selftest.sh || fail 70 "the parent-email sender tests failed, see above"
  RESULTS+=("passed  parent-email sender tests (Deno)")
fi

step "4/4 livecheck (the live project, read-only)"
if [ -n "${LL_URL:-}" ] && [ -n "${LL_ANON_KEY:-}" ]; then
  python3 tools/livecheck.py || fail 40 "the live project has something open, or could not be checked, see above"
  RESULTS+=("passed  livecheck")
else
  echo "SKIPPED: LL_URL and LL_ANON_KEY are not set, so the LIVE project was NOT checked."
  echo "         To check it:  LL_URL=https://<ref>.supabase.co LL_ANON_KEY=<anon key> ./tools/check-all.sh"
  RESULTS+=("SKIPPED livecheck (LL_URL / LL_ANON_KEY not set)"); SKIPPED=$((SKIPPED+1))
fi

echo
echo "=============================================="
printf '%s\n' "${RESULTS[@]}"
if [ "$SKIPPED" -gt 0 ]; then
  echo "=============================================="
  echo "ALL THAT RAN PASSED, but $SKIPPED step(s) were SKIPPED (see above). That is not the same as everything being checked."
  exit 0
fi
echo "=============================================="
echo "ALL CHECKS PASSED."
