#!/usr/bin/env bash
# An encrypted backup of the school database, kept OUTSIDE this repository.
#
#   ./tools/backup.sh run              take a backup now
#   ./tools/backup.sh verify FILE      check a backup file is whole (and, if it can, readable)
#   ./tools/backup.sh prune            delete all but the newest LL_BACKUP_KEEP backups
#   ./tools/backup.sh help
#
# What is in it: everything in the "public" schema (tables, data, row-level
# security policies, grants) plus the sign-in accounts (auth.users and
# auth.identities). That is children's names and adults' password hashes, so
# a backup is ONLY ever written encrypted, and never inside a git work tree.
# See docs/restore.md for getting it back, and for what the file contains.
#
# Settings (environment variables, never arguments, so they stay out of `ps`
# and shell history; nothing here ever prints them):
#
#   LL_DB_URL_FILE   a file, mode 600, holding the Postgres connection string
#                    (Supabase: Project Settings -> Database -> Connection string,
#                    the DIRECT or SESSION-POOLER one, not the transaction pooler).
#                    LL_DB_URL is accepted instead, but a file is better.
#   LL_BACKUP_DIR    where the encrypted files go. Must exist, and must NOT be
#                    inside a git repository. Make it mode 700.
#   one of:
#   LL_BACKUP_AGE_RECIPIENT   an `age` public key (age1...). Needs `age` installed.
#                             Best: the private key can stay off this machine.
#   LL_BACKUP_PASSFILE        a file, mode 600, holding a long passphrase.
#                             Uses openssl AES-256-CBC with PBKDF2. Works with
#                             nothing extra installed.
#   LL_BACKUP_KEEP   how many backups `prune` keeps (default 14)
#   LL_PG_IMAGE      the postgres image used for pg_dump (default postgres:16)
#
# Needs Docker (pg_dump runs in a throwaway container, so nothing is installed
# on your Mac). It only ever READS the database.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${LL_PG_IMAGE:-postgres:16}"
KEEP="${LL_BACKUP_KEEP:-14}"
PATTERN='letslearn-[0-9]{8}T[0-9]{6}Z\.sql\.(age|enc)$'

die() { echo "backup: $*" >&2; exit "${2:-1}"; }

need_dir() {
  [ -n "${LL_BACKUP_DIR:-}" ] || die "LL_BACKUP_DIR is not set (the folder for the encrypted files)." 2
  [ -d "$LL_BACKUP_DIR" ]     || die "LL_BACKUP_DIR is not a folder: $LL_BACKUP_DIR" 2
  local dir; dir="$(cd "$LL_BACKUP_DIR" && pwd -P)"
  # a backup next to the code is one `git add .` from being published
  if git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1; then
    die "refusing: $dir is inside a git repository. Pick a folder outside every repository." 3
  fi
  local top; top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$top" ]; then
    top="$(cd "$top" && pwd -P)"
    case "$dir/" in "$top"/*) die "refusing: $dir is inside this project ($top)." 3 ;; esac
  fi
  local mode; mode="$(stat -f '%Lp' "$dir" 2>/dev/null || stat -c '%a' "$dir")"
  case "$mode" in *[1-7][0-7]|*[0-7][1-7]) echo "backup: note — $dir is readable by others (mode $mode). chmod 700 it." >&2 ;; esac
  BACKUP_DIR="$dir"
}

check_secret_file() {      # refuse a key or password file other people can read
  local f="$1" what="$2"
  [ -f "$f" ] || die "$what file not found: $f" 2
  local mode; mode="$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f")"
  case "$mode" in 400|600) ;; *) die "$what file must be mode 600 (it is $mode): chmod 600 it." 2 ;; esac
}

pick_cipher() {
  if [ -n "${LL_BACKUP_AGE_RECIPIENT:-}" ]; then
    command -v age >/dev/null || die "LL_BACKUP_AGE_RECIPIENT is set but age is not installed (brew install age)." 2
    CIPHER=age; EXT=age
  elif [ -n "${LL_BACKUP_PASSFILE:-}" ]; then
    check_secret_file "$LL_BACKUP_PASSFILE" "passphrase"
    [ "$(wc -c < "$LL_BACKUP_PASSFILE")" -ge 20 ] || die "the passphrase file is shorter than 20 characters; use a long one." 2
    command -v openssl >/dev/null || die "openssl not found." 2
    CIPHER=openssl; EXT=enc
  else
    die "no way to encrypt: set LL_BACKUP_AGE_RECIPIENT (best) or LL_BACKUP_PASSFILE. Backups are never written unencrypted." 2
  fi
}

encrypt() {
  if [ "$CIPHER" = age ]; then age -r "$LL_BACKUP_AGE_RECIPIENT"
  else openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass "file:$LL_BACKUP_PASSFILE"; fi
}

# prints the plain dump to stdout; for age this needs the PRIVATE key (LL_BACKUP_AGE_IDENTITY)
decrypt() {
  local f="$1"
  case "$f" in
    *.enc) check_secret_file "${LL_BACKUP_PASSFILE:-/nonexistent}" "passphrase"
           openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "file:$LL_BACKUP_PASSFILE" < "$f" ;;
    *.age) [ -n "${LL_BACKUP_AGE_IDENTITY:-}" ] || return 9
           check_secret_file "$LL_BACKUP_AGE_IDENTITY" "age identity"
           age -d -i "$LL_BACKUP_AGE_IDENTITY" < "$f" ;;
    *) die "not a backup file: $f" 2 ;;
  esac
}

load_url() {
  if [ -n "${LL_DB_URL_FILE:-}" ]; then
    check_secret_file "$LL_DB_URL_FILE" "connection string"
    LL_DB_URL="$(tr -d '\r\n' < "$LL_DB_URL_FILE")"
  fi
  [ -n "${LL_DB_URL:-}" ] || die "set LL_DB_URL_FILE (a mode-600 file holding the connection string)." 2
  case "$LL_DB_URL" in postgres://*|postgresql://*) ;; *) die "the connection string must start with postgresql://" 2 ;; esac
  export LL_DB_URL
}

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

check_dump_text() {        # reads a plain dump on stdin; fails unless both parts are whole
  # one pass with awk: grep -q on a pipe exits early and, under pipefail, looks like a failure
  awk '
    /PostgreSQL database dump complete/ { ends++ }
    /CREATE TABLE public\.profiles/ { prof = 1 }
    /COPY auth\.users|INSERT INTO auth\.users/ { acct = 1 }
    END {
      if (ends < 2) { printf "backup: the dump is cut short (found %d of 2 end markers)\n", ends > "/dev/stderr"; exit 1 }
      if (!prof)    { print "backup: no profiles table in the dump" > "/dev/stderr"; exit 1 }
      if (!acct)    { print "backup: no sign-in accounts in the dump" > "/dev/stderr"; exit 1 }
    }'
}

cmd_run() {
  need_dir; pick_cipher; load_url
  command -v docker >/dev/null || die "Docker is needed for pg_dump (it runs in a container)." 2
  docker info >/dev/null 2>&1 || die "Docker is not running." 2

  local stamp out tmp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  out="$BACKUP_DIR/letslearn-$stamp.sql.$EXT"
  tmp="$out.partial"
  trap 'rm -f "$tmp"' EXIT

  # Two dumps in one stream. The connection string reaches the container as an
  # environment variable only (docker -e NAME, no value on the command line).
  # (the public schema already exists in every Supabase project, so the line that creates it is dropped)
  docker run --rm -i -e LL_DB_URL --add-host=host.docker.internal:host-gateway "$IMAGE" bash -c '
    set -eo pipefail
    echo "-- letslearn backup, part 1: the public schema (tables, data, policies, grants)"
    pg_dump "$LL_DB_URL" --no-owner --schema=public | sed "/^CREATE SCHEMA public;\$/d"
    echo "-- letslearn backup, part 2: sign-in accounts (data only)"
    pg_dump "$LL_DB_URL" --no-owner --data-only --table=auth.users --table=auth.identities
  ' | encrypt > "$tmp"

  [ -s "$tmp" ] || die "the backup came out empty; nothing was kept." 4
  local size; size="$(wc -c < "$tmp" | tr -d ' ')"
  [ "$size" -ge 256 ] || die "the backup is suspiciously small ($size bytes); nothing was kept." 4

  mv "$tmp" "$out"; trap - EXIT
  printf '%s  %s\n' "$(sha "$out")" "$(basename "$out")" > "$out.sha256"

  # prove it is whole: with a passphrase or an identity we can read it back;
  # otherwise (age, key kept offline) the checksum is all we can check here
  if decrypt "$out" 2>/dev/null | check_dump_text; then deep="read back and checked"
  else
    if [ "$CIPHER" = age ] && [ -z "${LL_BACKUP_AGE_IDENTITY:-}" ]; then deep="not read back (private key is offline, which is the point); run verify with LL_BACKUP_AGE_IDENTITY from time to time"
    else rm -f "$out" "$out.sha256"; die "the backup could not be read back; it was deleted." 4; fi
  fi
  echo "backup: wrote $(basename "$out") ($size bytes, sha256 $(sha "$out" | cut -c1-12)…), $deep"
  cmd_prune
}

cmd_verify() {
  local f="${1:-}"; [ -n "$f" ] && [ -f "$f" ] || die "usage: backup.sh verify FILE" 2
  local want got
  if [ -f "$f.sha256" ]; then
    want="$(cut -d' ' -f1 "$f.sha256")"; got="$(sha "$f")"
    [ "$want" = "$got" ] || die "FAILED: the file does not match its checksum (changed or damaged)." 5
    echo "checksum ok"
  else echo "no .sha256 beside it; skipping the checksum"; fi
  local rc=0
  decrypt "$f" 2>/dev/null | check_dump_text || rc=$?
  if [ $rc -eq 0 ]; then echo "verify: readable and whole"; return 0; fi
  if [ "${PIPESTATUS[0]:-0}" = 9 ] || { [[ "$f" == *.age ]] && [ -z "${LL_BACKUP_AGE_IDENTITY:-}" ]; }; then
    echo "verify: checksum only (set LL_BACKUP_AGE_IDENTITY to read an age backup)"; return 0
  fi
  die "FAILED: it could not be decrypted, or it is cut short." 5
}

cmd_prune() {
  need_dir
  case "$KEEP" in ''|*[!0-9]*) die "LL_BACKUP_KEEP must be a number" 2 ;; esac
  [ "$KEEP" -ge 1 ] || die "LL_BACKUP_KEEP must be at least 1" 2
  local files n=0 gone=0 f
  files="$(ls -1 "$BACKUP_DIR" 2>/dev/null | grep -E "$PATTERN" | sort -r || true)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1))
    if [ "$n" -gt "$KEEP" ]; then rm -f "$BACKUP_DIR/$f" "$BACKUP_DIR/$f.sha256"; gone=$((gone + 1)); fi
  done <<< "$files"
  echo "backup: keeping $((n - gone)), removed $gone older"
}

# restore.sh sources this file for the helpers above; only run a command when executed directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
case "${1:-help}" in
  run)    cmd_run ;;
  verify) shift; cmd_verify "${1:-}" ;;
  prune)  cmd_prune ;;
  help|-h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: $1 (try: run, verify, prune, help)" 2 ;;
esac
fi
