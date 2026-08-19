# Tech Stack and Architecture

This document defines the technical architecture for the Dog Walking Rewards prototype.

The goal is to keep the system simple enough for a four-engineer junior team while still using production-style foundations: one Android app, one backend, one relational database, clear API contracts, and vertical use-case ownership.

---

## 1. Final Stack

| Layer | Technology |
|---|---|
| Android language | Kotlin |
| Android UI | Jetpack Compose |
| Android architecture | MVVM-style separation |
| Local persistence | Room |
| API client | Retrofit + OkHttp |
| Background sync | WorkManager |
| Walk tracking | Android Foreground Service |
| Location | Fused Location Provider |
| Maps | TBD |
| QR generation | Android-compatible QR library |
| QR scanning | CameraX-compatible QR scanner |
| Backend language | Python |
| Backend framework | Django |
| API framework | Django REST Framework |
| Database | MySQL |
| Internal admin | Django Admin |
| API contract | OpenAPI |
| Local development | Docker Compose |
| Version control | Git |

---

## 2. Why This Architecture

### One Android App

Owners and cafés use the same app, with the backend role deciding which interface is shown.

```text
Account.role
├── OWNER
├── CAFE
└── ADMIN
```

Reasons:

- only one frontend codebase;
- one login/authentication flow;
- easier maintenance for a small prototype;
- café QR scanning can use native Android camera APIs;
- all engineers learn the same frontend stack;
- avoids maintaining React/web infrastructure for only a few cafés.

The backend must still enforce role permissions. UI visibility is not security.

### Kotlin + Jetpack Compose

Kotlin is used because the prototype is Android-only and depends heavily on Android-native functionality:

- background location;
- foreground services;
- camera access;
- local offline storage;
- notifications;
- device lifecycle handling.

Jetpack Compose keeps new UI development simpler than maintaining XML layouts.

### Django REST Framework

Django provides:

- structured models;
- ORM;
- migrations;
- authentication and permissions;
- transaction support;
- Django Admin;
- a clear API layer through Django REST Framework.

This reduces how much infrastructure junior engineers must design from scratch.

### MySQL

MySQL is used from the beginning because:

- it matches the team's existing stack;
- the app has relational data;
- point deductions and redemptions require transactions;
- migrations are safer than ad-hoc CSV schema changes;
- the prototype can grow without changing database technology.

CSV may still be used for:

```text
seed data
fixtures
imports
exports
debugging
```

CSV is not the runtime database.

---

## 3. High-Level Architecture

```text
                         ANDROID APP
                              │
                ┌─────────────┴─────────────┐
                │                           │
            OWNER ROLE                  CAFE ROLE
                │                           │
      ┌─────────┼─────────┐       ┌─────────┼─────────┐
      │         │         │       │         │         │
     Dogs     Walks     Cafés   Profile    Items    QR Scan
      │         │         │       │         │         │
      └─────────┴─────────┴───────┴─────────┴─────────┘
                              │
                         HTTPS / JSON
                              │
                              ▼
                     DJANGO REST API
                              │
        ┌─────────────┬───────┼───────────┬─────────────┐
        │             │       │           │             │
     Accounts        Cafés   Walks      Wallet      Redemptions
        │             │       │           │             │
        └─────────────┴───────┴───────────┴─────────────┘
                              │
                              ▼
                            MySQL
```

---

## 4. Suggested Repository Structure

```text
dog-rewards/
├── android/
│   └── app/
├── backend/
│   ├── accounts/
│   ├── cafes/
│   ├── walks/
│   ├── wallets/
│   └── redemptions/
├── docs/
│   ├── PROJECT_MAP.md
│   ├── USE_CASES.md
│   ├── DATA_MODEL.md
│   ├── API_RULES.md
│   └── DECISIONS.md
├── docker-compose.yml
├── README.md
└── TECH_STACK.md
```

Recommended authority:

| Source | Authority |
|---|---|
| `README.md` | Product overview and locked rules |
| `TECH_STACK.md` | Technical architecture and conventions |
| `PROJECT_MAP.md` | Detailed product behaviour |
| OpenAPI | API request/response contract |
| Django models + migrations | Physical database |
| `DECISIONS.md` | Intentional changes and TBD decisions |

---

## 5. Backend Domain Split

Use separate Django apps by domain.

```text
accounts
cafes
walks
wallets
redemptions
```

This reduces migration conflicts and makes ownership clearer.

### accounts

Responsible for:

- owner registration;
- café registration;
- login;
- account roles;
- owner profile;
- dog CRUD.

### cafes

Responsible for:

- café profile;
- location;
- opening hours;
- catalogue items;
- item availability;
- café discovery.

### walks

Responsible for:

- uploaded walks;
- route samples;
- participating dogs;
- validation status;
- validated duration.

### wallets

Responsible for:

- current point balance;
- point ledger;
- walk rewards;
- manual admin adjustments.

### redemptions

Responsible for:

- carts/redemption requests;
- QR tokens;
- item snapshots;
- café confirmation;
- atomic point deduction;
- redemption history.

---

## 6. Core Data Model

### Account

```text
id
username
password_hash
role
display_name
profile_photo
is_active
created_at
```

Rules:

- username is unique;
- passwords are hashed using Django authentication;
- plaintext passwords are never stored;
- role is `OWNER`, `CAFE`, or `ADMIN`.

### Dog

```text
id
owner_id
name
photo
breed
age
created_at
```

One owner may have multiple dogs.

### Cafe

```text
id
account_id
name
description
address
latitude
longitude
opening_hours
photo
created_at
updated_at
```

For the prototype:

```text
one café account = one café
```

Café registration becomes active immediately.

### CafeItem

```text
id
cafe_id
name
description
photo
point_price
is_available
created_at
updated_at
```

Coffee and dog snacks are normal catalogue items.

Rewards are not tied to dogs.

### Walk

```text
id
client_uuid
owner_id
start_time
end_time
status
valid_minutes
earned_points
created_at
```

`client_uuid` is generated on the phone before tracking starts.

Purpose:

```text
same walk uploaded twice
→ same client_uuid
→ backend returns existing result
→ no duplicate points
```

### WalkDog

```text
walk_id
dog_id
```

Records which registered dogs participated in the walk.

Dog count does not affect points.

### WalkPoint

```text
id
walk_id
latitude
longitude
recorded_at
accuracy
sequence_number
```

Only store the minimum GPS data required for route reconstruction and basic validation.

### Wallet

```text
owner_id
balance
updated_at
```

### PointLedger

```text
id
owner_id
amount
type
walk_id
redemption_id
reason
created_at
```

Examples:

```text
+35 WALK_REWARD
-100 REDEMPTION
+50 ADMIN_ADJUSTMENT
```

Rule:

> Never change wallet balance without creating the corresponding ledger entry.

### Redemption

```text
id
user_id
cafe_id
token
status
total_points
expires_at
confirmed_at
created_at
```

### RedemptionItem

```text
id
redemption_id
cafe_item_id
item_name_snapshot
point_price_snapshot
quantity
```

Item names and prices are snapshotted so historical purchases remain correct after a café edits its catalogue.

---

## 7. Android Architecture

Recommended structure:

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

The UI should not directly call Retrofit or Room.

### Suggested feature modules/packages

```text
auth
dogs
cafes
walks
wallet
redemption
shared
```

### Shared Android responsibilities

Keep these shared instead of reimplementing them per use case:

```text
API client configuration
authentication token storage
error mapping
navigation
loading states
image loading
shared UI components
Room database
network connectivity handling
```

---

## 8. Walk Tracking

The owner:

```text
selects dog(s)
→ presses Start
→ foreground service begins
→ route appears on map
→ GPS points are stored locally
→ presses End
```

The foreground service continues tracking when the app is backgrounded.

The phone stores:

```text
latitude
longitude
timestamp
GPS accuracy
```

The phone should not decide the authoritative reward.

### Offline Flow

```text
Start walk
→ generate client_uuid
→ store route in Room
→ finish
→ if online: upload
→ if offline: PENDING_SYNC
→ WorkManager retries
→ backend validates
→ backend awards points
```

### Walk State Machine

```text
RECORDING
    ↓
PENDING_SYNC
    ↓
VALIDATING
   ↙       ↘
ACCEPTED   REJECTED
```

### Point Rules

```text
1 valid minute = 1 point
minimum walk = 10 minutes
maximum earning = 300 points/day
points never expire
dog count does not multiply points
```

The daily cap is based on the walking date, not the upload date.

### Prototype Validation

Only basic validation is required.

Check for:

- missing GPS samples;
- invalid timestamp order;
- extremely inaccurate samples;
- impossible location jumps;
- sustained vehicle-like speed;
- minimum valid duration.

Advanced fake-GPS detection is out of scope.

---

## 9. Café Discovery

Owner café discovery requires:

```text
café name
location
distance
opening hours
photo
available items
point prices
```

Map/geocoding provider is still TBD.

The backend should return café data; Android decides how it is displayed on the map.

---

## 10. Redemption Flow

A user may select multiple items and quantities from one café.

```text
Owner selects café
→ adds items
→ requests redemption
→ backend reads current item prices
→ backend calculates total
→ backend checks balance
→ backend creates QR
→ café scans QR
→ backend returns preview
→ café confirms or rejects
→ backend checks balance again
→ backend confirms redemption
→ points are deducted atomically
→ ledger record is created
```

### QR Rules

```text
valid for 5 minutes
random token
single-use
tied to one café
tied to one redemption
```

Do not use a raw user ID as the QR security mechanism.

### Redemption State Machine

```text
PENDING
 ├── CONFIRMED
 ├── REJECTED
 ├── EXPIRED
 └── CANCELLED
```

### Atomic Confirmation

Café confirmation must execute in one database transaction.

Conceptually:

```text
BEGIN

lock redemption
check status = PENDING
check not expired
check café matches
check current balance
deduct balance
create ledger debit
mark redemption CONFIRMED

COMMIT
```

If any step fails:

```text
ROLLBACK
```

A repeated confirmation request must return the already-completed state instead of deducting points again.

---

## 11. API Structure

Suggested API groups:

```text
/api/auth/
/api/dogs/
/api/cafes/
/api/walks/
/api/wallet/
/api/redemptions/
```

Possible endpoint shape:

```text
POST   /api/auth/register/owner
POST   /api/auth/register/cafe
POST   /api/auth/login

GET    /api/dogs
POST   /api/dogs
PATCH  /api/dogs/{id}
DELETE /api/dogs/{id}

GET    /api/cafes
GET    /api/cafes/{id}
GET    /api/cafes/{id}/items

POST   /api/walks
GET    /api/walks/{id}

GET    /api/wallet
GET    /api/wallet/ledger

POST   /api/redemptions
GET    /api/redemptions/{token}/preview
POST   /api/redemptions/{id}/confirm
POST   /api/redemptions/{id}/reject
```

Exact routes should eventually be defined by OpenAPI rather than copied manually between developers.

---

## 12. API Rules

The backend is authoritative for:

```text
account role
walk validity
earned points
daily cap
wallet balance
catalogue price
redemption total
redemption state
QR expiry
```

Android may calculate temporary UI values, but those values are never trusted by the server.

Use one shared error response structure, for example:

```json
{
  "code": "INSUFFICIENT_POINTS",
  "message": "Not enough points to complete this redemption."
}
```

Avoid every engineer inventing different response formats.

---

## 13. Authentication and Permissions

Use Django's authentication system with API token/JWT-style authentication.

Final token implementation is TBD.

Backend permissions should enforce:

```text
OWNER
- manage own dogs
- create own walks
- view cafés
- create own redemptions
- view own wallet/history

CAFE
- edit own café
- manage own items
- scan/confirm redemptions for own café
- view own redemption history

ADMIN
- Django Admin access
```

Never trust an account ID sent by the Android app when the authenticated user identity already determines ownership.

Example:

Bad:

```text
POST /walks
owner_id = 123
```

Better:

```text
POST /walks
backend gets owner from authenticated request
```

---

## 14. MySQL and Migration Policy

MySQL is used from day one.

Normal schema workflow:

```text
edit Django model
→ generate migration
→ review migration
→ run migration
→ commit model + migration together
```

Every schema-changing pull request should contain:

```text
model change
migration
tests
documentation update
```

During very early development:

```text
team may intentionally reset + reseed development DB
```

After pilot data matters:

```text
do not casually reset
use forward migrations
backup before risky changes
```

### Why migrations are still simpler than CSV

With migrations:

```text
every developer gets the same schema
schema changes are version-controlled
CI can build DB from zero
relationships stay explicit
```

Without migrations, schema knowledge becomes tribal knowledge and each developer's database drifts.

---

## 15. Development Environment

Recommended Docker Compose services:

```text
backend
mysql
```

Optional later:

```text
redis
```

Redis is not required for the current prototype.

Recommended environment variables:

```text
DJANGO_SECRET_KEY
MYSQL_DATABASE
MYSQL_USER
MYSQL_PASSWORD
MYSQL_HOST
API_BASE_URL
```

Never commit production secrets.

---

## 16. Four-Engineer Split

Work by vertical use case.

### Engineer 1 — Accounts and Dogs

```text
owner registration
café authentication foundation
login
profile
dog CRUD
```

### Engineer 2 — Café and Discovery

```text
café self-registration
café profile
location
catalogue CRUD
availability
owner café map
item browsing
```

### Engineer 3 — Walk and Wallet

```text
dog selection
foreground tracking
route UI
Room
offline sync
walk upload
validation
point calculation
wallet
ledger
```

### Engineer 4 — Redemption

```text
cart
quantities
QR generation
QR scanner
preview
confirmation
atomic deduction
redemption history
```

Each engineer owns:

```text
Android UI
Django API
database model/migration
tests
documentation
```

Do not create permanent frontend/backend silos.

---

## 17. Shared-Code Rule

Before creating a new helper, model convention, API response type, or authentication method, check whether one already exists.

Shared concerns should have one implementation.

Examples:

```text
auth token handling
Retrofit client
API errors
Room database
Django permission classes
point transaction logic
QR token generation
```

Avoid four engineers creating four versions of the same concept.

---

## 18. Definition of Done

A use case is complete only when:

- Android UI works;
- backend API works;
- MySQL migration works from a blank database;
- error states are handled;
- automated tests exist;
- OpenAPI/docs are updated;
- the complete vertical flow works without mocked data.

Main acceptance flow:

```text
Owner registers
→ adds dog
→ starts walk
→ sees route
→ loses internet
→ completes walk
→ reconnects
→ walk syncs
→ points are awarded
→ finds café
→ selects multiple items
→ generates QR
→ café scans
→ café confirms
→ points are deducted exactly once
→ redemption appears in history
```

Critical failure tests:

```text
duplicate walk upload
expired QR
duplicate QR confirmation
insufficient balance
unavailable item
invalid login
offline retry
```

---

## 19. Out of Scope for v1

```text
iOS
separate café web app
social login
advanced GPS fraud detection
custom admin frontend
automatic café reimbursement settlement
point expiry
dog-based reward restrictions
dog-based point multiplier
```

---

## 20. TBD

The team must explicitly decide these later:

```text
map/geocoding provider
raw GPS route retention period
deployment provider
final API auth token implementation
final QR library
```

Developers and AI assistants must not silently invent behaviour for a TBD.

When a TBD is resolved, record it in `docs/DECISIONS.md`.
