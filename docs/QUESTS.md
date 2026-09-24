# Quest integration — 25 September 2026

Owner navigation is **Account / Walk / Quest / Redeem**. Leaderboard belongs to
another teammate: this slice's tab, services, views, backend endpoint and tests
have been removed. Existing walks, dogs, points and evidence are preserved.

## Available tasks and presentation

Quest is a compact list without a large heading or unavailable placeholders.
Each horizontal row has a pet avatar or venue symbol, task name, subject and
state. Tap for a detail sheet containing the conditions, progress and reward.

| State | Presentation | Action |
|---|---|---|
| `READY` | Highlighted, at the top | Tap details, then Collect |
| `IN_PROGRESS` | Normal row with progress where measurable | Tap details to continue |
| `COLLECTED` | Muted, below all active rows | Read details; no further credit |

Collected rows remain only on their **Melbourne collection date**; after local
midnight they leave the main list. Original evidence, entitlement and ledger
records remain. Device display expiry does not qualify or award a reward.
Unknown task kinds/states never become collectible. Successful collection stays
visible when a subsequent refresh fails or returns older data.

| Kind | When it appears | Reward |
|---|---|---|
| Birthday | Actual birthday today, or the owner's collection today | 60 per dog per year |
| Council registration | Eligible dog without a lifetime entitlement, pending proof, or collection today | 300 once per dog |
| Microchip registration | Eligible annual period, pending proof, or collection today | 300 per annual registration period |
| Vet check-up | Current quota/date eligibility, pending proof, or collection today | 200, maximum twice per visit calendar year, at least 60 days apart |
| Venue check-in | Provider-supplied daily opportunities below the combined cap; today's collections remain below | Provider confirms actual reward and cap |

Daily goal targets and live dog attribution await the formula. Streak award
delivery is not enabled. These capabilities do not produce actionable task rows
until implemented; legacy summary fields remain in the API for compatibility.
Base walking is not a Quest row. Its existing rule remains 8 points/km, maximum
40 walking points per day. Leaderboard is outside this slice.

Explicit nullable dog birthdays never invent dates for old age-only profiles.
Known birthdays determine completed-month age. An observed non-leap-year date
for 29 February remains undecided; actual birthday anniversaries are used.
Microchip rewards currently use explicit annual validity periods; a switch to
calendar-year entitlement remains a separate product decision.

## Submit, then collect

Evidence is self-reported; no up-front review or authenticity verification is
claimed. Eligible submission reserves a `DocumentEntitlement`, preserving a
`DocumentSubmission` version with zero awarded points. **Only explicit Collect
creates a ledger credit.** Later spot-audit workflows are not implemented.

The original three document rules, file limits and validation remain described
in [the evidence documentation](../backend/evidence/README.md). Pending
entitlements reserve quota, so additional submissions cannot evade limits.
Re-uploading proof for the same qualification reuses the same entitlement.
Stable submission UUIDs replay their original stored response; a changed payload
under the same UUID returns 409. The live dashboard provides current status even
when an old submission response describes an earlier state.

Collect locks the owner, dog and entitlement and links one canonical `PointEntry`.
Repeated or simultaneous collection from Quest and Documents returns the same
reward without another credit. Account changes discard late client responses.
After collection the canonical wallet refresh is queued even if another load or
purchase is in progress. Successful receipts survive follow-up refresh failures.

The additive `evidence.0002_documententitlement_collected_at` migration copies
existing credits' creation timestamps. It does not revoke, replay or create
credits. Prior submission receipts remain unchanged. A transferred/deleted dog's
historical credit stays with its recipient; prior owners see their submitted
name snapshot rather than another owner's updated profile.

Private evidence remains under `backend/private_uploads/`, outside public media.
Only the submitting owner or admin may download files. Preserve original bytes
and back up private files with the database. Retention and audit procedures are
separate policy decisions; the Quest list's daily hiding does not delete files.

## API

See [OpenAPI](openapi.yaml) for request/response fields and permissions. All routes
accept both trailing-slash styles. OWNER authentication is required except file
downloads, which also allow ADMIN.

| Method | Route | Result |
|---|---|---|
| GET | `/api/quests` | Server date/reset and ordered actionable `tasks`, plus legacy summary fields |
| POST | `/api/quests/birthdays/{dog_id}/collect` | Birthday credit receipt and balance |
| GET | `/api/quests/documents` | Dogs, immutable evidence versions, current entitlements and eligibility |
| POST | `/api/quests/documents` | Saved evidence and reserved reward; no new credit |
| POST | `/api/quests/documents/entitlements/{id}/collect` | One entitlement's credit receipt and balance |
| GET | `/api/quests/documents/{id}/file` | Authenticated original-file download |

`tasks` carries stable IDs, kind/state, title/subject/avatar, detail text,
reward points, optional progress, dog/entitlement IDs and collection timestamp.
Unavailable birthdays and ineligible document opportunities are excluded.
Read endpoints never award points. `QuestDefinition` switches gate new work;
completed request replays and historical file access remain available.

## Venue teammate handoff

Location verification, the actual check-in backend and map start/discovery flow
belong to the venue feature. Implement `CheckInProgressServing` and inject it
through `OwnerHomeView(checkInService:)` with the shared authenticated API client.
No invented HTTP endpoint, local dwell qualification or fabricated venue rows
are supplied while this provider is absent.

```swift
func fetchProgress() async throws -> CheckInProgressSnapshot
func collect(id: String, requestID: UUID) async throws -> CheckInCollectionReceipt
```

A snapshot contains:

- `items`: at most **four** daily opportunities, with stable daily IDs, venue
  identity/photo, required seconds, server-verified seconds, reward points,
  status (`inProgress`, `ready`, `collected`, `cancelled`) and actual `collectedAt`.
- `earnedPointsToday`: the authoritative **walking + check-in** earned total,
  from 0 to 72. It is never wallet balance and excludes birthday/document bonuses.
- `serverTime` and `localDate`: a consistent Australia/Melbourne day.

All four opportunities remain visible below 72, including ones not started yet
(`inProgress`, zero verified seconds). At 72 uncollected opportunities disappear;
collected opportunities remain at the bottom through the collection day. Keep
collected daily slots in the snapshot so they are not replaced by a fifth offer.

Collection receipts include the collected item, actual awarded points,
`walletBalance`, `dailyEarnedPoints`, and `localDate`. The backend must enforce
owner scope, daily maximum count, dwell qualification, cap and idempotency. It
must return actual credited points when the remaining daily allowance is smaller
than the nominal reward. iOS displays the remaining allowance but does not credit
or independently decide qualification.

Both map and Quest observe one store and use the same compact card/detail flow.
Duplicate taps are serialized; ambiguous retries keep the same UUID. Confirmed
collections and the cap cannot be undone by stale/older-day responses. At local
midnight the previous daily rows are hidden until a fresh snapshot arrives.
Foreground Walk/Quest polling runs every five seconds and is cancelled when
leaving/backgrounding. Neither progress nor points advance using device time.

## Validation

Run backend discovery from `backend/` or use `make test`; repository-root Django
discovery can accidentally run zero tests. SQLite covers API logic, dates,
permissions, migration preservation, file failure and receipt replay. MySQL
transaction tests use an isolated test database for simultaneous collectors.
Never run test flushes against the demo database.

The iOS suite covers row availability, explicit document/birthday collection,
session changes, stale responses, Melbourne midnight, four venue slots, the
72-point cap, wallet refresh races and light/dark/accessibility snapshots.
Physical-device GPS and the teammate's real check-in provider remain separate
integration acceptance work.

This revision passed 214 backend tests on an isolated MySQL 8.4 database and
266 iOS simulator tests, with one physical-device protection test skipped.
Seven Quest list/detail appearance snapshots were exported and the light, dark
and accessibility layouts inspected. Django migration drift checks passed;
local authenticated HTTP reads returned actionable tasks and the removed
leaderboard route returned 404. The additive evidence migration was applied
after a database backup, and the signed simulator build was updated.
