# Emails to parents

Absences, new homework, fees, and online lessons, by email, **only to parents who ask for them**.
Nothing has been sent, ever: every piece below is built and tested, and none of it has been run
against a real email provider or a real Supabase project. Read this once, top to bottom, before
switching anything on.

## The three yeses, and the dry run

An email is only *prepared* if all three are true, and only *sent* if a fourth thing is too:

1. **The school said yes.** An admin switches "Parent emails" on (Office → Parent emails). It is off
   until they do, and the page makes them tick three boxes first. Switching it off cancels anything waiting.
2. **The parent said yes, for that kind.** Each parent switches each kind on for themselves (Email alerts).
   Everything starts off. Being on the roster signs nobody up. Every email has a link that stops that kind in one click.
3. **The address is confirmed.** The parent's sign-in email has been confirmed, and still matches. This only means
   something once Supabase's **Confirm email is ON**. (With it off, Supabase treats every address as confirmed the
   moment it is typed, so anyone could register as a parent by knowing their email.)
4. **The sender is live.** A small scheduled function sends what the database prepared. Until you set
   `NOTIFY_LIVE=yes` it is a **dry run**: every message is marked "prepared, not sent" and nothing leaves.

All of these are checked again at the moment of sending, so a parent who opts out, or a school that switches off,
an hour after a message was prepared is not emailed.

Also: at most **8 emails a day** per parent, **none between 21:00 and 07:00** London time (they wait until 07:30),
and the same event never queues twice for the same parent.

## What an email says, and never says

| Kind | Says | Never says |
|---|---|---|
| Absence | the child's **first name**, the class, the date | surname, scores, anything else |
| Homework | the class, the title the teacher gave it (cut to 80 characters, web addresses replaced), the due date | the details, the score |
| Fees | "a fee of £12.50 for Autumn 2026 is due" or "a payment could not be collected" | any bank detail |
| Online lesson | the day and time | **the meeting link** (they open the app to join) |

No images, no tracking pixel, no tracked links. Switch off open and click tracking in your provider too.

Only registers entered for today or yesterday email: a teacher catching up last week's register does not send a
burst of old news.

## Setting it up, in this order

1. **Back up first** (`docs/restore.md`), then apply `0021_parent_notifications.sql`.
   It also changes sign-up: a new account is linked to its roster row only **when its email is confirmed**
   (so, with Confirm email ON, typing someone's address is no longer enough to become them).
2. **Authentication → Sign In / Providers → Confirm email: ON.** Set Site URL to the address the app is served from.
3. **An email provider.** The sender is written for **Resend** (any provider with an HTTP API would need a small change in
   `supabase/functions/notify-send/lib.ts`). Create an account, then **verify a subdomain**, for example
   `mail.yourdomain.org`, not your main domain, so a mistake cannot hurt your ordinary email. The provider shows you
   DNS records to add:
   - **SPF** and **DKIM** (the provider gives you both, as TXT/CNAME records);
   - **DMARC**: a TXT record on `_dmarc.mail.yourdomain.org`, start with `v=DMARC1; p=none; rua=mailto:you@yourdomain.org`,
     read the reports for a few weeks, then tighten to `quarantine`.
   Turn **open tracking and click tracking off** for the domain.
4. **Secrets** go in the function's environment, never in this repo, and never on a command line you will keep:
   put them in a file **outside the repo** (`chmod 600`) and load it:
   ```
   NOTIFY_SECRET=<a long random string, 24+ characters>
   RESEND_API_KEY=<the provider key>
   MAIL_FROM=Karimia <notifications@mail.yourdomain.org>
   APP_URL=https://<the address the app is served from>
   NOTIFY_ALLOWLIST=<your own email address>
   ```
   `supabase secrets set --env-file ~/.letslearn-notify.env`. **Do not set `NOTIFY_LIVE` yet.**
5. **Deploy:** `supabase functions deploy notify-send --no-verify-jwt`. The function refuses to run without
   `NOTIFY_SECRET` and without the matching `x-notify-secret` header, so the missing JWT is not an open door.
6. **Schedule it** (Dashboard → Integrations → Cron, or `pg_cron` with `pg_net`) to call the function every 5 minutes with the
   secret in the `x-notify-secret` header. Keep the secret in Supabase **Vault**, not typed into the cron SQL.
7. **Dry run.** In the app, switch parent emails on for your school; as a test parent, switch absence on; as a teacher,
   mark that parent's child absent. On the admin page "prepared, not sent" goes up. Nothing has left.
8. **Live, to yourself only.** Set `NOTIFY_LIVE=yes`, keep `NOTIFY_ALLOWLIST` as your own address. Press
   "Send a test email to me". It should arrive. In Gmail choose "Show original" and check SPF, DKIM and DMARC say PASS,
   and that the stop link opens the app and says Done.
9. **A few willing families**, by adding their addresses to the allowlist. Everyone else's emails stay "prepared, not sent".
10. **Everyone**: remove `NOTIFY_ALLOWLIST`.

## Stopping it

Fastest first: the admin switch (cancels the queue); unset `NOTIFY_LIVE` (back to dry run); unschedule the cron job.
Each one alone is enough.

## What is stored, and where

- `notify_outbox` holds the subject, the text, a state and a random stop-token. **It holds no email address**: the
  sender asks for the address only at the moment of sending. Rows are deleted after 90 days.
- A parent can read their own history (subject and state only, not the token). Admins see counts and failure
  reasons, never addresses or messages. Teachers see nothing.
- The provider receives the parent's address, the parent's first name and the message, and therefore a child's
  first name. They are a processor of that data: sign their data processing terms, name them in your privacy notice,
  and tell parents what the emails are. This is practical guidance, not legal advice; the ICO's guidance on
  "service messages" and PECR is the place to check what you may send without consent. The design here goes
  further than that (consent per kind, one-click stop) on purpose.
- The function logs counts only. No address, name or message is ever logged.

## What was tested, and what was not

- **Database**: 105 checks in `supabase/test/0230_notifications_tests.sql` (who is told, who is not, what is in the
  text, caps, quiet hours, the last-moment re-check, the claim/mark protocol, who can call what, and that a failing queue
  never stops the register or homework). Twelve deliberate breakages are each caught.
- **Sender logic**: `./tools/notify-selftest.sh` (Deno, in Docker): dry run never sends, live needs exactly "yes",
  the allowlist holds, no pixel or remote image, markup in a message or name is escaped, one recipient only,
  addresses never reach a log or a stored error. Seven breakages caught.
- **Screens**: stubbed-database browser checks for the parent page, the admin page, and the stop link.
- **Not tested**: a real Resend call, a real scheduled run, real DNS and deliverability, Gmail/Outlook behaviour, a real
  Supabase project. The first real run (steps 7 and 8) is the real test.
- **Not built**: reminders for *overdue* fees (they need a scheduled job that looks for them), a daily digest, SMS or push,
  and a "sent" receipt per parent beyond the history list. Emails about a child added at home rather than through a school
  are not sent: they depend on the school's switch.
