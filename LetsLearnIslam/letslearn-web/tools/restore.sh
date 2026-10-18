#!/usr/bin/env bash
# Put a backup made by tools/backup.sh into an EMPTY database.
#
#   ./tools/restore.sh FILE
#
# Settings (environment variables, as for backup.sh):
#   LL_RESTORE_URL_FILE   a file, mode 600, holding the connection string of the NEW, EMPTY
#                         database (a fresh Supabase project: direct or session-pooler string)
#   LL_BACKUP_PASSFILE    the passphrase file the backup was made with, or
#   LL_BACKUP_AGE_IDENTITY  the age PRIVATE key file
#
# What it does, and why it is not just `psql < dump`:
#   * it refuses a database that already has pupils in it. It never overwrites, and the
#     live project is not the place to practise;
#   * it does everything in ONE transaction, so a failure leaves the target untouched;
#   * it switches triggers off while the data goes in (otherwise the append-only logs, the
#     guards and the sign-up linking would all fire on old rows);
#   * it re-applies PERMISSIONS exactly. A plain restore into Supabase makes new tables with
#     Supabase's generous default grants, and the dump only adds to them: that put back the
#     very holes migrations 0016 and 0017 closed (the self-test caught this). So default
#     grants are switched off while the tables are made and put back afterwards.
#
# It does not recreate Supabase's own settings: sign-in providers, the Site URL, anonymous
# sign-ins, SMTP. docs/restore.md has the checklist.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup.sh
source "$here/backup.sh"

f="${1:-}"; [ -n "$f" ] && [ -f "$f" ] || die "usage: restore.sh FILE" 2
[ -n "${LL_RESTORE_URL_FILE:-}" ] || die "set LL_RESTORE_URL_FILE (a mode-600 file with the NEW database's connection string)." 2
LL_DB_URL_FILE="$LL_RESTORE_URL_FILE"; load_url
command -v docker >/dev/null && docker info >/dev/null 2>&1 || die "Docker is not running." 2

if [ -f "$f.sha256" ]; then
  [ "$(cut -d' ' -f1 "$f.sha256")" = "$(sha "$f")" ] || die "the backup does not match its checksum; not restoring a damaged file." 5
fi
# prove it can be read and is whole BEFORE touching the target
decrypt "$f" 2>/dev/null | check_dump_text || die "the backup cannot be read, or is cut short; nothing was changed." 5

psql_t() { docker run --rm -i -e LL_DB_URL --add-host=host.docker.internal:host-gateway "$IMAGE" sh -c 'psql "$LL_DB_URL" -v ON_ERROR_STOP=1 -q -t -A "$@"' sh "$@"; }

have="$(echo "select coalesce((select count(*) from public.profiles), 0)" | psql_t 2>/dev/null || echo missing)"
case "$have" in
  0|missing) : ;;
  *) die "refusing: the target already has $have people in public.profiles. Restore only into a new, empty project." 3 ;;
esac
echo "restore: target is empty; restoring $(basename "$f") in one transaction…"

pre='set session_replication_role = replica;
alter default privileges in schema public revoke all on tables    from anon, authenticated, service_role;
alter default privileges in schema public revoke all on sequences from anon, authenticated, service_role;
alter default privileges in schema public revoke all on functions from anon, authenticated, service_role;'
post='alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;'

{ echo "$pre"; decrypt "$f"; echo "$post"; } \
  | docker run --rm -i -e LL_DB_URL --add-host=host.docker.internal:host-gateway "$IMAGE" \
      sh -c 'psql "$LL_DB_URL" -v ON_ERROR_STOP=1 -q --single-transaction -f -' >/dev/null \
  || die "the restore failed and was rolled back; the target is as it was." 6

n="$(echo "select count(*) from public.profiles" | psql_t)"
echo "restore: done. public.profiles has $n rows. Now work through the checklist in docs/restore.md."
