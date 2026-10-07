# Quest and Point Policy

Canonical reward reference, updated 4 October 2026. Latest source:
[New Point Retrieval / Calculation](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/27525122/New+Point+Retrieval+Calculation),
24 September, plus subsequent confirmed collection/UI decisions.
[Open questions](DECISIONS.md#open-decisions) remain explicit; a published reward
amount does not mean its qualification engine is implemented.

## Reward rules and delivery

| Source | Policy | Current delivery |
|---|---|---|
| Walking | 8 points/km; maximum 40 per Melbourne day; dog count does not multiply the award | Connected: server validates confirmed uploads and rounds cumulative daily distance down |
| Daily goal | 20-point baseline; per-dog/account scope remains open | Per-dog personalised owner and manual Admin targets share one history; progress and goal streaks connected; payouts disabled pending multi-dog rules |
| Venue check-in | 12 points; at most one daily opportunity per type, four types total | Connected venue GPS start/resume/cancel, server-verified dwell and ledger collection; physical acceptance pending |
| Birthday | 60 points per dog/year, on the actual birthday | Connected: explicit Collect |
| Council registration | 300 points per dog per confirmed registration period; renew after its actual expiry | Connected: document reading, confirmed expiry, then Collect; expired pending rewards are unavailable |
| Microchip registration | 300 points once per dog in its lifetime | Connected: entered number or proof, then Collect; no certificate validity dates |
| Vet check-up | 200 points per visit, at most two per visit calendar year and at least 60 days apart | Connected: evidence with actual visit date, then Collect |
| Streak | Each consecutive run: 7 days earns 20 points; 30/60/90… days earn 100 points each | Connected: validated walking days, one progress bar and explicit Collect |
| Net-walk | 2 points/km, maximum 10/day | Data foundation only; no proximity matcher or award implementation |

The implemented shared activity cap is **72 points per Melbourne day for walking, daily goals
and check-ins**. Wallet balance is not this counter: spending/refunds, admin
grants and birthday/document credits do not change the activity-earned total.
Goal cap membership was confirmed on 4 October (40 walking + 20 goal + 12
check-in). Multi-dog reward/cap scope and net-walk membership remain unresolved.
Earlier documents
that simply sum all proposed sources must not silently change the service.

A check-in with less than its full promised reward remaining cannot currently
collect; partial awards are disabled pending a decision. Earlier awards are not
retroactively reduced. Read requests never create credits.

Points expire twelve calendar months after earning. Refunds create new credits
with a new expiry while retaining the original debit/order history. One
canonical PointEntry ledger supplies all balances.

Policy estimates are **about 72 points for a dog treat/Puppuccino and 504 points
for a coffee**. The wallet uses 504 for its coffee comparison only. Cafés set
actual product prices; policy changes do not reprice existing menus or orders.

### Check-in qualification target

| Venue type | Required verified dwell |
|---|---|
| Vet | 3 minutes |
| Park | 5 minutes |
| Café | 10 minutes |
| Restaurant | 20 minutes |

The current policy specifies a 20-metre radius and explicit user initiation.
Authenticated start and location reports verify proximity and dwell on the
server; gaps over 90 seconds reset progress. A device countdown or existing
CheckIn row alone is not proof of completion. Physical-device acceptance is
still pending, and no peer live-location matcher is delivered.

## Task presentation

Owner navigation is Account / Walk / Quest / Redeem. There is no leaderboard
tab/endpoint in this delivery; its feature belongs to another teammate.

Quest uses compact horizontal avatar/venue rows with detail sheets. READY rows
are highlighted first, IN_PROGRESS rows follow, and COLLECTED rows are muted at
the bottom. Collection happens in the detail sheet. Base walking is not a task
row. Unavailable birthdays, ineligible documents and unimplemented goal
rewards produce no placeholder rows or invented percentage.

Streak uses one progress bar with only `x / 7`, `x / 30`, `x / 60` and later
30-day milestones. A completed milestone fills and highlights the bar; tapping
opens its details and Collect. Collection advances to the next available target
instead of adding another collected streak row.

A collected row remains only on its **Melbourne collection date**. Hiding it at
midnight does not delete evidence, qualification or ledger history. The client
uses the server's date baseline, rejects older-day snapshots and retains
confirmed collection through stale responses or failed refreshes. Device time
never qualifies a reward.

Dog birthdays are explicit nullable dates; legacy age-only records keep unknown
birthdays. Known birthdays determine age. The observed non-leap-year date for
29 February is undecided, so only the actual anniversary qualifies. Per-dog/year
uniqueness survives ownership changes; an old recipient can replay their own
receipt without giving a new owner another award.

## Daily goals

[Daily goals](DAILY_GOALS.md) documents personalised owner and manual Admin target configuration,
seven-day calendars, duration eligibility, history and the disabled payout path.
The goal-completion streak is separate from the following existing reward.

## Walking streaks

A qualifying day has at least one server-validated walk with actual movement.
Use the walk's Melbourne end date, count each date once per account, and count
valid walks even if rounding or the daily activity cap gave them zero points.
Stationary, simulated, rejected, local-only and unverified legacy records do not
qualify. Daily Goal completion is not required, and multiple dogs do not multiply
the day count.

Yesterday's run remains current while today is still in progress. A full missed
Melbourne day breaks the run; the next qualifying day starts again at one. Each
new run can earn its own seven-day reward, then the 30/60/90… milestones.
Already earned, uncollected milestones remain available after a break; the
single bar shows the oldest uncollected milestone first. No claim expiry is
introduced. Existing verified walks can establish progress without creating
credits on reads.

The server recomputes eligibility before collection and locks the owner's
account. `QuestAward` identifies owner, run start and milestone, and links one
canonical ledger credit. Repeated or simultaneous requests return the same
award. Streak credits do not consume the walking/goal/check-in daily cap. No new
progress table or client-generated qualification is used.

## Evidence: submit, then collect

Council, microchip and vet evidence are self-reported per dog. An eligible
submission reserves a DocumentEntitlement and preserves an immutable submission
version with zero newly awarded points. Explicit Collect links one ledger credit.
Re-uploading the same qualification does not create another reward. Microchip
has one lifetime reward per dog; prior credits and historical receipts remain
intact and cannot produce a second lifetime credit.

Council uses the **confirmed expiry printed on the document**. `valid_to` is
inclusive in Australia/Melbourne: a document expiring on 15 June remains eligible
through that day; the renewal task opens at local midnight on 16 June. There is
no fixed 10 April reset and no upload-date-plus-one-year calculation. Expired or
superseded pending Council rewards disappear from Quest and cannot be collected.
They do not remain alongside the new task. Historical files, receipts and ledger
entries remain private records; hiding a task does not delete those records.

Only one Council qualification is active per dog. An unexpired paid registration
blocks a new reward. Profile corrections can update its actual expiry but cannot
advance its reward renewal boundary or create another qualification. Once it expires, renewed evidence with a later valid expiry may
reserve the next reward. The same animal number may recur after renewal; an
identical file cannot support another qualification. Ownership transfers do not
reset eligibility. Explicit collection rechecks expiry under the dog lock.

Historical Council rows with unknown expiry do not acquire an invented date from
their old registration year. The current legacy qualification first requests
its actual expiry. Updating an already paid qualification earns no extra points;
an update-only task hides the reward amount. Earlier superseded pending rows are
not offered. Old annual columns/keys and immutable receipt snapshots remain for
compatibility; they no longer qualify a reward or schedule the next task.

Each task opens its fixed dog/type. **Upload proof is the default**; entered
details remain a secondary route. PDF/JPEG/PNG selection starts on-device reading:
PDFKit extracts a text layer, and Apple Vision reads images or rendered PDF pages
when needed. Council suggestions include council, animal registration number,
printed dog name and explicitly labelled expiry; microchip suggestions include
chip number, registry and printed dog name, without an expiry requirement.

Users inspect and confirm the short fields before submission. Unreadable or
ambiguous values stay empty for correction or a replacement file. Payment due
dates, birthdays and issue dates are not silently used as expiry. Printed dog
identity is kept separately from the app's dog name. Extracted candidates and
confirmed values retain distinct provenance; full OCR text is not stored as a
second copy. Reading does not establish authenticity, official completion or
ownership, and no registry lookup or automatic verified status is implied.

Submission UUIDs replay their original response, even across expiry; changed
payloads under one UUID conflict. An already paid collection can replay its
original receipt but never credits again. Account changes reject late client
responses; confirmed success survives a failed refresh and queues the wallet
refresh. Private originals remain owner/admin-readable for later spot checks.
Dog settings now provides **Registration documents** for Council and microchip.
It shows the current record even after collection or expiry, permits corrections
and attachment replacement, and separates renewal from editing. Corrections create
an immutable evidence version under the same entitlement and award zero points.
The actual expiry is editable; the latest confirmed expiry remains the earliest
renewal boundary. Shortening expiry cannot advance a reward, while extending it
postpones renewal. Settings shows both dates when relevant. Original records remain
private and the dog's separate profile chip number stays unchanged. A successful
edit invalidates cached registration Quest rows before a fresh server read.

File limits, expiry selection and migration compatibility are documented in
[evidence documentation](../backend/evidence/README.md).

## HTTP contract

[OpenAPI](openapi.yaml) defines fields and permissions. These routes accept both
trailing-slash styles. OWNER authentication is required; original-file downloads
also permit ADMIN.

| Method | Route | Result |
|---|---|---|
| GET | `/api/quests` | `server_time`, `timezone`, `local_date`, `next_reset_at`, `tasks`, `daily_goals`, `goal_rewards_status` |
| GET | `/api/dogs/{id}/goal` | Preview the next effective personalised target and current/scheduled target history |
| POST | `/api/dogs/{id}/goal` | Save one immutable target revision using the confirmed preview inputs |
| POST | `/api/quests/birthdays/{dog_id}/collect` | Existing or newly created birthday credit receipt and balance |
| POST | `/api/quests/streaks/collect` | Collect one server-qualified run/milestone; replay returns its existing credit |
| GET | `/api/quests/documents` | Dogs, evidence versions, management records, current entitlements and eligibility |
| POST | `/api/quests/documents` | Saved evidence and reserved entitlement; no new credit |
| POST | `/api/quests/documents/{id}/corrections` | Latest registration version corrected under its original entitlement; no credit |
| POST | `/api/quests/documents/entitlements/{id}/collect` | One entitlement's collection receipt and balance |
| GET | `/api/quests/documents/{id}/file` | Authenticated original-file download |

Each task includes a stable ID, kind/state, title/subject/avatar, detail, reward,
optional measured progress, dog/entitlement IDs and collection timestamp. iOS
also uses Council's actual expiry and entitlement identity to scope tasks and receipts. It
ignores unused presentation fields and unsupported kinds/states. The old
`daily_goal`, `streak`, `birthdays`, `check_ins` and `documents` dashboard
projections are removed; the document dashboard has its own route. Daily-goal
progress is now supplied by the typed `daily_goals` envelope and dog goal route.

QuestDefinition switches gate new supported work. They do not implement a
missing payout policy or future capability. Historical receipts and authorized file access remain
available when new awards are disabled.

## Venue integration

Production dependencies inject `CheckInProgressService` and
`VenueCheckInService`. The Venues tab uses `CheckInLocationManager` for explicit
start/resume, location reporting, cancellation and collection. Walk and Quest
share `CheckInProgressStore`. Venue IDs are integers; check-in IDs are attempt
UUIDs and must never be interchanged. APIs are listed in [OpenAPI](openapi.yaml).

The server measures continuous dwell from receipt times, with a 90-second
maximum gap. The client reports fresh precise fixes at most once per 25 seconds
and displays only server-verified seconds. A long gap or leaving the radius
resets progress. Background delivery is best effort; a locked phone is not a
guarantee of qualification. Pending permission/start/report work is cancelled
on teardown, and late responses cannot replace a newer attempt. An existing
IN_PROGRESS venue offers Resume after relaunch. GPS check-ins do not create
walk records or walking points; each earning path uses the same ledger/cap.

```swift
func fetchProgress() async throws -> CheckInProgressSnapshot
func collect(id: String, requestID: UUID) async throws -> CheckInCollectionReceipt
```

A snapshot supplies at most four daily opportunities with stable IDs, venue
identity/photo, required and server-verified seconds, reward, state and real
collection timestamp. It also supplies consistent Melbourne `serverTime` /
`localDate` and authoritative `earnedPointsToday` from zero to 72.

Below the cap, active opportunities remain visible, including zero verified
progress. At the cap, active rows hide; today's collected rows remain. Keep
collected slots in the snapshot so another offer cannot replace them as a fifth
opportunity. Collection returns the actual item/credit, wallet balance, daily
activity total and date. The server enforces ownership, qualification, daily
uniqueness and the full-reward allowance; it never trusts client progress.

Walk map and Quest share one store, serialized collection and stable ambiguous-retry
request UUIDs. Venues collection also uses the same backend check-in/credit;
idempotency is enforced by the attempt and its one credit, including concurrent
collection through different surfaces. Confirmed state/cap cannot be undone by old responses. Previous-day rows
hide until a fresh snapshot arrives. Foreground Walk/Quest polling is five
seconds and stops when inactive. Neither verified progress nor points advance
using the device clock.

## Validation boundary

Backend tests cover dates, eligibility, permissions, ledger atomicity, receipt
replay and migration preservation. Use disposable MySQL for lock/concurrency
cases; SQLite intentionally skips those checks. iOS tests cover task visibility,
collection, account changes, stale responses, midnight, cap presentation and
wallet refresh races, with light/dark/large-text snapshots.

These tests do not certify physical GPS/background behavior,
unimplemented peer-location/social APIs or disabled goal/net rewards. Record actual
run results with the build under test; use [feature status](FEATURES.md) and
[Walk device tests](WALK_TESTING.md) for remaining acceptance work.
