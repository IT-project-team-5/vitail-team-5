# Tech Stack and Architecture

This document defines the technical architecture for the Vitail pilot.

The goal is to keep the system simple enough for a four-engineer junior team
while using production-style foundations: one native iOS app, one backend, one
relational database, clear API contracts, and vertical use-case ownership.

Product rules live in `README.md`. Open questions live in `docs/DECISIONS.md`.

---

## 1. Final Stack

| Layer | Technology |
|---|---|
| Platform | Native iOS 17+ |
| iOS language | Swift |
| iOS UI | SwiftUI |
| iOS architecture | MVVM-style separation |
| Local persistence | SwiftData |
| API client | URLSession + Codable |
| Concurrency | Swift async/await |
| Dependency management | Swift Package Manager |
| Unit and integration tests | Swift Testing |
| UI tests | XCTest / XCUITest |
| Walk tracking | Core Location with background location mode |
| Check-in location | User-initiated Core Location session |
| Maps | MapKit |
| Basic anti-spoofing | Location-source checks |
| Secure token storage | Keychain |
| Backend language | Python |
| Backend framework | Django |
| API framework | Django REST Framework |
| Database | MySQL |
| Internal admin | Django Admin |
| API contract | OpenAPI |
| Local development | Docker Compose |
| Hosting region | Australian (Sydney or Melbourne) |
| Version control | Git |
| Beta and release | TestFlight + App Store |

---

## 2. Why This Architecture

### One app, two end-user roles

Owners and café staff use the same native iOS app. The backend role decides which
interface loads.

```text
Dog owner    → iOS app, Account / Walk / Redeem shell
Café staff   → iOS app, Account / Orders shell
Vitail admin → Django Admin
```

Cafés do not self-register, do not scan codes and do not edit their own offers
at pilot. Their accounts are created by an admin. Owners self-register with
email and password.

Putting the café screen inside the app provides real authentication instead of
a secret URL and lets the team reuse the same client foundation. During the
MVP, café staff leave the order screen open and it polls for changes.

The backend must still enforce that an account only acts on its own data.
UI visibility is not security.

### Swift + SwiftUI

The product depends heavily on iOS-native capability:

- continuous Core Location updates during a manually started walk;
- user-initiated location verification and dwell tracking at venues;
- background location lifecycle while an activity is in progress;
- local buffering while the network drops;
- basic location-source checks;
- camera access for optional photo check-ins.

SwiftUI keeps the client native while avoiding a second UI framework. The pilot
targets iOS 17 or later so SwiftData can provide the short-lived local route
buffer without adding a third-party database.

### Django REST Framework

Django provides models, ORM, migrations, authentication, permissions,
transactions and an admin interface out of the box. The admin interface is not
a convenience here — it **is** the merchant and support tool for pilot.

### MySQL

Relational data with strict transactional requirements: point deduction,
order collection and expiry must never double-apply. Migrations keep every
developer's schema identical.

CSV is used for seed data, fixtures and exports only. It is never the runtime
database.

### Australian hosting

Vitail intends to partner with insurers and councils, and the product collects
continuous location data plus registration documents. Personal data is hosted in
an Australian region from day one, because moving it later is far harder than
starting there.

Note that map tile and related requests may be processed by Apple infrastructure
regardless of where Vitail's own data sits. This is documented rather than
solved at pilot.

---

## 3. High-Level Architecture

```text
                    iOS APP (owner / café staff)
                                │
        ┌───────────┬───────────┼───────────┬────────────┐
        │           │           │           │            │
       Dog        Walk       Venues      Wallet      Redemption
      profile   tracking   + check-ins   + history     orders
        │           │           │           │            │
        └───────────┴───────────┴───────────┴────────────┘
                                │
                          HTTPS / JSON
                                │
                                ▼
                        DJANGO REST API
                                │
   ┌──────────┬──────────┬──────┼───────┬──────────┬────────────┐
   │          │          │      │       │          │            │
 accounts    dogs      venues  walks  wallets  redemptions   rewards
   │          │          │      │       │          │            │
   └──────────┴──────────┴──────┴───────┴──────────┴────────────┘
                                │
                                ▼
                        MySQL (AU region)
                                │
                                ▼
                     Django Admin (Vitail staff)
```

---

## 4. Repository Structure

Use a feature-first layout. Create a feature directory only when work on that
feature begins.

```text
vitail-team-5/
├── ios/
│   └── Vitail/
│       ├── App/
│       ├── Core/
│       │   ├── API/
│       │   ├── Auth/
│       │   └── DesignSystem/
│       └── Features/
│           ├── Auth/
│           ├── OwnerHome/
│           └── CafeOrders/
├── backend/
│   ├── config/
│   ├── accounts/
│   ├── venues/
│   └── redemptions/
├── docs/
│   ├── DECISIONS.md
│   ├── openapi.yaml
│   └── FEATURES.md
├── docker-compose.yml
├── Makefile
├── README.md
└── TECH_STACK.md
```

| Source | Authority |
|---|---|
| `README.md` | Product overview and locked rules |
| `TECH_STACK.md` | Technical architecture and conventions |
| `docs/DECISIONS.md` | Resolved decisions and open questions |
| `docs/FEATURES.md` | Lightweight feature status and MVP acceptance |
| OpenAPI | API request/response contract |
| Django models + migrations | Physical database |

---

## 5. Backend Domain Split

```text
accounts      email authentication, roles, owner profile
dogs          dog profile, breed reference data, personalised goal
venues        partner venues, proximity checks, check-ins, offers
walks         walk sessions, route samples, validation
wallets       point lots, ledger, balance, expiry, streaks, caps
redemptions   orders, collection, charity donations, history
rewards       vet checkup and council registration verification
```

Separate Django apps reduce migration conflicts and make ownership clear.

---

## 6. Core Data Model

### Account

```text
id
email                  unique login identifier
password               Django-managed encoded value
role                   OWNER | CAFE | ADMIN
display_name
profile_photo
is_active
created_at
```

Passwords are hashed by Django authentication. Plaintext is never stored. Apple
identity fields are added later, when the project has its own Apple Developer
Program account and Sign in with Apple is implemented.

### Dog

```text
id
owner_id
name
photo
breed_id
age_months
size                   SMALL | MEDIUM | LARGE
is_brachycephalic
created_at
```

### Breed (reference data)

```text
id
name
energy_level           LOW | MODERATE | HIGH
default_size
is_brachycephalic
```

Seeded reference table. `Dog.is_brachycephalic` defaults from the breed but can
be overridden for mixed breeds.

### Walk

```text
id
owner_id
started_at
ended_at
end_reason             MANUAL | AUTO_TIMEOUT | LOGOUT
status
raw_distance_m
valid_distance_m
valid_duration_s
awarded_points
created_at
```

### WalkPoint

```text
id
walk_id
latitude
longitude
recorded_at
accuracy_m
sequence_number
is_discarded           accuracy > 30 m, or failed speed check
```

Store only the minimum needed for route display and validation.

### WalkDog

```text
walk_id
dog_id
```

Which of the owner's dogs took part in a walk. An account may hold several dogs
and a single walk may include more than one of them.

Dog count never multiplies points. This table exists so each dog's own daily
goal can be evaluated, and so history shows who actually went.

### Venue

```text
id
name
venue_type             VET | DOG_PARK | CAFE | RESTAURANT | OTHER
description
address
latitude
longitude
checkin_radius_m
required_dwell_s
opening_hours
photo
is_active
account_id             the CAFE account that signs in for this venue
order_feed_cursor      internal per-venue polling sequence
created_at
```

Created and edited by Vitail admins only. `account_id` is null for venues with
no staff login, such as dog parks.

### VenueOffer

```text
id
venue_id
name
description
photo
point_price
is_available
created_at
```

An offer cannot move to another venue after it has appeared in a redemption
order; the order-item snapshots and venue boundary must remain consistent.

### CheckIn

```text
id
owner_id
venue_id
entered_at
dwell_completed_at
status                 IN_PROGRESS | COMPLETED | ABANDONED
awarded_points
completed_local_date   nullable; populated only on COMPLETED
```

Unique on `(owner_id, venue_id, completed_local_date)`. MySQL permits several
null values, so abandoned and in-progress retries do not collide, while only
one completed check-in can exist for a venue and local date.

### PointLot

```text
id
owner_id
source                 WALK | GOAL | CHECKIN | VET | COUNCIL | STREAK | REFUND
amount_earned
amount_remaining
earned_at
expires_at             earned_at + 12 months
```

Points expire 12 months after they are earned, so the wallet cannot be a single
integer. Balance is the sum of `amount_remaining` across unexpired lots, and
spending consumes lots **oldest-first (FIFO)** so points closest to expiry are
used first.

### PointLedger

```text
id
owner_id
amount                 signed
type
walk_id
checkin_id
redemption_id
lot_id
reason
created_at
```

> Never change a balance without writing the corresponding ledger entry.

### DailyPointTally

```text
owner_id
local_date
walk_points
goal_points
checkin_points
capped_total           never exceeds 72
```

Makes the daily cap cheap to enforce and cheap to audit.

### VerifiedReward

```text
id
owner_id
type                   VET_CHECKUP | COUNCIL_REGISTRATION
evidence_file
status                 PENDING | APPROVED | REJECTED
reviewed_by
reviewed_at
awarded_points
created_at
```

Reviewed by a Vitail admin. See `docs/DECISIONS.md` — the confirmation method
for vet checkups is still open.

### RedemptionOrder

```text
id
owner_id
venue_id
reference_number       shown to owner and merchant
owner_name_snapshot    customer name when the order was placed
status                 PENDING | COLLECTED | EXPIRED | CANCELLED
total_points
created_at
updated_at
collected_at
expires_at             end of the day it was created
```

### RedemptionOrderItem

```text
id
order_id
venue_offer_id
item_name_snapshot
point_price_snapshot
quantity
```

Customer names, item names and prices are snapshotted so order history and the
café feed stay correct after an account or venue edits its details.

### CafeOrderEvent

```text
id
venue_id
cursor                 monotonically increasing within one venue
order_id
kind                   UPSERT | REMOVE
created_at
```

The short-lived event log powers incremental café polling. Cursor assignment
and the order change commit in the same transaction. Old event rows are bounded;
a client behind the retained range receives a full reset snapshot.

### CharityDonation

```text
id
owner_id
charity_id
reference_number
points
created_at
```

---

## 7. iOS Architecture

```text
UI / SwiftUI screens
        ↓
ViewModel
        ↓
Service
   ↙       ↘
Keychain  URLSession → Django API
```

The UI never calls URLSession, Keychain or SwiftData directly. Do not add a
repository interface, use-case layer or dependency framework until a real need
appears. Extract shared code after it is used by more than one feature.

Feature folders:

```text
auth
dog
walk
venues
wallet
redemption
shared
```

Shared concerns, implemented once:

```text
API client configuration
Keychain auth token storage
error mapping
navigation
loading and empty states
image loading
SwiftData container
location permission handling
```

### Small design system

Keep styling central without building a UI framework. Start with only:

```text
AppColors, AppSpacing, AppRadius
PrimaryButton, AppTextField
LoadingView, ErrorView
```

Use system fonts, SF Symbols and semantic colours. Add a shared component only
when a feature needs it.

### On offline behaviour

A multi-walk offline queue and long-lived background sync are **out of scope**.
GPS recording itself does not need the network, so:

- route samples are buffered in SwiftData **during** the walk;
- the walk uploads when the owner ends it;
- upload failure retries with backoff while the app is open;
- there is no queue of several completed offline walks.

---

## 8. Walk Tracking

```text
Owner selects which dogs are coming
→ selects Start
→ app requests When In Use location permission if needed
→ app requests temporary Precise Location if reduced accuracy is active
→ app waits for an accurate GPS lock
→ Core Location tracking starts with background delivery enabled
→ route renders on the map
→ samples are buffered in SwiftData
→ Owner selects End
```

The Core Location session begins only after the owner taps Start. Background
location delivery remains enabled only while the walk is active, so tracking
continues if the owner locks the phone or switches apps. It stops immediately
when the walk ends or the owner logs out. The phone never decides the
authoritative reward — the backend does.

Precise Location is required because reduced-accuracy coordinates cannot satisfy
the 30 m accuracy floor. If permission is denied, the app explains the
requirement and does not start the walk.

### Auto-end

A walk ends automatically after **5 minutes of inactivity**, or when the owner
logs out. Auto-ended walks are still validated and still earn points for the
valid portion.

### Pause forgiveness

Stationary periods **under 5 minutes** are forgiven and do not end the walk.
Dogs stop to sniff; that is normal walking behaviour, not inactivity.

### Sample validation

Discard a sample when:

```text
accuracy worse than 30 m
timestamps out of order
implied speed above walking range (driving or cycling)
impossible location jump
```

Signal loss underground simply produces no samples, and those minutes do not
count.

### Walk state machine

```text
RECORDING
    ↓
UPLOADING
    ↓
VALIDATING
   ↙       ↘
ACCEPTED   REJECTED
```

---

## 9. Personalised Daily Goal

The goal is a **recommended walk duration**, derived per dog:

```text
breed energy level
age
size
brachycephalic flag
       ↓
base recommended duration
       ↓
welfare guardrails
  - lower target for brachycephalic breeds
  - lower target for senior dogs
  - reduced target in Australian summer heat
       ↓
personalised daily goal
```

Each dog has its own goal. The 20-point award is granted once per day per
**account**, not per dog — dog count never multiplies points.

With several dogs on an account, the award is granted when **every dog that took
part in that day's walks** has met its own goal. A dog left at home that day does
not block the award.

The goal is expressed in minutes while walk points are earned per kilometre.
This mismatch is intentional but must be presented clearly in the UI, and the
open question is recorded in `docs/DECISIONS.md`.

Heat adjustment requires a weather source. Provider is not yet chosen.

---

## 10. Venue Check-ins

Venues are registered with a coordinate, a check-in radius and a required dwell
time.

```text
Owner opens a venue and taps Start check-in
→ app confirms the owner is inside the venue radius
→ backend creates CheckIn as IN_PROGRESS
→ active Core Location session sends location reports
→ dwell satisfied → COMPLETED → 12 points
→ owner leaves early → ABANDONED, no penalty
→ owner may return the same day and try again
```

The pilot does not start check-ins automatically on region entry and does not
monitor every venue in the background. Location access is requested in context,
when the owner starts a check-in. This avoids passive location monitoring and
the platform limit on simultaneously monitored regions.

Dwell requirements:

```text
vet          3 minutes
dog park     5 minutes
café        10 minutes
restaurant  20 minutes
```

Dwell completion is confirmed by the **backend** from repeated location reports
and server receipt times. The client must not self-report a completed check-in.
Precise Location is required; if the active session ends before the required
dwell is verified, progress is lost and the owner can retry.

After the explicit Start check-in action, background location delivery may
continue while the owner locks the phone or switches apps. It stops when the
check-in completes, is abandoned, the owner logs out, or the app is terminated.

---

## 11. Points Engine

Earning rules are listed in `README.md`. Implementation requirements:

- walking is 8 points per km, counted up to 5 km per day;
- all point values **round down**;
- the daily cap of 72 applies to walking + goal + check-ins only;
- vet checkups, council registration and streak bonuses are outside the cap;
- the cap is applied as a **running total in chronological order**, so an
  earlier event is never retroactively revoked by a later one;
- the day boundary is the owner's **local date**.

Every award writes both a `PointLot` and a `PointLedger` entry, inside one
transaction.

### Streaks

A streak day is a day with at least one accepted walk. Bonuses are one-time:
7 days awards 20 points, 30 days awards 100.

### Expiry

A scheduled job expires lots past `expires_at`, zeroes their remaining amount
and writes a negative ledger entry. Expiry must be idempotent — running it twice
must not double-deduct.

---

## 12. Redemption

### Partner offer

```text
Owner selects venue and items
→ backend reads current prices and computes the total
→ backend checks available balance
→ order created as PENDING
→ points deducted immediately, FIFO across lots
→ reference number issued
→ the order appears on the café order screen on its next refresh
→ owner travels to the venue
→ owner taps Redeem
→ order marked COLLECTED
```

Deduction happens at **order creation**, not at collection. Two consequences
that must be implemented:

- an order not collected by end of day moves to `EXPIRED` and the points are
  **refunded automatically** as a new lot, with a ledger entry;
- an admin can cancel and refund an order manually, for example when a venue has
  run out of stock.

At MVP the Redeem button is always tappable and collection has no location
gate. An owner can therefore mark an order collected away from the venue. This
is a known and accepted gap. Build the collection endpoint so a location policy
can be added later without reshaping the order state machine.

### Café order screen

Café staff sign in to the same iOS app with a `CAFE` account and leave the order
screen open during trading hours.

```text
GET  /api/cafe/orders?since={cursor}       polled by the café screen
```

The screen polls every five seconds and lists orders still `PENDING` for that
café, showing the reference number, the owner's name, the items and the time
ordered. When the owner taps Redeem the order becomes `COLLECTED` and drops off
the list on the next poll.

Implementation requirements:

- the feed is scoped to the venue attached to the signed-in `CAFE` account, and
  must never return another café's orders;
- it accepts a `since` cursor and returns only what changed;
- respond `304 Not Modified` when nothing changed, so idle polling is nearly
  free;
- if retained history no longer covers the cursor, return a full snapshot with
  `reset: true` so the app can repair its cache;
- a five second interval is ample at pilot volume;
- polling runs only while the Orders page is visible and the app is active;
- the screen is a **display surface only**. There is no endpoint a café can call
  to mutate an order — collection is driven by the owner's app, never by the
  café.

### Order state machine

```text
PENDING
 ├── COLLECTED
 ├── EXPIRED    (auto, end of day, refunded)
 └── CANCELLED  (admin, refunded)
```

### Atomicity

Deduction and collection each run in a single database transaction:

```text
BEGIN
lock the order row
check the current status
check expiry
apply the state change
write ledger entries
COMMIT
```

If any step fails, `ROLLBACK`. A repeated request must return the existing
state, never apply the change twice.

### Charity donation

Points are deducted the same way and a reference number is issued. There is no
venue, no location verification and no collection step.

---

## 13. API Structure

```text
/api/auth/
/api/dogs/
/api/walks/
/api/venues/
/api/checkins/
/api/wallet/
/api/redemptions/
/api/rewards/
```

Indicative endpoints:

```text
POST   /api/auth/register
POST   /api/auth/login
POST   /api/auth/refresh
GET    /api/auth/me

GET    /api/dogs
POST   /api/dogs
PATCH  /api/dogs/{id}
GET    /api/dogs/{id}/goal

POST   /api/walks
GET    /api/walks/{id}

GET    /api/venues
GET    /api/venues/{id}
GET    /api/venues/{id}/offers

POST   /api/checkins
POST   /api/checkins/{id}/heartbeat

GET    /api/wallet
GET    /api/wallet/ledger

POST   /api/redemptions/orders
POST   /api/redemptions/orders/{id}/collect
GET    /api/redemptions/orders
POST   /api/redemptions/donations

GET    /api/cafe/orders              café order feed, CAFE role, polled

POST   /api/rewards/vet-checkup
POST   /api/rewards/council-registration
```

Exact routes are ultimately defined by OpenAPI, not copied between developers.
Sign in with Apple, password reset and account deletion endpoints are added in
their later use cases.

---

## 14. API Rules

The backend is authoritative for:

```text
walk validity and distance
awarded points
daily cap
streaks
wallet balance and expiry
check-in dwell completion
offer price and order total
order state
refunds
```

iOS may compute temporary display values, but the server never trusts them.

Authentication currently uses DRF's standard `detail` and field-validation
messages to keep the first slice small. Business endpoints converge on this
shared error shape as they are added:

```json
{
  "code": "INSUFFICIENT_POINTS",
  "message": "Not enough points to complete this redemption."
}
```

---

## 15. Authentication and Permissions

Django authentication uses JWT access and refresh tokens. Owners self-register
with email and password; registration always creates an `OWNER` and never
accepts a client-selected role. Café accounts are created in Django Admin and
use the same login endpoint. The login response includes the account role, so
the same iOS app routes to the owner or café interface.

The login UI first asks the user to choose the `I'm a dog owner` or
`I'm a cafe owner` option. This is the intended login context only: it never
sets or changes the account role. Registration remains available only to dog
owners. The backend-returned role must match the chosen context before the app
stores the session and routes to its shell.

Both tokens are stored in iOS Keychain, never in SwiftData or UserDefaults. On
logout, the app removes them. Backend permissions remain authoritative; hiding
a screen is not access control.

Sign in with Apple is deferred until the project has its own Apple Developer
Program account. Password reset and in-app account deletion are separate later
use cases. Google login is not included.

```text
OWNER
- manage own dog
- create own walks and check-ins
- view venues and offers
- create own orders and donations
- view own wallet and history

CAFE
- view orders for own venue only
- nothing else: cannot edit offers, cannot collect an order

ADMIN
- Django Admin
- onboard and edit venues and offers
- review vet and council evidence
- cancel and refund orders
- investigate suspected farming
```

Never trust an owner ID sent by the app when the authenticated identity already
determines ownership.

Bad:

```text
POST /walks
owner_id = 123
```

Better:

```text
POST /walks
owner is taken from the authenticated request
```

---

## 16. Anti-Abuse

Pilot runs mostly on trust. The controls exist to discourage farming, not to
police users:

```text
walking-speed sanity checks
30 m GPS accuracy floor
simulated-location checks (`CLLocation.sourceInformation`)
server-confirmed venue proximity and dwell
one check-in per venue per day
daily point cap
```

Advanced fake-GPS detection is out of scope. Disputes are handled by email at
pilot.

---

## 17. Privacy and Data Handling

The product collects continuous location, dog health attributes and — for
council registration — identity documents. That is the most sensitive data in
the system.

Requirements:

- personal data hosted in an Australian region;
- request location access only when the owner starts a walk, check-in or nearby
  venue search, with purpose strings that explain each use;
- enable background location delivery only during an active walk or check-in;
- disclose collected and linked data accurately in App Store Connect;
- a defined retention period for raw GPS route samples (still open);
- registration evidence stored with restricted access and deleted after review
  where possible;
- when the later account-deletion use case is built, it must remove or
  irreversibly anonymise personal data;
- the owner's name is displayed on the café order screen, which must be stated
  in the privacy notice.

---

## 18. Notifications

Remote push notifications are deferred to keep the MVP small. The café order
screen polls every five seconds while open. Owner reminders and transactional
push can be added later without changing the core API.

---

## 19. MySQL and Migration Policy

```text
edit the Django model
→ generate the migration
→ review the migration
→ run it
→ commit model and migration together
```

Every schema-changing pull request contains the model change, the migration,
tests and a documentation update.

Early development may reset and reseed the development database. Once pilot data
exists, use forward migrations and back up before risky changes.

---

## 20. Development Environment

Docker Compose services:

```text
api
db
```

Compose environment overrides:

```text
DJANGO_SECRET_KEY
DJANGO_DEBUG
DJANGO_ALLOWED_HOSTS
DJANGO_TIME_ZONE
MYSQL_DATABASE
MYSQL_USER
MYSQL_PASSWORD
MYSQL_ROOT_PASSWORD
JWT_ACCESS_MINUTES
JWT_REFRESH_DAYS
```

iOS local configuration:

```text
API_BASE_URL
DEVELOPMENT_TEAM
PRODUCT_BUNDLE_IDENTIFIER
```

Never commit secrets. Never commit a real API key.

For local iPhone testing, each developer uses their own free Personal Team and
a local bundle identifier. Signing details and the Mac's LAN API address belong
in an uncommitted local configuration file. No shared or personal paid Apple
Developer account is part of the project.

Keep environment management to three levels: local Docker Compose now, one
shared staging environment when remote team testing starts, and production for
release. Each environment has a separate database and secrets.

### App Store delivery

The iOS target requires a stable bundle identifier and the following signing
capabilities as their features are implemented:

```text
Sign in with Apple (after the project has its own Developer Program account)
Background Modes → Location updates
```

Every release candidate is distributed through TestFlight before App Store
submission. Submission requires complete App Privacy answers, a public privacy
policy and support URL, in-app account deletion, and review credentials for
both `OWNER` and `CAFE` interfaces. Location purpose strings must describe
manual walk tracking and user-initiated venue check-ins plainly.

---

## 21. Four-Engineer Split

### Engineer 1 — Accounts and Dog

```text
owner email registration and login, café login, role routing
Sign in with Apple, password reset and account deletion in later use cases
owner profile
dog profiles, several per account, and breed reference data
personalised goal calculation
heat adjustment
```

### Engineer 2 — Venues and Check-ins

```text
venue and offer admin models
discovery list and MapKit map
user-initiated Start check-in flow and proximity verification
dwell tracking and confirmation
check-in awards and daily uniqueness
```

### Engineer 3 — Walks and Wallet

```text
Core Location walk tracking and background lifecycle
route UI and SwiftData buffering
walk upload and validation
points engine, caps, rounding
point lots, ledger, FIFO spend, expiry job
streaks
```

### Engineer 4 — Redemption and Rewards

```text
order creation and deduction
café login, café order screen and its polling feed
collection endpoint with no MVP location gate, built for a later policy check
expiry and refund job
charity donations
redemption history
vet and council evidence submission and admin review
```

Each engineer owns the iOS UI, the API, the migration, the tests and the
docs for their area. Do not create permanent frontend/backend silos.

---

## 22. Shared-Code Rule

Before creating a new helper, convention, response type or auth method, check
whether one already exists. Shared concerns get one implementation:

```text
Keychain auth token handling
URLSession API client
API errors
small design-system tokens and controls
SwiftData container
Django permission classes
point transaction logic
Core Location session handling
reference number generation
```

---

## 23. Definition of Done

A use case is complete when:

- the iOS UI works on a physical supported iPhone;
- its real backend API and any migration work from a blank database;
- the happy path and important failure states work;
- secrets are not committed;
- focused tests cover important business or permission rules;
- OpenAPI and relevant docs are updated.

Review is lightweight: confirm the build, the use-case flow, key errors and
security basics. Do not require coverage targets, speculative abstractions or a
large review process for the MVP.

First authentication-slice acceptance flow:

```text
User explicitly chooses dog owner or café owner on the login page
Owner registers with email/password → receives OWNER role → owner tab shell
Café account is created in Django Admin → logs in → café tab shell
Owner shell: swipe or tap between Account / Walk / Redeem; fixed `0 pts`
Café shell: tap between Account / Orders
Logout is available from Account for both roles
App relaunch refreshes the session from Keychain
Logout removes the local session
```

Walk and owner-side Redeem remain navigation placeholders. The café Orders page
is implemented as a separate slice using the authenticated polling feed
documented in `docs/openapi.yaml`; real point balances and owner-side redemption
are not implemented yet.

Main acceptance flow:

```text
Owner registers with email and password
→ adds one or more dogs
→ sees a personalised daily goal per dog
→ starts a walk
→ sees the route
→ ends the walk
→ points are awarded within the cap
→ walks to a partner venue
→ taps Start check-in
→ dwells and completes a check-in
→ orders an offer
→ points are deducted once
→ taps Redeem
→ order is marked collected
→ the redemption appears in history with a reference number
```

Critical failure tests:

```text
duplicate walk upload
driving instead of walking
GPS accuracy below threshold
simulated location
location permission denied or reduced accuracy
second check-in at the same venue the same day
daily cap boundary
walk with several dogs earns the same as a walk with one
insufficient balance
duplicate collection request
uncollected order expiry and refund
point expiry at 12 months
```

---

## 24. Out of Scope

```text
Android
merchant self-registration and self-service offer editing
location-gated order collection (planned after MVP)
multi-walk offline queues and long-lived background sync
remote push notifications
App Attest and advanced device integrity
in-app payments
reviews and ratings
wearable integration
net-walking
friends and leaderboards
advanced GPS fraud detection
automatic merchant reimbursement settlement
```

---

## 25. TBD

Recorded in `docs/DECISIONS.md`. Developers and AI assistants must not silently
invent behaviour for an open decision.

```text
vet checkup confirmation method
raw GPS route retention period
weather provider for heat adjustment
charity partners
minimum walk length
whether the daily goal is measured in minutes or kilometres
deployment provider within the AU region
```
