# Vitail — Dog Walking Rewards

Native iOS pilot, built with Swift and SwiftUI, where dog owners earn points
from tracked walks and partner check-ins, then spend those points on partner
offers or charity donations.

Vitail differs from general fitness apps in two ways. Targets are calculated per
**dog** rather than per person — using breed energy, age, size and a
brachycephalic flag, with lower targets for flat-faced or senior dogs and
reduced targets in Australian summer heat. And the reward loop connects walking
to **local businesses**, which general fitness apps do not do.

## Status

Pilot scope, Melbourne. This document and `TECH_STACK.md` reflect the client
requirements and platform decisions captured through 2026-08-24.

Anything not yet decided is tracked in `docs/DECISIONS.md`. Do not invent
behaviour for an open decision — raise it instead.

### Current build slice: authentication

The first use case is deliberately small:

```text
User selects "I'm a dog owner" or "I'm a cafe owner"
Dog owner self-registers or signs in → OWNER tab shell
Café owner signs in with an admin-created account → CAFE tab shell
```

Both roles use the same login API and iOS app. The API returns JWT access and
refresh tokens, which the app stores in Keychain. Sign in with Apple waits until
the project has its own Apple Developer Program account. Password reset and
in-app account deletion are later use cases, not part of this first slice.

The role choice makes the login page clear, but it does not grant a role. The
backend account remains authoritative, and a mismatched login asks the user to
choose the correct account type. The current post-login UI is deliberately a
shell: owners can swipe between Account, Walk and Redeem, with the same pages
available in the bottom navigation and fixed `0 pts` at top right.
Café owners have Account and Orders pages. Logout lives in Account for both
roles; Walk, Redeem, Orders and real point data are not implemented yet.

## Business Model

B2B2C. Vitail sits between dog owners and the partners who fund the reward
catalogue: insurers, councils, and local merchants (cafés, vets, groomers, pet
retailers). Partners pay for foot traffic, referrals and healthier-dog data.

## Product Roles

At pilot there are **three** account types.

| Role | Interface | Notes |
|---|---|---|
| **Dog owner** | iOS app | Tracks walks, checks in, redeems points |
| **Café staff** | iOS app | Signs in and watches incoming orders |
| **Vitail admin** | Django Admin | Onboards partners, handles support and disputes |

Owners and café staff use the **same iOS app**. The account role decides
which interface loads.

```text
OWNER → Account / Walk / Redeem shell
CAFE  → Account / Orders shell
ADMIN → Django Admin
```

Café accounts are created by a Vitail admin, not self-registered. Café staff
cannot edit their own offers during pilot — they contact Vitail and an admin
makes the change.

For the first use case, dog owners self-register with email and password. Café
staff use email-and-password accounts created by a Vitail admin. Google sign-in
is not included. Sign in with Apple will be added only after the project has its
own Apple Developer Program account.

The café screen is **read-only**. It lists orders waiting to be collected and
refreshes every few seconds, and it cannot mark an order collected. Only the
owner can do that by tapping Redeem in the iOS app. Order collection has no
location gate during the pilot.

Vets, councils and dog parks remain **data records, not accounts**.

## Dogs

An account can hold **multiple dogs**. Each walk records which dogs took part.

Stored per dog: name, photo, breed, age, size, and a brachycephalic flag.

This is **not** display-only. Breed energy, age, size and the brachycephalic
flag feed that dog's own personalised daily walk goal, and the goal is reduced
during Australian summer heat. A senior pug and a young kelpie on the same
account are targeted differently.

Dog count never multiplies points — walking three dogs earns the same as
walking one. The 20-point daily goal is awarded once per day per account, when
every dog that came along that day has met its own goal. A dog left at home does
not block it.

An account may hold up to **10 dogs**.

## Earning Points

| Source | Points | Limit |
|---|---|---|
| Walking | 8 per km | Counted up to 5 km/day (40 max) |
| Personalised daily goal met | 20 | Once per day |
| Partner venue / dog park / vet check-in | 12 | Once per venue per day, location-verified |
| Confirmed vet checkup | 200 | Max 2/year, at least 60 days apart |
| Council registration proof | 300 | Once per registration period, max 1/year |
| 7-day walking streak | 20 | One-time |
| 30-day walking streak | 100 | One-time |

**Daily cap: 72 points**, applied to the sum of walking + daily goal + venue
check-ins.

Vet checkups, council registration and streak bonuses sit **outside** the daily
cap.

Points always round down. Points expire **12 months** after they are earned.

> These are starting numbers. See `docs/DECISIONS.md` for the consequences of
> the 72-point cap on multi-venue check-ins.

## Check-in Dwell Times

Check-ins are user-initiated, not automatic. The owner opens a venue and taps
**Start check-in**, then must remain inside its configured check-in radius for:

| Venue type | Dwell |
|---|---|
| Vet | 3 minutes |
| Dog park | 5 minutes |
| Café | 10 minutes |
| Restaurant | 20 minutes |

Vet check-ins exist so dogs build a positive association with the vet, not only
for the reward.

If a check-in is not completed, progress is simply lost. There is no penalty,
and the owner can return later the same day and start another check-in at that
venue.

After Start check-in, location verification continues if the owner locks the
phone or switches apps. Background location updates stop when the check-in
completes, is abandoned, or the owner logs out. Force-quitting the app loses the
in-progress check-in.

## Walk Rules

```text
Owner selects which dogs are coming
→ taps Start
→ GPS lock required before tracking begins
→ Core Location records the route, including while the app is backgrounded
→ pauses under 5 minutes are forgiven (sniffing)
→ owner taps End
```

- Walks are started **manually**. There is no background auto-detection.
- Background location updates are enabled only while a manually started walk or
  check-in is active, and stop when that activity ends.
- A walk auto-ends after 5 minutes of inactivity, or if the owner logs out.
- Speed sanity checks exclude driving and cycling.
- GPS readings worse than 30 m accuracy are ignored.
- Minutes without signal (underground) do not count.

## Redeeming Points

Two redemption paths.

**Partner offer**

```text
Owner browses partner and selects items
→ confirms order
→ points are deducted immediately
→ order receives a reference number
→ the order appears on the café's order screen within seconds
→ owner travels to the venue
→ owner taps Redeem
→ order is marked collected
```

The Redeem action is not location-gated during the pilot. In-venue location
verification for collection is a possible post-MVP enhancement.

Uncollected orders expire at end of day and points are refunded automatically.

**Charity donation**

Owners can donate points to a selected charity. This path needs no merchant, no
location verification and no collection step.

Every redemption carries a reference number and appears in the owner's profile
history, so owners can see what they spent points on and Vitail can resolve
disputes with merchants.

Merchants set their own point prices and thresholds when signing a partnership.

## Anti-Abuse

Pilot runs largely on trust — the premise is that owners act in their dog's
interest. The safety net exists to discourage farming, not to police users:

```text
walking-speed sanity checks
GPS accuracy floor
simulated-location detection
venue proximity and dwell verification
daily caps
```

Photo check-ins are a desirable optional addition, not a pilot requirement.

## Project Structure

The repository now contains the first vertical slice. Future feature folders
are added only when their work begins.

```text
vitail-team-5/
├── ios/                 SwiftUI app and auth tests
├── backend/             Django API, accounts app and migration
├── docs/
│   ├── DECISIONS.md
│   └── FEATURES.md      (lightweight delivery status)
├── docker-compose.yml   local API and MySQL
├── Makefile             short local commands
├── README.md
└── TECH_STACK.md
```

## Local Development

Docker Compose has local-only defaults, so no environment file is required to
start. From the repository root:

```bash
make up
```

In a second terminal, create a Vitail admin and open the iOS project:

```bash
make superuser
make ios
```

The simulator uses `http://127.0.0.1:8000` automatically. To run on an iPhone,
copy the untracked local configuration and edit its Personal Team, unique
bundle identifier and Mac LAN address:

```bash
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig
```

Keep the Mac and iPhone on the same network, select the iPhone in Xcode, then
Run. A free Personal Team is enough; its development install expires after
seven days and can be installed again from Xcode.

Create café logins at `http://127.0.0.1:8000/admin/` with role `CAFE`. Useful
commands are `make test`, `make check`, and `make down`. To override the local
Compose defaults, copy `backend/.env.example` to a root `.env` and edit it;
neither `.env` nor `Local.xcconfig` is committed.

## Team Ownership

Work is split by vertical use case. Each engineer owns the iOS UI, API,
database changes, tests and documentation for their area.

| Engineer | Ownership |
|---|---|
| 1 | Accounts, login, dog profile, personalised goal calculation |
| 2 | Partner venues, discovery map, proximity checks, check-ins and dwell verification |
| 3 | Walk tracking, walk validation, points engine, ledger, streaks, expiry |
| 4 | Redemption orders, café order screen, in-store collection, charity donations, history |

## Must-Have Scope

The three features that define a successful first release:

```text
1. tracked walk
2. venue check-in
3. redeem points
```

## Out of Scope

Explicitly **not** built for pilot:

```text
Android
merchant self-registration and self-service offer editing
location-gated order collection (planned after MVP)
multi-walk offline queues and long-lived background sync
remote push notifications
App Attest and advanced device integrity
in-app payments or buying points
reviews and ratings
pet wearable integration
net-walking (parallel-walking boost)
friends and leaderboards
merchant-editable offers
dog-count point multipliers
point-earning from non-walking activity
```

## Source of Truth

- `README.md` — product overview and locked rules
- `TECH_STACK.md` — architecture and implementation conventions
- `docs/DECISIONS.md` — resolved decisions and open questions
- `docs/FEATURES.md` — one-row-per-feature delivery status
- OpenAPI — API contract
- Django models + migrations — physical database structure

If code or AI-generated suggestions conflict with these documents, resolve the
conflict before implementation.
