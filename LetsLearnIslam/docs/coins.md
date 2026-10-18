# Coins: how they are earned, spent and kept safe

The rule everything here serves: **a child must never be able to give themselves coins.**

## Where the numbers live

For a child signed in to the school, the coin balance is held by the **server**, in the `points` table, which
nothing signed in or out can write to directly. The garden shows that balance. A child's device does not own
it, so typing a bigger number into the browser changes nothing the server believes.

The demo, test students and test mode are different on purpose: their coins stay on the device, as before,
and are never real.

## How a child earns (amounts are in the `reward_rates` table, one place, not in the app)

| Source | Coins | Who proves it |
|---|---|---|
| Joining a class | 100, once ever | the enrolment itself |
| Coming to class | 5 | the teacher, by pressing **Finish register** |
| On time (marked present, not late) | +10 | the teacher |
| Camera on (the teacher's tick) | +5 | the teacher |
| Homework marked 80+ / 50-79 / below | 15 / 10 / 5 (at most 45 a day) | the teacher marking it |
| Practice (80+ / 50-79 / below) | 10 / 6 / 3 | a claim, checked |
| Dhikr, a set of 33 (three sets a day) | 10 | a claim, checked |
| Prayer ticked (once each a day) | 6 (+20 for all five) | a claim, checked |
| Reading (a book, once a day) | 15 | a claim, checked |
| A teacher or parent giving some | 1-100 at a time | the adult (200 a day to one child, 1,000 a day in all) |

**The four "claims"** (practice, dhikr, prayer, reading) are things the server cannot see happen. They are made
hard to farm instead of impossible: each must be recent and fresh, only once, in order, and spaced out, and
**together they can never pay more than 40 coins in a day.** So the most a child can get by claiming everything
untruthfully is 40 a day. Everything a teacher proves (the register, marked homework, gifts) has its own bound.

Gone, because they could not be bounded fairly: coins for sleeping, for club likes and joins, for reading
corners and rooms, for the duas, and from the quiz (quiz coins are not built yet).

## Spending and selling

Spending is done through the server, one reference per purchase, so a retried request never charges twice and a
balance never goes below nothing. If the device is offline, spends wait in a small saved queue and are sent when
it is back. **Selling** asks for half back by amount, and the server refuses to ever return more than half of
everything that child has spent in total. A child can therefore only ever lose coins by buying and selling,
never gain.

## What this does NOT protect

The garden's contents (the items and where they are) still live on the child's device, as they always did. A
determined child with developer tools can place things in their own garden without paying for them. What they
cannot do is make the balance the school sees, any gift, or anything counted from the ledger different from what
the server holds. Items are cosmetic, so a server-held inventory was judged not worth its cost.

## Changing the amounts

Update `reward_rates` in the SQL editor, for example `update reward_rates set coins = 120 where key = 'welcome';`.
It takes effect for the next payment. Nothing already paid changes. `activity_day_cap` (40) is the daily
ceiling for practice, dhikr, prayer and reading; `homework_day_cap` (45) is the one for marked homework.

## Setting it up

Apply `0022_points_enum.sql` **on its own first** (it adds values to an enum, which must commit before they are
used), then `0023`, then `0024` **on its own**, then `0025`, `0026`. If pupils are already enrolled, run
`supabase/manual/backfill_welcome.sql` once. Take a backup first (`docs/restore.md`).

Coins already held on a child's device before this was switched on are **not** carried over: there are no real
families yet, and an "import what you had" step would be a loophole. Everyone starts with the welcome.

## What was tested

`supabase/test/0240` (ledger), `0250` (earning rules), `0260` (selling): about 170 checks, with deliberate
breakages of every protection. The client wallet has a browser test against a fake server that follows the same
rules (typing 999999 changes nothing; spends, sells, offline queues and retries; every old earner switched off;
the pull of an old garden document; test students). **Not tested:** two requests at the same instant (the per-child
lock is there, but proving it needs two sessions at once), and a real Supabase project.
