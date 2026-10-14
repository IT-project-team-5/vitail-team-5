# Daily walking goals

Updated 10 October 2026. Each dog can explicitly collect **20 points per Melbourne
day** after completing its own goal. Walking, goals and check-ins share the
owner account's **72-point cap**. Walking-day streak bonuses stay separate.
Backend verification and outstanding iPhone acceptance are recorded in
[the implementation report](OWNER_JOURNEY_REPORT.md).

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
  If the latest revision is the maximum representable date (9999-12-31), there
  is no following day: preview falls back to the first free permitted date.
  This leaves that far-future revision and every existing snapshot unchanged.
- `POST /api/dogs/{id}/goal`: `{ "effective_from": "2026-10-07",
  "owner_adjustment": "1.00", "request_id": "UUID" }`. Date is required; omitted adjustment means
  100%. Returns 201 with the recomputed recommendation and saved revision.
  Invalid profile, adjustment, past/same-day changes or duplicate dates return
  400; another owner's dog returns 404. Unknown request fields, including
  client-calculated seconds and a second exercise factor, are rejected.
- `PATCH /api/dogs/{id}` accepts `weight_kg` as decimal text or null through the
  existing profile service. Null is accepted only for already-unknown legacy
  weight; a known weight cannot be cleared. New dogs require positive weight.
  Profile saves do not configure targets.

Saving revalidates current ownership, profile inputs and date under the same
owner/dog locks used by Admin and uploads. If a preview became stale, the server
recalculates from the current profile; the saved response shows the actual
target. Duplicate submissions cannot create a second target on that date. An optional
request UUID replays the original saved revision after network failure, profile
changes or midnight; changing its adjustment/date is rejected. iOS persists the
original request until confirmed, and uses debounced read-only slider previews.

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
counting. Net-Walk intervals refer to those same base walks and add no goal
time. The connected social session can verify together-distance, but it does
not produce a goal qualification or wallet reward.

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

## Daily reward qualification and accounting

`POST /api/quests/goals/{dog_id}/collect` accepts only
`{"local_date":"YYYY-MM-DD"}`. The backend checks the current owner, enabled
quest, current Melbourne date and actual eligible progress. It reserves a
versioned dog/day qualification and calls the existing `settle_reserved_goal`
service, which rechecks frozen target inputs and ownership before crediting.
The response contains the award ID, dog/day, 20 points, canonical PointEntry ID,
collection timestamp, current wallet balance and whether this was a new credit.
New credits return 201; successful retries return 200, including after midnight.
A new claim for a previous day is rejected. Late valid uploads can still correct
historical goal progress under the existing deadline, without opening past rewards.

Dog A and Dog B collect separately, potentially earning 40 goal points. Neither
completion, preview, profile save nor Quest reads issue points. The shared
activity total includes WALK, DAILY_GOAL and CHECK_IN credits. At 52 earned
points one full 20-point goal can bring the account to 72; at 53 the reward is
unavailable because only 19 remain. No partial credits or displacement of earlier
credits occurs. Each task explains insufficient allowance.

The owner lock serializes competing dog collections, walking and check-ins.
The dog/day uniqueness constraint, unique qualification key, one-to-one credit
and unique ledger source prevent duplicate collection. Original paid receipts
remain replayable only by their recipient. Ownership transfers require the new
ownership revision's target; they do not reopen a dog's already collected day.
The server creates qualification snapshots; no client can supply an award amount,
completion flag or qualification inputs. No historical payout backfill occurs.

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

The implementation must be verified in the backend and iOS suites before
merge. iOS build, simulator and physical-device acceptance are still unverified
on this Windows implementation host. The commands below remain the reproducible source of truth; historical
test counts are not used as a current result.

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

Run the backend suite against disposable MySQL and the usual Django checks.
The new tests cover accumulated walks, selected dogs, retry uploads, midnight,
DST, late uploads, missed days, target changes, unconfigured days, preserved
history, shared/net intervals and ledger/cap/settlement consistency. Concurrency
tests require disposable MySQL. iOS Quest tests cover calendar presentation,
midnight invalidation, refresh after an in-flight read and appearance at large
text sizes. Test source alone is not evidence of a successful build; record only
results produced by the current checkout.

`accounts.0006` defaults existing accounts to completed onboarding. Newly registered
owners explicitly start incomplete. `dogs.0008` adds nullable request UUIDs and
the dog creation fingerprint; it does not change historical profiles or targets.
`quests.0004` allows per-dog daily qualifications and adds kind/dog/day uniqueness.
Existing legacy qualifications with null dog IDs remain valid. None of these
migrations deletes records or creates points.
