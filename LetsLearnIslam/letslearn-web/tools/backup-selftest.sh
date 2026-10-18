#!/usr/bin/env bash
# Does the backup actually work, and can it actually be restored?
#
#   ./tools/backup-selftest.sh
#
# Starts a throwaway Postgres with the real migrations and the seed data, backs it up with
# tools/backup.sh, then restores that backup into a SECOND, empty Postgres the way
# docs/restore.md says, and compares the two. Also tries to break the backup (damage it,
# cut it short, give the wrong passphrase) and the script's refusals. Needs Docker.
# Touches no Supabase project; every key and file it makes lives in a temp folder
# outside the repository and is deleted at the end.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC=llbktest; DST=llbkrest; PORT=54330; DPORT=54331
WORK="$(mktemp -d)"
pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
cleanup() { docker rm -f $SRC $DST >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
docker info >/dev/null 2>&1 || { echo "Docker is not running."; exit 30; }
docker rm -f $SRC $DST >/dev/null 2>&1 || true

boot() { # name port
  docker run -d --name "$1" -e POSTGRES_PASSWORD=test ${2:+-p $2:5432} postgres:16 >/dev/null
  for _ in $(seq 1 40); do docker exec "$1" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
  sleep 2
}
sql() { docker exec -i "$1" psql -v ON_ERROR_STOP=1 -q -t -A -U postgres -d postgres; }

echo "starting two databases…"
boot $SRC $PORT; boot $DST $DPORT
sql $SRC < "$ROOT/supabase/test/0000_supabase_stub.sql" >/dev/null
for f in "$ROOT"/supabase/migrations/*.sql; do sql $SRC < "$f" >/dev/null; done
sql $DST < "$ROOT/supabase/test/0000_supabase_stub.sql" >/dev/null     # a new project starts with Supabase's own parts and nothing of ours
n_prof=$(echo "select count(*) from public.profiles" | sql $SRC)
echo "insert into auth.users(email) values ('parent@example.test')" | sql $SRC >/dev/null
check "the source has seed data to back up ($n_prof profiles)" "[ $n_prof -gt 0 ]"

# the secrets, outside the repo
mkdir -m 700 "$WORK/out"
printf 'postgresql://postgres:test@host.docker.internal:%s/postgres' $PORT > "$WORK/url"; chmod 600 "$WORK/url"
head -c 48 /dev/urandom | base64 | tr -d '\n' > "$WORK/pass"; chmod 600 "$WORK/pass"
export LL_DB_URL_FILE="$WORK/url" LL_BACKUP_DIR="$WORK/out" LL_BACKUP_PASSFILE="$WORK/pass" LL_BACKUP_KEEP=3
B="$ROOT/tools/backup.sh"

echo "backing up…"
out=$("$B" run 2>&1) && ok "backup run succeeds" || { bad "backup run: $out"; exit 1; }
file=$(ls "$WORK/out"/letslearn-*.sql.enc | head -1)
check "an encrypted file and a checksum were written" "[ -s '$file' ] && [ -s '$file.sha256' ]"
check "the file is mode 600" "[ \"\$(stat -f %Lp '$file' 2>/dev/null || stat -c %a '$file')\" = 600 ]"
check "no plain text in the file (no table names, no school name)" "! grep -qaE 'profiles|CREATE TABLE|Karimia|PostgreSQL' '$file'"
check "the run did not print the password or the connection string" "! echo \"\$out\" | grep -qE 'postgres:test|host.docker.internal|$(cat "$WORK/pass" | cut -c1-12)'"
check "verify passes on a good backup" "'$B' verify '$file' >/dev/null"

echo "trying to break it…"
cp "$file" "$WORK/dmg.enc"; cp "$file.sha256" "$WORK/dmg.enc.sha256"
python3 - "$WORK/dmg.enc" <<'PY'
import sys; p = sys.argv[1]; b = bytearray(open(p, 'rb').read()); b[len(b) // 2] ^= 0xFF; open(p, 'wb').write(b)
PY
sed -i.bak 's/letslearn-[0-9TZ]*\.sql\.enc/dmg.enc/' "$WORK/dmg.enc.sha256"
check "a changed byte is caught (checksum)" "! '$B' verify '$WORK/dmg.enc' >/dev/null 2>&1"
rm -f "$WORK/dmg.enc.sha256"
check "a changed byte is caught even without the checksum file" "! '$B' verify '$WORK/dmg.enc' >/dev/null 2>&1"
head -c $(( $(wc -c < "$file") / 2 )) "$file" > "$WORK/cut.enc"
check "a file cut short is caught" "! '$B' verify '$WORK/cut.enc' >/dev/null 2>&1"
head -c 48 /dev/urandom | base64 | tr -d '\n' > "$WORK/pass2"; chmod 600 "$WORK/pass2"
check "the wrong passphrase is caught" "! LL_BACKUP_PASSFILE='$WORK/pass2' '$B' verify '$file' >/dev/null 2>&1"

echo "the script's refusals…"
exits() { local want="$1"; shift; ( set +e; "$@" >/dev/null 2>&1; [ $? -eq "$want" ] ); }
mkdir -p "$ROOT/.selftest-in-repo" ; 
check "refuses a backup folder inside this repository" "exits 3 env LL_BACKUP_DIR='$ROOT/.selftest-in-repo' '$B' run"
rmdir "$ROOT/.selftest-in-repo"
check "refuses to run with no way to encrypt" "exits 2 env -u LL_BACKUP_PASSFILE -u LL_BACKUP_AGE_RECIPIENT '$B' run"
chmod 644 "$WORK/pass2"
check "refuses a passphrase file other people can read" "exits 2 env LL_BACKUP_PASSFILE='$WORK/pass2' '$B' run"
printf 'short' > "$WORK/pass3"; chmod 600 "$WORK/pass3"
check "refuses a short passphrase" "exits 2 env LL_BACKUP_PASSFILE='$WORK/pass3' '$B' run"
printf 'mysql://x' > "$WORK/url2"; chmod 600 "$WORK/url2"
check "refuses a connection string that is not postgres" "exits 2 env LL_DB_URL_FILE='$WORK/url2' '$B' run"
chmod 644 "$WORK/url2"
check "refuses a connection-string file other people can read" "exits 2 env LL_DB_URL_FILE='$WORK/url2' '$B' run"
printf 'postgresql://postgres:wrong@host.docker.internal:%s/postgres' $PORT > "$WORK/url3"; chmod 600 "$WORK/url3"
before=$(ls "$WORK/out" | wc -l)
check "a failed dump (bad password) keeps nothing" "! LL_DB_URL_FILE='$WORK/url3' '$B' run >/dev/null 2>&1 && [ \$(ls '$WORK/out' | wc -l) -eq $before ]"

echo "keeping only the newest…"
for d in 20200101T000000Z 20200102T000000Z 20200103T000000Z 20200104T000000Z; do : > "$WORK/out/letslearn-$d.sql.enc"; : > "$WORK/out/letslearn-$d.sql.enc.sha256"; done
echo keep > "$WORK/out/notes.txt"
"$B" prune >/dev/null
check "prune keeps the newest 3 and removes the older ones" "[ \$(ls '$WORK/out' | grep -cE '^letslearn-.*\.sql\.enc\$') -eq 3 ] && [ -s '$file' ]"
check "prune leaves other files alone" "[ -f '$WORK/out/notes.txt' ]"

echo "restoring into an empty database…"
printf 'postgresql://postgres:test@host.docker.internal:%s/postgres' $DPORT > "$WORK/rurl"; chmod 600 "$WORK/rurl"
R="$ROOT/tools/restore.sh"
export LL_RESTORE_URL_FILE="$WORK/rurl"
check "restore refuses a damaged backup, and the target stays empty" "! '$R' '$WORK/cut.enc' >/dev/null 2>&1 && [ \"\$(echo 'select count(*) from pg_tables where schemaname=\$\$public\$\$' | sql $DST)\" = 0 ]"
check "restore refuses with the wrong passphrase, and the target stays empty" "! LL_BACKUP_PASSFILE='$WORK/pass2' '$R' '$file' >/dev/null 2>&1 && [ \"\$(echo 'select count(*) from pg_tables where schemaname=\$\$public\$\$' | sql $DST)\" = 0 ]"
rout=$("$R" "$file" 2>&1) && ok "the backup restores into an empty database" || bad "restore failed: $rout"
cnt() { echo "$2" | sql "$1"; }
check "restore did not print the password or the connection string" "! echo \"\$rout\" | grep -qE 'postgres:test|host.docker.internal'"
check "restore refuses a database that already has people in it" "exits_code() { ( set +e; \"\$@\" >/dev/null 2>&1; echo \$? ); }; [ \"\$(exits_code '$R' '$file')\" = 3 ]"
for t in schools profiles classes enrolments guardians attendance points garden quiz_sets quiz_questions; do
  a=$(cnt $SRC "select count(*) from public.$t"); b=$(cnt $DST "select count(*) from public.$t")
  check "public.$t has the same rows after restore ($a)" "[ '$a' = '$b' ]"
done
check "the sign-in accounts came back" "[ \"$(cnt $SRC 'select count(*) from auth.users')\" = \"$(cnt $DST 'select count(*) from auth.users')\" ] && [ $(cnt $DST 'select count(*) from auth.users') -ge 1 ]"
# an error on either side is a failure, never "both empty, so equal"
same() { local a b; a=$(cnt $SRC "$1") || return 1; b=$(cnt $DST "$1") || return 1; [ -n "$a" ] && [ "$a" = "$b" ]; }
check "every table still has row-level security switched on" "same \"select string_agg(relname||relrowsecurity::text, ',' order by relname) from pg_class where relnamespace='public'::regnamespace and relkind='r'\""
check "the security policies are the same" "same \"select count(*)||':'||md5(string_agg(tablename||policyname||cmd||coalesce(qual,'')||coalesce(with_check,''), '|' order by tablename, policyname)) from pg_policies where schemaname='public'\""
check "the permissions are the same (children cannot write what 0016/0017 took away)" "same \"select md5(string_agg(grantee||table_name||privilege_type, '|' order by grantee, table_name, privilege_type)) from information_schema.role_table_grants where table_schema='public' and grantee in ('anon','authenticated')\""
check "who may run each function is the same" "same \"select md5(string_agg(grantee||routine_name||privilege_type, '|' order by grantee, routine_name, privilege_type)) from information_schema.role_routine_grants where routine_schema='public' and grantee in ('anon','authenticated','PUBLIC')\""
check "the functions are the same" "same \"select count(*)||':'||md5(string_agg(proname||pg_get_functiondef(oid), '|' order by proname, oid::text)) from pg_proc where pronamespace='public'::regnamespace\""
check "the sequence permissions are the same" "same \"select md5(coalesce(string_agg(grantee||object_name||privilege_type, '|' order by grantee, object_name, privilege_type),'')) from information_schema.role_usage_grants where object_schema='public' and grantee in ('anon','authenticated')\""
check "the default grants for NEW tables are back to Supabase's usual" "same \"select md5(string_agg(defaclobjtype::text||defaclacl::text, '|' order by defaclobjtype)) from pg_default_acl d where defaclnamespace='public'::regnamespace\""
check "the triggers are the same" "same \"select count(*)||':'||md5(string_agg(tgname, '|' order by tgname)) from pg_trigger where not tgisinternal and tgrelid in (select oid from pg_class where relnamespace='public'::regnamespace)\""
check "restoring did not run the triggers (the append-only logs are still empty)" "[ \"$(cnt $DST 'select count(*) from public.report_log')\" = \"$(cnt $SRC 'select count(*) from public.report_log')\" ]"
check "pin hashes came back byte for byte" "same \"select md5(string_agg(id::text||coalesce(pin_hash,''), '|' order by id)) from public.profiles\""

if [ -n "${KEEP_DBS:-}" ]; then trap - EXIT; echo "kept: $WORK"; fi
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
