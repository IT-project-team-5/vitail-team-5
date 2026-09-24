# Quest integration — 25 September 2026

This slice adds Account / Walk / Quest / Leaderboard / Redeem navigation, dog
birthdays, self-reported document rewards, and shared check-in presentation.
The policy source is the client meeting's **New Point Retrieval / Calculation**
table, followed by the owner's decisions in the implementation conversation.

## Implemented rules and boundaries

| Quest | Display / qualification | Award |
|---|---|---|
| Daily goal | Each dog's accepted distance today; targets and completion stay null until the formula is confirmed | Not enabled |
| Walking streak | Consecutive Melbourne dates with a positive-distance accepted walk; current, longest and next milestone on the outer card | Milestones describe 7 days → 20 and 30/60/90… → 100; automatic/claim awards not enabled in this slice |
| Birthday | Explicit date of birth; missing dates prompt profile editing; birthday-day collection | 60 per dog per year, through the canonical point ledger |
| Council registration | Number and/or PDF, separately for each dog | 300 once per dog |
| Microchip registration | Number and/or PDF with annual validity dates, separately for each dog | 300 per eligible annual registration period |
| Vet check-up | Actual visit date and JPEG/PNG evidence, separately for each dog | 200, at most twice per visit calendar year, at least 60 days between rewarded visits |
| Venue check-in | Both map drawer and Quest observe one verified progress store | The venue feature supplies qualification, collection and the authoritative receipt |

Base walking is not a separate Quest card. Existing walking awards remain
8 points/km, maximum 40 per day. Leaderboard provides **This week / All time**
using accepted walking distance, walk count and walking points. It is explicitly
self-only until the separate friends feature exists; it does not rank strangers
or include purchases, grants, refunds or birthday/document points as walking.

New dog forms request a date of birth. Existing age-only profiles remain
editable and are never assigned a fabricated birthday. Known birthdays drive
completed-month age calculation. Date-only fields do not shift with device time
zone. Birthday reward dates and reporting weeks use Australia/Melbourne; weeks
start Monday and local midnight boundaries account for daylight saving.

Open product decisions remain visible rather than becoming guessed values:

- Daily target formula, units, welfare/heat factors and live walk dog attribution.
- Whether annual microchip rewards use actual registration periods or calendar
  years. The current implementation follows explicit annual validity periods.
- Which non-leap-year day observes a 29 February birthday. The current birthday
  collector accepts actual anniversaries only; age calculation separately clamps
  month-end anniversaries.
- Final streak award delivery and historical eligibility; the current streak
  card reports accepted activity without awarding points.

## Server ownership

`QuestDefinition` controls the five typed catalogue entries. It is not a generic
rules engine. Accepted `Walk` rows supply activity, `Dog` supplies profile facts,
and `PointEntry` remains the only wallet. `QuestAward` records birthday entitlement
and its ledger link. No client-written counter can qualify a reward.

Document evidence has three distinct records:

- `DocumentEntitlement`: the dog's qualifying lifetime/annual/visit entitlement
  and its one ledger credit.
- `DocumentSubmission`: each immutable submission version and retry receipt.
- `EvidenceFingerprint`: per-dog evidence reuse protection. One family document
  may cover multiple dogs; one dog's file cannot support another entitlement.

Successful submission immediately credits an eligible reward and records
`SELF_REPORTED`. This means submitted, not verified or approved. Later spot audits
are not implemented. Re-uploading an existing entitlement keeps the new version
and awards zero. Stable UUID retries return the original receipt; changing the
payload under the same UUID returns 409. Owner/dog locks serialize entitlement
and ledger changes; database uniqueness is the final duplicate guard.

PDFs are bounded, parsed, unencrypted and 1–20 pages. Vet photos must decode as
JPEG/PNG. This validates file structure, not document authenticity. Files are
limited to 4 MiB decoded and remain outside public media under
`backend/private_uploads/`. Only the submitting owner or admin may download;
responses prevent caching and MIME sniffing. Back up this directory with the
database, separately from public profile photos. No production retention period
is inferred. See [evidence details](../backend/evidence/README.md).

## API

All routes require the authenticated OWNER except document downloads, which also
permit ADMIN. Both trailing-slash variants work. See [OpenAPI](openapi.yaml).

| Method | Route | Result |
|---|---|---|
| GET | `/api/quests` | Server date/reset, per-dog daily goal, streak, birthdays, capability availability |
| POST | `/api/quests/birthdays/{dog_id}/collect` | Birthday award, balance and created flag |
| GET | `/api/leaderboard?period=week\|all_time` | Explicit self-only walking statistics |
| GET | `/api/quests/documents` | Owned dogs, evidence versions and eligibility |
| POST | `/api/quests/documents` | Evidence receipt, awarded points and balance |
| GET | `/api/quests/documents/{id}/file` | Authenticated attachment download |

After an award, iOS refreshes the canonical wallet. A wallet refresh requested
during another load or purchase is queued, so a late older result does not leave
the displayed balance stale. A successful receipt remains visible if a later
history refresh fails. Account-bound stores reject responses after sign-out or
switching users.

## Venue teammate handoff

The location verification and check-in backend belong to the venue feature.
This slice deliberately has no invented HTTP endpoint or local dwell timer.
Implement `CheckInProgressServing`, then inject the provider through
`OwnerHomeView(checkInService:)` using the shared authenticated API client.

The provider's two operations are:

```swift
func fetchProgress() async throws -> [VenueCheckInProgress]
func collect(id: String, requestID: UUID) async throws -> CheckInCollectionReceipt
```

Each progress item supplies a stable `id`, venue identity/name/photo,
`requiredSeconds`, **server-verified** `verifiedSeconds`, `updatedAt`,
`rewardPoints`, and status `inProgress`, `ready`, `collected` or `cancelled`.
The receipt contains the confirmed collected item, actual awarded points and
wallet balance. The backend must enforce owner scope, eligibility, daily caps
and UUID idempotency; an unknown/invalid receipt cannot update the shared store.

`CheckInProgressStore` is shared by the map drawer and Quest. Both show the same
bar and call the same collect method. Duplicate taps are serialized, retry IDs
survive lost responses, and a confirmed collection cannot be overwritten by an
older ready response, even after an empty refresh. Foreground Walk/Quest polling
refreshes every five seconds; tab/background cancellation stops polling. The
provider may also trigger `refresh()` after its own start/progress events.

Without a provider, the UI honestly reports that check-ins are unavailable.
There is no fake progress or local award. The venue owner must align the final
API and rule contract before enabling this capability.

## Validation

Run backend tests from `backend/` (or `make test`); running Django discovery from
the repository root can find zero tests. SQLite covers models, API permissions,
period/date boundaries, idempotency and rollback. Run MySQL transaction tests as
well for concurrent collections/submissions. Test databases must be isolated
from the local demo database.

iOS tests cover response decoding, services, account changes, late responses,
duplicate collection, stable retries, wallet refresh races and document receipt
validation. SwiftUI attachments cover light/dark and accessibility layouts.
Physical-device GPS and the teammate's actual check-in service remain separate
integration acceptance work.

Verified on 25 September 2026: the full backend suite passed **201 tests** on an
isolated MySQL 8.4 instance, including birthday/document concurrency. The iOS
simulator suite passed **254 tests**, with one protected-file test requiring a
physical device skipped. Django checks and migration drift checks passed. Local
demo migrations and authenticated HTTP reads succeeded; existing account, dog,
product, ledger and order counts were preserved.
