# Going live: one ordered checklist

Everything below has been built and tested against a throwaway database and a stubbed browser. **None of it has
ever run against your real Supabase project**, so the order matters and the rehearsal steps are not optional.
Do one phase, check it, then the next. Nothing here sends an email or touches a child until Phase 6.

## Phase 0: before you touch anything

- [ ] **Free disk space** (the Mac this was built on ran out and Docker stopped). Restart Docker Desktop.
- [ ] `cd letslearn-web && ./tools/check-all.sh` says everything passed (the "live check skipped" line is normal for now).
- [ ] You can sign in to the Supabase dashboard and open the SQL Editor for the **letslearn** project.
- [ ] You know which migrations are already applied. **Easiest:** paste `letslearn-web/supabase/manual/which_migrations.sql` into the SQL Editor and
      Run: one true/false row per migration, 0009 to 0027 (read-only). Or run this smaller one:
  ```sql
  select to_regclass('public.class_sessions') as m0009, to_regclass('public.timetable_slots') as m0010,
         to_regclass('public.hours_log') as m0012, to_regclass('public.report_log') as m0013,
         to_regclass('public.pupil_books') as m0014, to_regclass('public.pin_reset_audit') as m0018,
         to_regclass('public.client_errors') as m0020, to_regclass('public.notify_outbox') as m0021,
         to_regclass('public.reward_rates') as m0023;
  ```
  A column that says `null` has not been applied. (0001 to 0008 were applied on 10 October.)

## Phase 1: a backup you have proved you can restore

- [ ] Follow **`docs/restore.md`**: make the folder, the connection-string file, the passphrase or `age` key.
- [ ] `./tools/backup.sh run` works and says "read back and checked".
- [ ] **Rehearse the restore** into a throwaway Supabase project (a free one), as that document says. This is the step
      that proves the backup is worth having. Delete the throwaway project afterwards.

## Phase 2: turn on the things that protect children (do these FIRST)

- [ ] Authentication → Sign In / Providers: **Confirm email ON** (this is also what makes parent emails safe later).
- [ ] **Allow anonymous sign-ins ON** (children use them).
- [ ] Authentication → URL Configuration: **Site URL** and the Redirect URL are the address the app is really served from.
- [ ] Apply, in this order, **`0016_profiles_lockdown.sql`**, then **`0009_class_sessions.sql`**, then **`0017_cross_school.sql`**. Paste each file whole
      into the SQL Editor and run it once. (0016 stands alone. 0017 needs 0009, because it uses a function 0009 creates; this order was checked
      against a fresh database, and 0017 on its own fails.) Until they run, a signed-in child can make themselves an admin and a teacher
      can overwrite any pupil's PIN hash.
- [ ] `LL_URL=https://<ref>.supabase.co LL_ANON_KEY=<the anon key> ./tools/livecheck.py` (or `check-all.sh` with those two set).
      It is read-only and uses only the public key. Everything it reports as open is a reason to stop.

## Phase 3: the rest of the migrations, in order, one file at a time

Run each file whole, in this order, skipping any you already applied in Phase 2 (0009, 0016, 0017). **Never paste two together.** After each, run the live check; a new "present" line
appears for it.

| File | What it adds | Special |
|---|---|---|
| 0009 class sessions | online lessons with a meeting link | (already done in Phase 2) |
| 0010 timetable and classes | weekly timetable, admins create classes | |
| 0011 test student | a flagged test pupil | |
| 0012 teacher hours | hours and pay rates | |
| 0013 reports | report recipients and an append-only log | |
| 0014 pupil books | books given per pupil | |
| 0015 homework | set, hand in, mark | |
| 0016, 0017 | (done in Phase 2) | |
| 0018 PIN reset | "I forgot my number" | |
| 0019 pupil report | the child progress report | |
| 0020 client errors | the app error log | |
| 0021 parent notifications | parent emails (database half, sends nothing) | also changes sign-up linking (needs Confirm email ON) |
| **0022 points enum** | new kinds of coin entry | **run alone**, nothing else in the same paste |
| 0023 coin ledger | the server-held coin ledger | |
| **0024 points enum 2** | one more kind | **run alone** |
| 0025 earning rules | welcome, register, homework, claims | |
| 0026 refund pool | selling for half, in total | |
| 0027 gift limits | sensible limits on gifts, for the Give coins page | needs 0023 |

- [ ] If pupils are already enrolled, run **`supabase/manual/backfill_welcome.sql`** once (their welcome coins).
- [ ] Take **another backup**. This is your known-good point.

## Phase 4: look at it as each person would

On the real project, with a real account for each. Write down anything odd; do not fix it live.

- [ ] **Admin**: sign in; the roster, classes and timetable load; **App problems** says "Nothing reported" or lists real errors (read them: the log may already show something).
- [ ] **Teacher**: Attendance for a class, mark two children, press **Finish register**, tick **Camera on** for one and press it again (only new coins).
- [ ] **Child** (class code + PIN): sign in; the garden shows the welcome coins; buy something; reload the page (the balance is the same); sell it (half back).
- [ ] **Child**: do one practice activity: coins arrive, the message says "You earned…". Do it again straight away: nothing, and no error shown.
- [ ] **Teacher and parent**: **Give coins**. A teacher sees their own classes, a parent only their own children. Give one thank-you; the child's balance goes up. Try 30 coins to one child twice in a day as a teacher: the second is refused kindly.
- [ ] **Parent**: the **Report card** for their child opens; **Email alerts** shows everything OFF.
- [ ] **Forgot my number**: a child asks; the teacher issues a temporary number; the child chooses their own.
- [ ] **A child cannot cheat the balance**: in the browser console type `gardenState().deeds = 999999`; the number the garden shows does not change after a moment.

## Phase 5: a small pilot

- [ ] One class, with the teacher present, for a week. Keep a note of confusions, not just bugs.
- [ ] Read App problems every day.
- [ ] Take a backup before the pilot starts and weekly after.

## Phase 6: parent emails (separate, later, optional)

Follow **`docs/notifications.md`**. It has its own ten steps: dry run first, then your own address, then a few willing families.
Nothing in Phases 1 to 5 sends an email.

## If something goes wrong

Migrations cannot be undone. The way back is a **restore into a new project** (`docs/restore.md`), switching the app to
the new project's URL and key. That is why Phase 1 comes first and why you rehearse it.

## Known gaps to decide about before the school depends on this

- Quiz coins, missions and streak coins are not built (a connected child earns nothing from the quiz).
- The garden's contents live on the device; only the balance is the server's (`docs/coins.md`).
- Google and Facebook sign-in, GoCardless (even sandbox), and every email path are untested against the real services.
- Dua audio files are not recorded; the Arabic of the duas and the deen quiz sets still need a teacher's check.
