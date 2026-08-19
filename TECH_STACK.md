# Tech Stack and Architecture

This document defines the technical architecture for the Vitail pilot.

The goal is to keep the system simple enough for a four-engineer junior team
while using production-style foundations: one Android app, one backend, one
relational database, clear API contracts, and vertical use-case ownership.

Product rules live in `README.md`. Open questions live in `docs/DECISIONS.md`.

---

## 1. Final Stack

| Layer | Technology |
|---|---|
| Android language | Kotlin |
| Android UI | Jetpack Compose |
| Android architecture | MVVM-style separation |
| Local persistence | Room |
| API client | Retrofit + OkHttp |
| Walk tracking | Android Foreground Service |
| Location | Fused Location Provider |
| Geofencing | Android Geofencing API (Play Services) |
| Maps | Google Maps SDK for Android |
| Integrity / anti-spoofing | Play Integrity + mock-location detection |
| Push | Firebase Cloud Messaging |
| Backend language | Python |
| Backend framework | Django |
| API framework | Django REST Framework |
| Database | MySQL |
| Internal admin | Django Admin |
| API contract | OpenAPI |
| Local development | Docker Compose |
| Hosting region | Australian (Sydney or Melbourne) |
| Version control | Git |

---

## 2. Why This Architecture

### One app, two end-user roles

Owners and café staff use the same Android app. The backend role decides which
interface loads.

```text
Dog owner    → Android app, owner UI
Café staff   → Android app, café order screen
Vitail admin → Django Admin
```

Cafés do not self-register, do not scan codes and do not edit their own offers
at pilot. Accounts are created by an admin.

Putting the café screen inside the app rather than on a token-protected web page
buys two things: real authentication instead of a secret URL, and push delivery.
A café with the screen closed still receives an FCM notification when an order
arrives, which a left-open browser tab cannot do.

The backend must still enforce that an account only acts on its own data.
UI visibility is not security.

### Kotlin + Jetpack Compose

The product depends heavily on Android-native capability:

- foreground location during walks;
- geofence transitions with dwell;
- background service lifecycle;
- local buffering while the network drops;
- notifications;
- camera (optional photo check-ins).

Compose keeps new UI development simpler than maintaining XML layouts.

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

Note that Google Maps tile and geocoding requests leave for Google
infrastructure regardless of where our data sits. This is documented rather than
solved at pilot.

---

## 3. High-Level Architecture

```text
                   ANDROID APP (owner / café staff)
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

Target layout. Only the documents exist today.

```text
vitail-team-5/
├── android/
│   └── app/
├── backend/
│   ├── accounts/
│   ├── dogs/
│   ├── venues/
│   ├── walks/
│   ├── wallets/
│   ├── redemptions/
│   └── rewards/
├── docs/
│   └── DECISIONS.md
├── docker-compose.yml
├── README.md
└── TECH_STACK.md
```

| Source | Authority |
|---|---|
| `README.md` | Product overview and locked rules |
| `TECH_STACK.md` | Technical architecture and conventions |
| `docs/DECISIONS.md` | Resolved decisions and open questions |
| OpenAPI | API request/response contract |
| Django models + migrations | Physical database |

---

## 5. Backend Domain Split

```text
accounts      authentication, social login, owner profile
dogs          dog profile, breed reference data, personalised goal
venues        partner venues, geofences, check-ins, offers
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
email
password_hash
auth_provider          GOOGLE | EMAIL
role                   OWNER | CAFE | ADMIN
display_name
profile_photo
is_active
created_at
```

Passwords are hashed by Django authentication. Plaintext is never stored.

Social login is Google at pilot. Apple sign-in is deferred with iOS.

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
geofence_radius_m
required_dwell_s
opening_hours
photo
is_active
account_id             the CAFE account that signs in for this venue
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

### CheckIn

```text
id
owner_id
venue_id
entered_at
dwell_completed_at
status                 IN_PROGRESS | COMPLETED | ABANDONED
awarded_points
local_date
```

Unique on `(owner_id, venue_id, local_date)` for completed check-ins — one
check-in per venue per day.

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
status                 PENDING | COLLECTED | EXPIRED | CANCELLED
total_points
created_at
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

Names and prices are snapshotted so history stays correct after a venue edits
its catalogue.

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

## 7. Android Architecture

```text
UI / Compose screens
        ↓
ViewModel
        ↓
Repository
   ↙          ↘
Room       Retrofit
             ↓
         Django API
```

The UI never calls Retrofit or Room directly.

Feature packages:

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
auth token storage
error mapping
navigation
loading and empty states
image loading
Room database
location permission handling
```

### On offline behaviour

Full offline tracking and queued sync are **out of scope**. However, GPS
recording does not need the network, and a phone can lose connectivity
mid-route. So:

- route samples are buffered in Room **during** the walk;
- the walk uploads when the owner ends it;
- upload failure retries with backoff while the app is open;
- there is no long-lived background sync engine, and no multi-day offline queue.

---

## 8. Walk Tracking

```text
Owner selects which dogs are coming
→ selects Start
→ app waits for a GPS lock
→ foreground service starts
→ route renders on the map
→ samples buffered in Room
→ Owner selects End
```

The foreground service keeps tracking when the app is backgrounded. The phone
never decides the authoritative reward — the backend does.

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

Venues are registered with a coordinate, a geofence radius and a required dwell
time.

```text
Owner enters geofence
→ CheckIn created as IN_PROGRESS
→ dwell timer runs
→ dwell satisfied → COMPLETED → 12 points
→ owner leaves early → ABANDONED, no penalty
→ owner may return the same day and try again
```

Dwell requirements:

```text
vet          3 minutes
dog park     5 minutes
café        10 minutes
restaurant  20 minutes
```

Dwell completion is confirmed by the **backend** from timestamped location
reports. The client must not self-report a completed check-in.

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
→ Redeem button enables only inside the venue geofence
→ owner taps Redeem
→ order marked COLLECTED
```

Deduction happens at **order creation**, not at collection. Two consequences
that must be implemented:

- an order not collected by end of day moves to `EXPIRED` and the points are
  **refunded automatically** as a new lot, with a ledger entry;
- an admin can cancel and refund an order manually, for example when a venue has
  run out of stock.

At MVP the Redeem button is always tappable, so an order can be marked
collected away from the venue. This is a known and accepted gap.

Gating that button on the venue geofence is planned **after MVP**. It reuses the
check-in geofencing rather than adding a new mechanism, so the later change is
small. Build the collection endpoint so the check can be dropped in without
reshaping the flow.

### Café order screen

Café staff sign in to the Android app with a `CAFE` account and leave the order
screen open during trading hours.

```text
GET  /api/cafe/orders?since={cursor}       polled by the café screen
```

The screen polls every few seconds and lists orders still `PENDING` for that
café, showing the reference number, the owner's name, the items and the time
ordered. When the owner taps Redeem the order becomes `COLLECTED` and drops off
the list on the next poll.

Implementation requirements:

- the feed is scoped to the venue attached to the signed-in `CAFE` account, and
  must never return another café's orders;
- it accepts a `since` cursor and returns only what changed;
- respond `304 Not Modified` when nothing changed, so idle polling is nearly
  free;
- a five second interval is ample at pilot volume;
- an FCM push is also sent on order creation, so a café with the app closed or
  backgrounded is still alerted;
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
verify the geofence for collection
apply the state change
write ledger entries
COMMIT
```

If any step fails, `ROLLBACK`. A repeated request must return the existing
state, never apply the change twice.

### Charity donation

Points are deducted the same way and a reference number is issued. There is no
venue, no geofence and no collection step.

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
POST   /api/auth/social/google
POST   /api/auth/password-reset
DELETE /api/auth/account

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

Android may compute temporary display values, but the server never trusts them.

One shared error shape:

```json
{
  "code": "INSUFFICIENT_POINTS",
  "message": "Not enough points to complete this redemption."
}
```

---

## 15. Authentication and Permissions

Django authentication with token/JWT-style API auth. Google social login at
pilot; email and password as fallback. Password reset and account deletion are
both required.

```text
OWNER
- manage own dog
- create own walks and check-ins
- view venues and offers
- create own orders and donations
- view own wallet and history

CAFE
- view orders for own venue only
- receive order notifications
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
mock-location detection (isFromMockProvider + Play Integrity)
server-confirmed geofence dwell
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
- a defined retention period for raw GPS route samples (still open);
- registration evidence stored with restricted access and deleted after review
  where possible;
- account deletion must actually remove or irreversibly anonymise personal data;
- the owner's name is displayed on the café order screen, which must be stated
  in the privacy notice.

---

## 18. Notifications

Categories, with per-category opt-out:

| Type | Frequency |
|---|---|
| Walk reminder | Once daily, owner-chosen time, only if the goal is unmet |
| Heat safety | Temperature-triggered, summer |
| Nearby check-in | Max once daily, suppressed if already checked in |
| Streak at risk | Only approaching the 7 and 30-day milestones |
| Transactional | Uncapped (points awarded, order collected, refund) |

Hard cap of **two promotional notifications per day**, quiet hours 21:00–08:00.
Transactional messages are exempt. Over-notification is the main uninstall
driver for reward apps.

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
backend
mysql
```

Environment variables:

```text
DJANGO_SECRET_KEY
MYSQL_DATABASE
MYSQL_USER
MYSQL_PASSWORD
MYSQL_HOST
API_BASE_URL
GOOGLE_MAPS_API_KEY
FCM_CREDENTIALS
WEATHER_API_KEY
```

Never commit secrets. Never commit a real API key.

---

## 21. Four-Engineer Split

### Engineer 1 — Accounts and Dog

```text
registration, Google login, password reset, account deletion
owner profile
dog profiles, several per account, and breed reference data
personalised goal calculation
heat adjustment
```

### Engineer 2 — Venues and Check-ins

```text
venue and offer admin models
discovery list and map
geofence registration
dwell tracking and confirmation
check-in awards and daily uniqueness
```

### Engineer 3 — Walks and Wallet

```text
foreground tracking service
route UI and Room buffering
walk upload and validation
points engine, caps, rounding
point lots, ledger, FIFO spend, expiry job
streaks
```

### Engineer 4 — Redemption and Rewards

```text
order creation and deduction
café login, café order screen and its polling feed
collection endpoint, built to accept a geofence check later
expiry and refund job
charity donations
redemption history
vet and council evidence submission and admin review
```

Each engineer owns the Android UI, the API, the migration, the tests and the
docs for their area. Do not create permanent frontend/backend silos.

---

## 22. Shared-Code Rule

Before creating a new helper, convention, response type or auth method, check
whether one already exists. Shared concerns get one implementation:

```text
auth token handling
Retrofit client
API errors
Room database
Django permission classes
point transaction logic
geofence handling
reference number generation
```

---

## 23. Definition of Done

A use case is complete only when:

- the Android UI works;
- the backend API works;
- the migration runs from a blank database;
- error states are handled;
- automated tests exist;
- OpenAPI and docs are updated;
- the vertical flow works with no mocked data.

Main acceptance flow:

```text
Owner registers with Google
→ adds one or more dogs
→ sees a personalised daily goal per dog
→ starts a walk
→ sees the route
→ ends the walk
→ points are awarded within the cap
→ walks to a partner venue
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
mock location
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
iOS
merchant self-registration and self-service offer editing
geofence-gated order collection (planned after MVP)
offline tracking and queued sync
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
final API auth token implementation
```
