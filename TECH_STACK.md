# Technical Architecture

One native iOS app, one Django API and one MySQL database. Keep feature delivery
small and reuse shared authentication, point and order services.
[Feature status](docs/FEATURES.md) distinguishes working flows from schema
foundations. [Quest policy](docs/QUESTS.md) owns reward rules;
[Decisions](docs/DECISIONS.md) owns unresolved behavior.

## Stack

| Layer | Current choice |
|---|---|
| iOS | Swift, SwiftUI, iOS 17+, async/await, URLSession/Codable |
| Maps and walking | MapKit, Core Location, explicit background-location lifecycle |
| Local walk storage | Protected JSON checkpoints/history scoped by account and backend |
| Credentials | Keychain and one shared credential authority |
| Backend | Python, Django, Django REST Framework, JWT |
| Database/admin | MySQL 8.4 in Compose, Django ORM/migrations and Django Admin |
| Tests | XCTest, Django tests; separate physical-device acceptance |
| Local services | Docker Compose: `api`, `db`, `expiry` |

SwiftData, a separate wallet database, a background upload worker and a generic
rules engine are not part of the current implementation. Australian hosting is
a deployment requirement; the production provider is not selected.

## Client boundaries

```text
SwiftUI feature → ViewModel / observable store → feature service
                                            → AuthenticatedAPIClient
                                            → CredentialAuthority + APIClient
                                            → Django API
```

`AppDependencies` injects the same authenticated client into feature services.
Views do not create independent token stores or refresh policies. Keychain
credentials are bound to the selected backend; a Debug URL change requires a
new login. Refresh authentication failures clear the stale session; transient
server/network failures retain credentials for retry.

Owner navigation is Account / Walk / Quest / Redeem. Café navigation is
Account / Products / Orders. The login choice is context, not permission:
registration creates OWNER, café accounts are admin-created, and the returned
role must match before entering its interface.

`OwnerHomeView` owns the active `WalkSessionCoordinator`, Quest store, shared
check-in store and wallet view model. Switching tabs preserves a walk; changing
accounts stops work and rejects late responses. Both map and Quest observe the
same check-in collection state. Production injects the authenticated check-in
service; physical-device location and background acceptance remain release work.

The design system contains semantic colors, spacing, buttons, avatars and
collection controls. Persisted System/Light/Dark selection applies to pages,
sheets and login. Use system text styles and verify large-text layouts.

## Backend domains and data

| Domain | Responsibility |
|---|---|
| `accounts` | Login, roles, owner profile and authenticated café profile endpoints |
| `dogs` | Owner-scoped dog profiles, nullable birthdays, breed reference data, personalised owner/manual Admin goal targets and frozen results |
| `venues` | Canonical venue identity/details/photo and optional managing café account |
| `walks` | Validated walk uploads, participation/history snapshots; live-session, sample and net-walk schema foundations |
| `rewards` | Canonical PointEntry ledger, Reward products, Redemption orders, café feed and expiry/refunds |
| `quests` | Typed task projection, daily-goal calendars, reward catalogue and birthday/streak qualification/collection |
| `evidence` | Per-dog document entitlements, immutable submissions and private files |
| `checkins` | Authenticated venue discovery, GPS dwell verification, collection and shared daily-cap service |
| `social` | Friendship and directional-block schema foundations |

The core foundation contains 23 business tables, including the explicit
Walk–Dog relation and effective-dated `DogGoalTarget`. It does not include Django's built-in auth/admin/session
tables. [Database design](docs/database-design-2026-09-25/README.md) describes
fields and constraints; model migrations are the physical schema authority.
The six later tables for external identity, chat, charity/donation and push
registration/delivery are not created by this foundation.

Venue replaces duplicated café-profile storage. `Reward.venue` is the canonical
product location; legacy café-user identity remains on existing wire contracts
and historical order snapshots. Venue photos are distinct from login-account
avatars. Non-café places can exist without a login account. This normalization
does not itself implement map behavior; the `checkins` domain supplies the
authenticated venue map, explicit start/location/cancel and collection routes.

Keep one PointEntry model for both credit lots and ledger changes. Wallet
balance is the sum of unexpired remaining credits, not a second mutable total.
Spend soonest-expiring credits first, with deterministic creation/ID ordering.
An order remains one reward, quantity one; no cart or order-item subsystem is
needed. Redemption snapshots preserve names, prices, venue/café identity and
applicable terms after catalogue edits.

Daily-goal rows preserve per-dog inputs/results. Owner recommendations and Admin
targets share one append-only effective-dated history, and Quest displays the
seven-day calendar. Session/sample/net-interval and friendship rows preserve
data needed by later features. Their existence does not enable daily-goal
payouts, a location matcher, social API or leaderboard. Do not start storing raw GPS through the current walk-upload endpoint
just because a LocationSample table exists.

## Transactions and retry safety

- Earn/spend/refund operations use the shared ledger service and owner lock.
  Related qualification/order changes and credits/debits commit together.
- Walk and purchase UUIDs identify one immutable request. Replays return the
  prior result; changing the payload under the same ID conflicts.
- Birthday collection and document entitlement collection each link one
  canonical credit. Concurrent or repeated requests cannot credit twice.
- Check-in collection accepts persisted server-verified qualification, not
  client-reported elapsed time. Walking, daily-goal settlement and check-in
  services share the daily activity cap; daily-goal payouts and partial check-in
  rewards remain disabled pending policy.
- Order creation deducts; collection changes status only. Expiry and admin
  cancellation refund pending orders once. Terminal orders are not reopened.
- `expire_rewards --watch --interval 60` runs in Compose. It expires due credit
  lots and refunds overdue pending orders; `make expire` runs one sweep.

A successful action remains successful if its follow-up refresh fails. iOS
retains confirmed receipts/collection state and queues wallet refreshes rather
than inviting another purchase or award. Account shutdown clears local view
state and ignores responses belonging to the previous session.

## Walk persistence and GPS

The active route is WalkMapView → WalkSessionCoordinator → tracker/location,
history, draft and sync stores. The obsolete WalkView/WalkRecorder stack has
been removed. Full behavior and limits are in
[Walk integration](docs/WALK_INTEGRATION.md).

Finish persists an unconfirmed summary before choosing dogs. Only explicit
confirmation with dogs produces an uploadable record; no-dog completion stays
local. Stable IDs, protected files and receipt reconciliation preserve work
through failure. Relaunch restores an active checkpoint as Paused, never as
uninterrupted tracking. A force-quit cannot record missing movement.

The current HTTP walk endpoint validates measured coordinates, accuracy,
timestamps, segment boundaries and location-source flags, then stores the
accepted summary. It does not populate the new live-location foundation.
Server receipts are authoritative; local distance/points remain estimates.
Foreground retry retains the server submission deadline. There is no general
offline login or autonomous background upload service.

## API, permissions and files

[OpenAPI](docs/openapi.yaml) is the route/schema reference. Do not copy a future
endpoint list into the client. `/api/quests` returns the compact task envelope
and daily-goal calendars; `/api/dogs/{id}/goal` previews and saves the dog's
effective-dated personalised target. Old dashboard projections are removed.

Backend queries derive ownership from the authenticated account. OWNER, CAFE
and ADMIN capabilities are distinct; hiding a control is not authorization.
Café orders are read-only and scoped to the café snapshotted on the order.
The feed supports cursor deltas; current profile-aware clients request fresh
pending-order snapshots so names/photos update. Polling stops when inactive.

Public avatar/venue media and private evidence use separate storage paths.
Document originals require owner/admin authorization and preserve submission
versions. See [media](backend/MEDIA.md) and [evidence](backend/evidence/README.md)
for limits and backup requirements. Data retention, account erasure,
consent/visibility and later audit workflows remain product/release work;
private storage alone does not complete them.

## Development and review

[README](README.md) contains startup, device configuration and connected-flow
checks. Local environment overrides are listed in `backend/.env.example`;
iPhone signing/API settings belong in ignored `ios/Config/Local.xcconfig`.
Use separate databases/secrets for local, staging and eventual production.

For a schema change, commit the model, forward migration, meaningful tests and
contract/docs together. Preserve existing IDs, ledger history and retry
receipts; never reset a teammate's database to resolve a merge. SQLite tests
cover logic; disposable MySQL tests verify row locking and concurrency.

A change is ready for acceptance when it builds, its happy path and important
failure/permission cases pass, migrations preserve existing data, and API/docs
match. Physical-device checks remain necessary for GPS, background execution,
photos and protected storage. Test counts belong to the actual validation run,
not an undated claim of permanent coverage.

Future work includes physical-device venue/GPS acceptance, approved multi-dog goal earning,
net-walk earning, friends/leaderboards, OAuth, password reset/account
deletion, notifications, sharing, chat and charity. Schema preparation must not
be presented as completed functionality. See [open decisions](docs/DECISIONS.md).
