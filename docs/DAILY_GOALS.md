# Daily walking goals

Implemented 4 October 2026. Per-dog progress is available in Quest. **Daily-goal
payouts remain disabled pending the multi-dog decisions below.** Existing
walking-day streak bonuses remain separate and unchanged.

## Configuration and history

Owners use Dog Profile → Daily walking goal to preview and save a personalised
target. Django Admin → Dog goal targets → Add continues to accept an explicit
target in seconds. Both write the **same `DogGoalTarget` timeline** through the
same locking and validation service. The latest effective revision for the
current ownership version wins, regardless of whether Admin or the owner saved
it. Neither source has a separate override. The first target may start today;
changes start tomorrow or later.
A blank target pauses goals from its effective date. Targets are append-only;
there can be only one revision for a dog/effective date. Add a later revision
instead of editing or deleting history. Owners explicitly saving a later goal
can resume an Admin pause. Merely reading a recommendation or editing a profile
does not resume goals. Owner saves do not create reward qualifications.

## Personalised recommendation (confirmed 6 October 2026)

Policy `personalised-duration-v1` uses:

`suggested minutes = weight baseline × breed energy × age × brachycephalic factor`

`target minutes = suggested minutes × owner adjustment`

| Input | Factor |
| --- | --- |
| Weight <5 / 5–<10 / 10–<25 / 25–<40 / ≥40 kg | 30 / 40 / 50 / 60 / 60 minutes |
| Breed energy low / moderate or unknown / high / very high | 0.75 / 1.00 / 1.25 / 1.50 |
| Under 4 calendar months | Not eligible; no target or completed zero goal |
| 4–<7 months / 7 months until first birthday | 0.50 / 0.75 |
| First birthday through tenth birthday (inclusive) | 1.00 |
| Day after tenth birthday onward | 0.75 |
| Non-brachycephalic / brachycephalic | 1.00 / 0.70 |

The owner's reported exercise level **is** the adjustment: 50–200%, default
100%, in whole percentage points (API decimal 0.50–2.00). It is applied exactly
once. There is no separate exercise-level multiplier or profile setting that
can drift from the target revision.

The server calculates age on the selected effective date, using completed
calendar months and birthdays. A missing anniversary day clamps to month end;
a 29 February birthday falls on 28 February in non-leap years. The first
birthday itself uses 1.00. Exactly ten years still uses 1.00; the next day uses
0.75. A saved target is fixed until another explicit revision: birthdays and
profile/breed edits do not silently recalculate existing or scheduled targets.
Review and save a new target when the dog's needs change.

`Dog.weight_kg` is the only new profile field: nullable decimal kilograms with
two decimal places. Existing birthday, breed energy and dog-specific
brachycephalic fields are reused. Unknown or unrecognised breed energy uses
1.00. Missing weight or birthday is not inferred from size or recorded age;
missing breed or brachycephalic status is also ineligible. Legacy profiles
remain editable without a weight or birthday but cannot save personalised
targets until those inputs are supplied. Existing manual targets keep working.

Calculations use exact Decimal arithmetic with no intermediate rounding.
Multiply final target minutes by 60, then round to the nearest integer second,
with exact half seconds rounded **up** (`ROUND_HALF_UP`). All progress uses that
integer. The UI shows the exact recommendation in minutes and the resulting
target in minutes/seconds. For example, a 15 kg high-energy non-brachycephalic
adult gets 62.5 minutes; 50–200% gives 31.25–125 minutes (1875–7500 seconds).

Each revision preserves policy version, weight, birthday, age calculation date
and completed months, breed identity/name/energy, brachycephalic status, every
factor, the owner's adjustment, exact suggested/target minutes and rounding
rule. Newly materialised daily snapshots copy those calculation details and
retain the immutable target ID. The existing `manual-duration-v1` daily progress
rules stay unchanged; calculation policy is separate from walking eligibility.

Authenticated OWNER API:

- `GET /api/dogs/{id}/goal?owner_adjustment=1.00`: read-only preview plus current
  and scheduled targets. Optional `effective_from=YYYY-MM-DD` previews another
  date. The default date is today for an unconfigured dog, otherwise the later
  of tomorrow or one day after this ownership version's last scheduled revision,
  skipping dates already reserved by older ownership revisions. This avoids
  silently displacing a future Admin change in the owner UI.
- `POST /api/dogs/{id}/goal`: `{ "effective_from": "2026-10-07",
  "owner_adjustment": "1.00" }`. Date is required; omitted adjustment means
  100%. Returns 201 with the recomputed recommendation and saved revision.
  Invalid profile, adjustment, past/same-day changes or duplicate dates return
  400; another owner's dog returns 404. Unknown request fields, including
  client-calculated seconds and a second exercise factor, are rejected.
- `PATCH /api/dogs/{id}` accepts `weight_kg` as decimal text or null through the
  existing profile service. Profile saves do not configure targets.

Saving revalidates current ownership, profile inputs and date under the same
owner/dog locks used by Admin and uploads. If a preview became stale, the server
recalculates from the current profile; the saved response shows the actual
target. Duplicate submissions cannot create a second target on that date.

`DogGoalTarget` records effective-dated configuration and the owner at approval.
The existing `DogDailyGoal` stores each eligible day's frozen target, inputs and
final result. Missing days are materialised on the next Quest read, so being
away from the app does not hide missed days. Configuration changes do not alter
earlier targets. Unconfigured days, days before the dog's creation and days
before its first effective target are not missed. Owner transfers do not carry
another owner's configuration or walking time into the new owner's progress.
Deleted dogs retain target and daily snapshots via immutable dog IDs.

Admin transfers and normal `Dog.save()` ownership changes advance
`goal_owner_version`; approved targets record that version. Even a transfer back
to an earlier owner requires a new target. Use Admin or normal model saves for
transfers, not bulk `QuerySet.update(owner=...)` or raw SQL, which bypass model
hooks. Existing dog/date snapshots are never reassigned to another owner.
Any later revision still starts tomorrow or later, including after a transfer.
Admin validates duplicate effective dates while holding the same owner/dog locks
as configuration and uploads. Normal target saves/deletes cannot rewrite history.

Only walks started strictly after the target was configured can qualify. Old uploads,
unverified legacy walks, local-only records and unselected dogs are excluded.
There is no migration backfill of goals, points or configuration.

## Time and streaks

Use **Australia/Melbourne** throughout, including daylight-saving transitions.
The server returns the date, time, timezone and next midnight. The client shows
the server's results and hides a cached goal calendar after that date ends.

Consistent with existing walking points and walking-day streaks, a walk crossing
midnight contributes its entire validated active duration to its Melbourne
**end date**, once. Duration is the sum of accepted moving GPS intervals;
pauses, stationary intervals, missing GPS and rejected segments do not count.
Elapsed-time arithmetic uses UTC so a skipped or repeated DST hour does not
change the measured walking duration. The walking-day streak and goal services
share the same persisted validation checks.
Every explicitly selected dog receives its own validated participation time;
dog count does not multiply base walking points. Overlapping owner uploads are
already rejected. Walk request IDs and WalkDog uniqueness prevent retry double
counting. Net-walk intervals refer to those same base walks and add no goal time.
There is still no public shared-walk matcher or net-walk reward producer.

Each dog shows the seven calendar days ending today: completed, missed,
incomplete today, or not eligible. Its goal streak counts consecutive completed
days. Incomplete today preserves yesterday's run; a finished missed day breaks
it, even if nobody opened the app. A gap with no configured target is not called
missed and cannot bridge two runs. A paused or unconfigured today has a zero
current streak. Targets may differ across the run.

The existing upload deadline is 12 elapsed hours from walk start. Yesterday's
result can therefore be corrected by a valid late upload. Daily results freeze
12 elapsed hours after the following Melbourne midnight (using UTC arithmetic
across DST). A missed label before that deadline can become completed upon a
valid upload. Reads freeze progress only; they never credit points.

## Reward accounting and remaining decisions

The user confirmed the documented baseline: **40 walking + 20 daily goal + 12
check-in within the 72-point combined cap**. `daily_activity_points` now counts
WALK, DAILY_GOAL and CHECK_IN ledger credits. Goal membership in the cap is no
longer an open decision. Existing balances and reward history are untouched;
earlier awards are never reduced. Full rewards require enough remaining
allowance; no partial goal reward has been invented.

Client confirmation still required:

- Are goal rewards and the combined cap per dog or per account? Client
  Requirements allows two dogs with separate points; older once-per-account
  wording is not definitive.
- Must any dog or all participating dogs qualify? How is that participant set
  frozen, especially if another dog joins a later walk that day?

The existing account-based walking/check-in accounting continues while goal
payouts are disabled. Do not enable goal payments merely by switching on a
QuestDefinition. `quests.goals.settle_reserved_goal` is an **internal settlement
foundation with no production caller or qualification producer**. A future
approved backend qualifier must supply an immutable reward scope, policy
version, required daily goal IDs and expiry. Settlement rechecks ownership,
active account, day, progress and cap under the same owner lock as other rewards.
It also locks the participating dogs, requires their current ownership revision
and approved target inputs, and rejects missing/deleted/transferred dogs and
malformed qualification snapshots. Already credited qualifications remain
replayable by their original recipient without creating another credit.
The existing unique QuestAward qualification key, one-to-one credit and unique
PointEntry source reference make repeated/concurrent settlement return one
credit. No HTTP route or frontend can supply a qualification or grant points.
Tests use explicitly synthetic qualifications to exercise this dormant path.
The approved qualifier must define scope-specific daily uniqueness before launch;
this change deliberately does not impose account/day uniqueness on an unresolved
per-dog policy. Historical days will not automatically receive future awards.

Wallet balance remains `get_balance` over unexpired remaining PointEntry credits.
Walk receipts show base walking awards, Quest receipts show their own rewards,
and the daily activity total is distinct from spendable balance. Birthday,
document and existing walking-streak bonuses remain legitimate separate credits;
net-walk ledger metadata exists without a production earning path. Redemption,
expiry, refunds and admin grants still use the same ledger. The iOS client never
increments a wallet locally. Walk completion invalidates older Quest responses
and queues a fresh read in the same serialized operation. Concurrent polling and
walk/document notifications cannot discard another request's task handle. The
wallet uses its existing queued server refresh. Calendar validation checks seven
ordered dates ending today, identities, durations and completion states before
display. Time awaiting a response is included when expiring the calendar, so a
slow pre-midnight response cannot give yesterday's calendar a new cache lifetime.
Foregrounding, polling, retry and account teardown reuse the existing stores.

## Migration and verification

The [personalisation implementation report](PERSONALISED_GOALS_IMPLEMENTATION.md)
records the fresh 6 October 2026 result: **418 Linux MySQL tests passed with no
skips**, the blocked iOS build/XCTest checks, and the iPhone test checklist.

`dogs.0005_doggoaltarget` adds only the target revision table, foreign keys and
positive-target/identity and dog/effective-date uniqueness constraints. Existing
walks, daily-goal snapshots, awards and balances are preserved.

`dogs.0006_goal_owner_versions` adds ownership revisions to dogs and target
approvals, initially zero to retain existing configuration. It does not rewrite
targets, snapshots, walks or ledger entries, or try to infer past transfers.
Forward preservation is covered by a migration regression test. Apply it through
the normal deployment migration process; review/test commands do not migrate the
working database.

`dogs.0007_personalised_goals` adds nullable weight and immutable calculation
metadata, and adds VERY_HIGH/UNKNOWN breed choices. Legacy targets retain the
manual policy with empty calculation inputs; no invented weight, targets,
snapshots, walks, points or payout backfill is created. Apply migrations through
the normal deployment process. Verification only migrates disposable databases.

Run `DATABASE_ENGINE=sqlite python manage.py test` and the usual Django checks.
The new tests cover accumulated walks, selected dogs, retry uploads, midnight,
DST, late uploads, missed days, target changes, unconfigured days, preserved
history, shared/net intervals and ledger/cap/settlement consistency. Concurrency
tests require disposable MySQL. iOS Quest tests cover calendar presentation,
midnight invalidation, refresh after an in-flight read and appearance at large
text sizes. See the implementation report for checks actually run; test source
alone is not evidence of a successful iOS build or MySQL locking test.

### Verification recorded on 4 October 2026

- Full isolated SQLite suite: 361 tests, 341 passed, 20 skipped (MySQL-only
  locking/backend checks). No failures.
- Django system check: passed. Migration drift check: no changes detected.
- Forward migration preservation is covered by the full suite; existing daily
  targets/results and ledger balances remain unchanged.
- Swift syntax parsing passed for the changed application and Quest test files.
- Full iOS build, XCTest and visual snapshots could not run: only Command Line
  Tools are installed, with no Xcode/iOS SDK. Snapshot tests are added but their
  appearance remains unverified on a simulator/device.
- Docker is not running, so MySQL concurrency checks could not run. SQLite tests
  do not establish real row-lock correctness. Run the MySQL-only cases against a
  disposable database before enabling the future payout path.

### Review on 5 October 2026

See [the local review report](DAILY_GOALS_REVIEW.md) for reproduced failures,
changes, current verification results and the physical-iPhone retest checklist.
The earlier macOS/SQLite result above is historical and is not a substitute for
the current platform-specific results.
