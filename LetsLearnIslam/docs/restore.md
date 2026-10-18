# Backing up and restoring the school database

Read this *before* you need it. A backup you have never restored is a hope, not a backup.

## What a backup holds

`tools/backup.sh` writes one encrypted file containing:

1. everything in the `public` schema: all tables and their rows, the row-level-security policies, the
   permissions, the functions and triggers (children's names, attendance, homework, points, gardens,
   the fee records, the report log);
2. the sign-in accounts, `auth.users` and `auth.identities`: adult emails and **password hashes**, and
   the anonymous accounts children use.

That is children's data and credentials, so:

- it is **only ever written encrypted** (the script refuses to run without a way to encrypt);
- it is **never written inside a git repository** (the script refuses; `.gitignore` also blocks the file
  names, in case one is copied in by hand);
- the connection string and the passphrase are read from **mode-600 files**, never typed on a command
  line, and never printed;
- the script only **reads** the database.

It does **not** hold Supabase's own settings: sign-in providers, the Site URL, "Confirm email", anonymous
sign-ins, SMTP, API keys, uploaded files in Storage (the app uses none yet). Those are in the checklist
at the bottom.

## One-time setup

1. **A folder outside the repo** for the backups, private to you, ideally on a different disk or synced
   somewhere you trust:
   ```
   mkdir -m 700 ~/LetsLearnBackups
   ```
2. **The connection string.** Supabase dashboard → Project Settings → Database → Connection string.
   Use the **Direct** one, or the **Session pooler** if your network has no IPv6. *Not* the
   "Transaction pooler" (port 6543): `pg_dump` does not work through it. It contains the database
   password, so save it to a file, not the clipboard history:
   ```
   umask 077; cat > ~/.letslearn-db-url      # paste, press Return, then Ctrl-D
   ```
   If your password has special characters they must be percent-encoded in the URL.
3. **The encryption.** Choose one.
   - **`age` (best).** `brew install age`, then `age-keygen -o ~/Desktop/letslearn-backup.key`. It prints
     the public key (`age1...`). Put the **private key file somewhere safe and offline** (a password
     manager, a USB stick in a drawer). The backup machine only ever holds the public key, so a stolen
     laptop cannot read old backups. Set `LL_BACKUP_AGE_RECIPIENT=age1...`.
   - **A passphrase file (needs nothing installed).** At least 20 characters, long and random:
     ```
     umask 077; openssl rand -base64 36 > ~/.letslearn-backup-pass
     ```
     **Keep a copy in your password manager.** Lose the passphrase and every backup is unreadable. The
     file on this Mac is the only thing that can open them, so a stolen Mac can open them too: this is
     the weaker option.
4. Test the whole loop once (below) **before** the school depends on it.

## Taking a backup

```
export LL_DB_URL_FILE=~/.letslearn-db-url
export LL_BACKUP_DIR=~/LetsLearnBackups
export LL_BACKUP_PASSFILE=~/.letslearn-backup-pass        # or: export LL_BACKUP_AGE_RECIPIENT=age1...
./tools/backup.sh run
```

It dumps, encrypts, writes `letslearn-<UTC time>.sql.enc` (or `.age`) with a `.sha256` beside it, reads it
back to prove it is whole (only possible with the passphrase, or with `LL_BACKUP_AGE_IDENTITY` for age),
and then deletes all but the newest 14 (`LL_BACKUP_KEEP`). Exit codes: 2 setup problem, 3 refused (bad
folder or a target that is not empty), 4 the backup failed or is whole-looking only by checksum, 5 a damaged
or unreadable file, 6 a restore that was rolled back.

`./tools/backup.sh verify FILE` re-checks any file later. Run it on an old one now and then.

**How often.** Before you apply a migration to the live project, and then weekly while there are real
families. Supabase's own paid plans have daily backups; the free plan does not, and in any case a copy
**you** hold is the one you can still reach if the project or the account is lost.

**Offsite.** Copy the newest file somewhere that is not this Mac (an external disk, a cloud folder). It is
encrypted, so that is safe. With age and the private key kept elsewhere, it is safe even if that cloud
account is breached.

## Restoring

Always into a **new, empty** project, never over the live one. Practise this on a free test project, or in
Docker with `./tools/backup-selftest.sh`, which does exactly this with a throwaway database.

1. Make a new Supabase project (same region).
2. Save its connection string to a mode-600 file, as above.
3. Restore:
   ```
   export LL_RESTORE_URL_FILE=~/.letslearn-new-db-url
   export LL_BACKUP_PASSFILE=~/.letslearn-backup-pass        # or LL_BACKUP_AGE_IDENTITY=<the private key file>
   ./tools/restore.sh ~/LetsLearnBackups/letslearn-20261018T091500Z.sql.enc
   ```
   It refuses a damaged or unreadable file, refuses a database that already has people in it, does the lot
   in one transaction (a failure changes nothing), keeps triggers off while old rows go in, and re-applies the
   permissions exactly. That last part matters: a plain `psql < dump` into Supabase gives every table
   Supabase's generous default grants and the dump only adds to them, which reopened the holes migrations
   0016 and 0017 had closed. The self-test found this; it now fails if the permissions differ.
4. **The checklist the backup cannot do for you:**
   - Authentication → **Sign In / Providers**: turn on **Allow anonymous sign-ins** (children need it) and
     turn **Confirm email ON**.
   - Authentication → **URL Configuration**: set **Site URL** and the Redirect URL to the address the app is
     served from.
   - Authentication → **SMTP Settings**: your own sender, if you use password reset for real.
   - Project Settings → API Keys: copy the **new** project URL and legacy `anon` key, then in the app
     connect it ("This device only") again. The old keys do not work against the new project.
   - Run `LL_URL=... LL_ANON_KEY=... ./tools/check-all.sh` against the new project: the read-only live check
     confirms the tables are closed to the public key and the security functions refuse it.
   - Sign in as an admin, and sign a child in with class code and PIN, before telling anyone.
   - Adults sign in with the same email and password as before (their hashes came back). Children's devices
     may ask for the PIN again: their old anonymous session belongs to the old project.
5. Keep the old project until you are sure, and then delete it deliberately.

## What was proved, and what was not

`./tools/backup-selftest.sh` (it also runs inside `./tools/check-all.sh`, which needs Docker) makes a backup of a database
built from the real migrations and seed data, damages it three ways, tries the script's refusals, and restores
into an empty second database. It compares row counts for ten tables, the sign-in accounts, row-level security
on every table, every policy, every table, function and sequence permission, every function body, every trigger,
and the PIN hashes byte for byte. 46 checks; breaking the permissions step on purpose makes two of them fail.

**Not proved:** a backup of a real Supabase project (the test database has Supabase's roles and `auth` tables
stubbed, not the real ones: the first real run is the real test, so do it on a fresh project, not an emergency),
the `age` path (it is written but `age` was not installed on the machine where this was built), and the IPv6
and pooler details of your connection string.
