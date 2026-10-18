#!/usr/bin/env bash
# Apply every migration to a throwaway Postgres and run the RLS tests.
#
#   ./tools/testdb.sh          apply + test
#   ./tools/testdb.sh keep     leave the container running afterwards
#
# Needs Docker. Nothing here touches your Supabase project.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME=llpgtest
PORT=54329

cleanup() { [ "${1:-}" = keep ] || docker rm -f $NAME >/dev/null 2>&1 || true; }
docker rm -f $NAME >/dev/null 2>&1 || true

echo "starting postgres…"
docker run -d --name $NAME -e POSTGRES_PASSWORD=test -p $PORT:5432 postgres:16 >/dev/null
trap 'cleanup "${1:-}"' EXIT

for i in $(seq 1 40); do
  docker exec $NAME pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done

run() {
  local label="$1" file="$2"
  printf '  %-28s' "$label"
  if out=$(docker exec -i $NAME psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres < "$file" 2>&1); then
    echo "ok"
  else
    echo "FAILED"
    echo "$out" | sed 's/^/      /' | head -30
    exit 1
  fi
}

echo "applying…"
run "supabase stub"   "$ROOT/supabase/test/0000_supabase_stub.sql"
run "0001 schema"     "$ROOT/supabase/migrations/0001_schema.sql"
run "0002 functions"  "$ROOT/supabase/migrations/0002_functions.sql"
run "0003 rls"        "$ROOT/supabase/migrations/0003_rls.sql"
run "0004 seed"       "$ROOT/supabase/migrations/0004_seed.sql"
run "0005 families"   "$ROOT/supabase/migrations/0005_families.sql"
run "0006 quiz sets"  "$ROOT/supabase/migrations/0006_quiz_sets.sql"
run "0007 fees"       "$ROOT/supabase/migrations/0007_fees.sql"
run "0008 pgcrypto path" "$ROOT/supabase/migrations/0008_pgcrypto_search_path.sql"
run "0009 class sessions" "$ROOT/supabase/migrations/0009_class_sessions.sql"
run "0010 timetable"   "$ROOT/supabase/migrations/0010_timetable_and_classes.sql"
run "0011 test student" "$ROOT/supabase/migrations/0011_test_student.sql"
run "0012 teacher hours" "$ROOT/supabase/migrations/0012_teacher_hours.sql"
run "0013 reports"     "$ROOT/supabase/migrations/0013_reports.sql"
run "0014 pupil books" "$ROOT/supabase/migrations/0014_pupil_books.sql"
run "0015 homework"    "$ROOT/supabase/migrations/0015_homework.sql"
run "0016 profiles lockdown" "$ROOT/supabase/migrations/0016_profiles_lockdown.sql"
run "0017 cross school" "$ROOT/supabase/migrations/0017_cross_school.sql"
run "0018 pin reset"   "$ROOT/supabase/migrations/0018_pin_reset.sql"
run "0019 pupil report" "$ROOT/supabase/migrations/0019_pupil_report.sql"
run "0020 client errors" "$ROOT/supabase/migrations/0020_client_errors.sql"
run "0021 parent notifications" "$ROOT/supabase/migrations/0021_parent_notifications.sql"
run "0022 points enum" "$ROOT/supabase/migrations/0022_points_enum.sql"
run "0023 coin ledger" "$ROOT/supabase/migrations/0023_coin_ledger.sql"
run "0024 points enum 2" "$ROOT/supabase/migrations/0024_points_enum2.sql"
run "0025 earning rules" "$ROOT/supabase/migrations/0025_earning_rules.sql"
run "0026 refund pool" "$ROOT/supabase/migrations/0026_refund_pool.sql"

echo "testing…"
for t in 0100_rls_tests 0110_sessions_tests 0120_timetable_tests 0130_test_student_tests 0140_hours_tests 0150_reports_tests 0160_books_tests 0170_homework_tests 0180_profiles_lockdown_tests 0190_cross_school_tests 0200_pin_reset_tests 0210_pupil_report_tests 0220_client_errors_tests 0230_notifications_tests 0240_coin_ledger_tests 0250_earning_rules_tests 0260_refund_pool_tests; do
  if out=$(docker exec -i $NAME psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres \
             < "$ROOT/supabase/test/$t.sql" 2>&1); then
    echo "$out" | sed 's/^/  /'
  else
    # the failure is at the END, after all the passing notices
    echo "$out" | sed 's/^/  /' | tail -25
    exit 1
  fi
done

echo
echo "all green"
