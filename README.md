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

Pilot scope, Melbourne. Product requirements and platform decisions are
retained below; the connected build status is updated through 2026-09-24.

Anything not yet decided is tracked in `docs/DECISIONS.md`. Do not invent
behaviour for an open decision — raise it instead.

### Current build: connected owner and café MVP

The app stays deliberately small:

```text
User chooses Dog Owner or Cafe → authentication form opens
Dog owner registers/signs in → Account / Walk / Redeem
Café owner signs in with an admin-created account → Account / Products / Orders
```

Both roles use the same login API and iOS app. The API returns JWT access and
refresh tokens, which the app stores in Keychain. Sign in with Apple waits until
the project has its own Apple Developer Program account. Password reset and
in-app account deletion are later use cases, not part of this first slice.

Owners tap their avatar/name card to edit their name/photo or log out. A new
owner with no dogs sees the Add Dog form. Dog rows open a detail page, and up to
10 profiles use backend breed reference data. People, dogs and cafés can choose
and crop a photo from the system photo picker; uploads persist on the server.
Personalised-goal inputs are stored, but no duration is displayed until the
open numeric welfare and heat-adjustment rules are resolved.

The role choice does not grant a role: the backend account is authoritative.
Owners can edit their name and dogs, see their real wallet balance, browse
cafés by photo/name/hours, open a café menu, confirm one reward per order, and
slide to collect from the order detail page. Café staff see those **same orders**, scoped to their own
café, with a read-only feed that refreshes while open. Owner logout is inside
the profile editor. The top owner title is Vitail; points appear only in Redeem
with an approximate coffee count (60 points per cup; actual menu prices vary).
Café Account also lets staff edit the café photo, name, address, description,
opening hours and Google Maps link. A blank link uses a Maps address search. Login email is read-only. Products lets each café create and edit its own
menu items, point prices and availability; existing order snapshots stay unchanged.

Points deduct once at order creation. Retrying the same confirmation does not
create another order. Uncollected orders expire at the next Melbourne midnight
and refund automatically; admins can also cancel/refund pending orders. Admin
point grants are positive-only, and existing ledger/order records are read-only.

The current catalogue uses one `Reward` linked directly to a café account and
one item (quantity 1) per `Redemption`. There is no cart or separate venue/order
database. Names, price and café ownership are snapshotted at order time.

Walk uses a full-height map with a bottom menu that expands to show history.
Start begins recording; walking shows Pause, and paused walks show Resume and
Finish. Finish saves a protected pending summary. The owner chooses dogs and
confirms completion before an eligible record uploads measured GPS and segment
boundaries for points. No dogs means local history with zero points. Pending
summaries survive relaunch; lock-screen recording and recovery remain supported. Server receipts, not
the live distance estimate, confirm points. Foreground Retry reconciles a
previously timed-out upload before posting again. Old local records without
accuracy/source metadata remain viewable but are not retroactively credited.
The server still stores summaries only, not raw routes. See
`docs/WALK_INTEGRATION.md` for limits and compatibility.

Walk-distance earning is connected in this integration; the feature checklist
and limits are in `docs/FEATURES.md`. Personalised-goal awards, check-ins, streaks,
charity donations, social sharing and the wider product rules below remain
**planned**, not claims that those features already work.

## Business Model

B2B2C. Vitail sits between dog owners and the partners who fund the reward
catalogue: insurers, councils, and local merchants (cafés, vets, groomers, pet
retailers). Partners pay for foot traffic, referrals and healthier-dog data.

## Product Roles

At pilot there are **three** account types.

| Role | Interface | Notes |
|---|---|---|
| **Dog owner** | iOS app | Tracks walks, checks in, redeems points |
| **Café staff** | iOS app | Manages own products and venue details; watches incoming orders |
| **Vitail admin** | Django Admin | Onboards partners, handles support and disputes |

Owners and café staff use the **same iOS app**. The account role decides
which interface loads.

```text
OWNER → Account / Walk / Redeem
CAFE  → Account / Products / Orders
ADMIN → Django Admin
```

Café accounts are created by a Vitail admin, not self-registered. Café staff
manage their own products in Products: name, description, positive whole-number
point price and availability. Unavailable items disappear from the owner catalogue;
existing orders retain their original details. Admin can also manage the catalogue.

For the first use case, dog owners self-register with email and password. Café
staff use email-and-password accounts created by a Vitail admin. Google sign-in
is not included. Sign in with Apple will be added only after the project has its
own Apple Developer Program account.

The café Orders screen is **read-only**. It lists orders waiting to be collected and
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

## Earning Points — product rules

These are the full pilot rules. Only implemented sources listed in
`docs/FEATURES.md` award points in the current build; an admin may grant test
points to exercise redemption without a walk.

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
Owner taps Start
→ GPS lock required before tracking begins
→ Core Location records the route, including while the app is backgrounded
→ pauses under 5 minutes are forgiven (sniffing)
→ owner pauses, then taps Finish
→ reviews distance/time, chooses dogs and confirms completion
→ server confirms awarded points (or zero points for a dogless local record)
```

- Walks are started **manually**. There is no background auto-detection.
- Background location updates are enabled only while a manually started walk or
  check-in is active, and stop when that activity ends.
- A walk auto-ends after 5 minutes of inactivity, or if the owner logs out.
- Speed sanity checks exclude driving and cycling.
- GPS readings worse than 30 m accuracy are ignored.
- Minutes without signal (underground) do not count.

## Redeeming Points

The partner-offer path is implemented as one reward per order. Charity donations
remain planned.

**Partner offer**

```text
Owner browses cafés, opens a menu and selects one item
→ confirms order
→ points are deducted immediately
→ order receives a reference number
→ the order appears on the café's order screen within seconds
→ owner travels to the venue
→ owner opens the order details and slides to collect
→ order is marked collected
```

The Redeem action is not location-gated during the pilot. In-venue location
verification for collection is a possible post-MVP enhancement.

Uncollected orders expire at end of day and points are refunded automatically.

**Charity donation**

Owners can donate points to a selected charity. This path needs no merchant, no
location verification and no collection step.

Every redemption carries a reference number and appears in the owner's Redeem
history, so owners can see what they spent points on and Vitail can resolve
disputes with merchants. Refunds are new credits valid for twelve calendar months;
the original debit and terminal order remain in the audit history.

Merchants set their own point prices and thresholds when signing a partnership.
The wallet uses 60 points ≈ 1 cup of coffee as an approximate display reference
(confirmed on 2026-09-23), not a fixed price for every menu item.

Photo storage and deployment requirements are in [backend/MEDIA.md](backend/MEDIA.md).

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

Feature folders are added only when their work begins.

```text
vitail-team-5/
├── ios/                 SwiftUI app and focused feature tests
├── backend/             Django accounts, dogs, rewards and walk APIs
├── docs/
│   ├── DECISIONS.md
│   ├── FEATURES.md      (lightweight delivery status)
│   └── openapi.yaml     (implemented API contract)
├── docker-compose.yml   local API, MySQL and expiry worker
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

Create café logins at `http://127.0.0.1:8000/admin/` with role `CAFE`. Each tester
chooses their own passwords; there are no shared demo credentials. Useful
commands are `make test`, `make check`, `make expire`, and `make down`. `make test`
uses an isolated SQLite test database and does not reset the shared MySQL data.
Use MySQL separately for row-lock/concurrency checks. To override the local
Compose defaults, copy `backend/.env.example` to a root `.env` and edit it;
neither `.env` nor `Local.xcconfig` is committed.

For an explicitly requested clean local demo with one funded owner, one admin
and three cafés with menus, see `docs/LOCAL_DEMO.md`. Resetting demo accounts is
a separate, backed-up operation; it never runs automatically on startup.

### Quick connected-flow test

1. Run `make up`, then `make superuser` in another terminal. Leave Compose running.
2. Open `http://127.0.0.1:8000/admin/`. Create a user with role **CAFE**, then
   create an available **Reward** for that café (for example, Coffee for 40 points).
3. Run `make ios`, choose a simulator or connected iPhone in Xcode, and press Run.
   Choose **I'm a dog owner** and register a test owner.
4. In Admin → **Point entries** → Add, grant that owner 100 points with a future
   expiry. This is an optional test shortcut, not a second wallet.
5. In the owner app, refresh Redeem, confirm the Coffee order and check the
   balance is 60 with a reference number in history.
6. In a second simulator/iPhone, sign in as the café. Orders should show the same
   reference. Only the owner can tap Redeem/collect; it then disappears from the
   café feed. Café Account can save the venue name/address/description/hours.
   In Products, create or edit an item and toggle availability; refresh the
   owner catalogue to see the change. Another café must not be able to edit it.
   Signing out and switching roles on one device also works.
7. To test a refund immediately, create another order, then select it in Admin
   → Redemptions → **Cancel pending orders and refund points**. Refresh the owner
   wallet/history and café feed; repeating the action must not add points again.

For real earning, add/select a dog in Walk, allow precise location and record an
outdoor walk. End/upload it while online; server-validated distance awards
8 points/km, up to 40 walking points per Melbourne day, to the same wallet.
Goal and check-in bonuses are not awarded yet. Use a real iPhone for GPS tests;
simulated-location samples are intentionally rejected.

Compose runs `expire_rewards --watch --interval 60` after the API starts, so
end-of-day refunds and twelve-month point expiry run without an open app.
`make expire` runs one sweep manually; it does **not** force future orders to
expire. Wallet/history/feed/collection requests also enforce order expiry.
Pulling code shares schema migrations, **not other developers' database rows**.

### Temporary Backend URL setting

In a Debug build, sign out and use **Backend URL (Debug Only)** on the login
page. Enter the backend's full `http://` or `https://` address, without `/api`,
and tap **Save**. All new requests use it immediately, and it stays saved on
that device. **Reset** returns to the build's configured address.

Testers can enter the same HTTPS tunnel URL, such as an ngrok address, to use
one backend without sharing a Wi-Fi network. The backend and tunnel must stay
running; if the tunnel address changes, testers need to save the new address.
Use test accounts and data when exposing the local development server.

Saved login tokens are bound to their backend address. Switching the address
requires signing in again; old credentials without an address binding also
require a one-time new login after this update.

The override is excluded from Staging and Release. To remove it later, search
for `TEMPORARY DEBUG BACKEND URL OVERRIDE` in `APIClient.swift` and `AuthView.swift`
and remove the matching Debug tests. Keep personal signing values in the
ignored `ios/Config/Local.xcconfig`, not in the shared Xcode project.

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
merchant self-registration
location-gated order collection (planned after MVP)
general offline authentication and long-lived background upload workers
remote push notifications
App Attest and advanced device integrity
in-app payments or buying points
reviews and ratings
pet wearable integration
net-walking (parallel-walking boost)
friends and leaderboards
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
