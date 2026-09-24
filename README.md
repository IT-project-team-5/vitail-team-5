# Vitail — Dog Walking Rewards

Native iOS app and Django API for a Melbourne dog-walking rewards pilot.
Owners record walks, collect eligible care rewards and spend points at cafés.
Café accounts manage their own venue, menu and incoming orders.

## Start locally

Docker Desktop must be running and unpaused. From the repository root:

```bash
make up
```

In a second terminal:

```bash
make superuser
make ios
```

Compose starts MySQL, applies migrations, serves the API at
`http://127.0.0.1:8000`, and runs the point/order expiry worker. Open
`http://127.0.0.1:8000/admin/` to manage test accounts and data. The iOS simulator
uses that API address by default.

| Command | Purpose |
|---|---|
| `make test` | Backend tests on isolated SQLite; does not reset local MySQL data |
| `make check` | Django checks and migration drift check |
| `make migrate` | Apply pending migrations to the configured local database |
| `make expire` | One idempotent sweep of due point expiry and order refunds |
| `make down` | Stop Compose services without deleting the database volume |

MySQL locking/concurrency checks require a separate disposable test database.
For iOS tests, choose the Vitail scheme and a simulator in Xcode, then
**Product → Test**. Physical GPS acceptance is a separate
[device checklist](docs/WALK_TESTING.md).

Local Compose defaults need no `.env`. To override them, copy
`backend/.env.example` to a root `.env`. Keep secrets and personal signing
configuration out of Git. Pulling code shares migrations, not another
teammate's database rows. The optional [local demo reset](docs/LOCAL_DEMO.md)
is a separate, explicitly requested operation; startup never resets accounts.

### Run on an iPhone

```bash
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig
```

Set your development team, unique bundle identifier and the Mac's reachable
LAN API address in that ignored file. Keep the phone and Mac on the same
network, select the device in Xcode and Run. The phone's `localhost` is the
phone, not the Mac.

Debug builds also expose **Backend URL (Debug Only)** below the login page's
initial screen. Sign out, scroll down, enter a full HTTP/HTTPS address without
`/api`, and save. Reset restores the build configuration. A shared HTTPS tunnel
can connect testers to one running development backend; changing its address
requires updating each device. Credentials are bound to the backend address,
so changing it requires signing in again. This override is absent from
Staging and Release.

## Current app

| Account | Navigation | Available flow |
|---|---|---|
| Owner | Account / Walk / Quest / Redeem | Email registration, profiles/photos, dogs and birthdays, recorded walks, care rewards, wallet and café orders |
| Café | Account / Products / Orders | Admin-created login, venue details/photo/Maps, menu prices and availability, read-only pending orders |
| Admin | Django Admin | Onboarding, catalogue, positive test-point grants, pending-order cancellation/refunds and evidence access |

Dog Owner and Cafe login rows expand their form on the same page. The server's
account role controls access. Tokens use Keychain and a shared refresh path.
Owner logout lives inside the avatar/profile editor; both account types have
persisted System/Light/Dark appearance settings.

Walk uses a map and draggable menu. Start/Pause/Resume/Finish leads to a saved
summary where the owner chooses participating dogs and confirms upload.
No-dog walks remain local with zero points. Protected local drafts/history,
paused recovery and stable upload IDs preserve work without duplicate awards.
Only server receipts confirm points. See [Walk integration](docs/WALK_INTEGRATION.md).

Quest shows actionable birthday and document tasks, with explicit Collect.
Collected rows leave the list after Melbourne midnight; their history remains.
The map and Quest share a check-in presentation/store, but **no production
location provider or iOS check-in service is enabled yet**.

Redeem lists cafés, menus and actual product prices. Purchase deducts points
once and opens a receipt; the owner slides to collect. Uncollected orders
expire at the next Melbourne midnight and refund automatically. Café staff see
those same orders and cannot collect them for the owner.

The database now has a normalized Venue and foundations for daily goals,
check-ins, live sessions/location samples, net-walking and friendships. These
schema changes **do not deliver social APIs, location ingestion, matching,
leaderboards, goal/streak rewards, chat, notifications or charity donations**.
See [feature status](docs/FEATURES.md) before treating a capability as available.

## Quick connected-flow check

1. Create a `CAFE` login in Admin and its venue/menu; café Products can manage
   that account's items. Register an owner from the iOS login page.
2. Optionally grant the owner 100 test points in Admin → Point entries, with a
   future expiry. This uses the real ledger, not a second test wallet.
3. Price a test item at 40 points, refresh Redeem and purchase it. Verify the
   receipt reference and the remaining balance of 60.
4. Sign in as the café on another device, or switch accounts. Verify the same
   pending order. Only the owner can slide to collect; the café feed then removes it.
5. For another pending order, use Admin → Redemptions → **Cancel pending orders
   and refund points**. Repeating the action must not add another refund.
6. For real walking points, use an iPhone outdoors, finish the walk, choose dogs
   and confirm. Simulator-generated locations cannot earn points.

## Documentation

| Document | Authority |
|---|---|
| [Quest and point policy](docs/QUESTS.md) | Canonical reward amounts, limits, current delivery and check-in handoff |
| [Decisions](docs/DECISIONS.md) | Current choices and unresolved questions |
| [Feature status](docs/FEATURES.md) | What can be tested now versus foundations/future work |
| [Technical architecture](TECH_STACK.md) | Shared services, storage, transactions and development conventions |
| [OpenAPI](docs/openapi.yaml) | Implemented HTTP request/response contract |
| [Database design](docs/database-design-2026-09-25/README.md) | Domain tables, constraints and requirement coverage; migrations define physical schema |
| [Walk integration](docs/WALK_INTEGRATION.md) / [device tests](docs/WALK_TESTING.md) | Recording, confirmation, recovery and acceptance limits |
| [Media](backend/MEDIA.md) / [evidence](backend/evidence/README.md) | Public photos and authenticated private document storage |

Each feature owner maintains its UI, API, migrations, tests and relevant docs.
Do not create a parallel wallet/order model or invent behavior for an open
policy question.
