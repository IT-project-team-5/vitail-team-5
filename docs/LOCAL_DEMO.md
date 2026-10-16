# Local café demo data

The `reset_demo_data` management command replaces a deliberately selected local
development database's accounts and activity with:

- `owner@vitail.test`: one dog owner with 10,000 points by default.
- `admin@vitail.test`: one Vitail administrator.
- `riverside@vitail.test`: Riverside Paws Café.
- `garden@vitail.test`: Garden Tails Café.
- `laneway@vitail.test`: Laneway Bark Espresso.

Each café has an introduction, explicitly fictional demo address, a distinct
Melbourne demo coordinate, opening hours and five available products with
descriptions and prices between 40 and 180 points. All three are enabled as
check-in hotspots; they are not claims about real businesses. Products use the
existing Reward catalogue and can be edited
after signing in as the café and opening Products. The owner can redeem them
using the same wallet and order flow.

All five passwords are independently generated for each reset. They are written
to a new JSON file with owner-only permissions, never to source control or command
output. Keep credentials and SQL backups under the ignored `backend/.local-demo/`
directory. No fixed demo password is included in this repository.

## Reset procedure

This deletes existing users, dog profiles, walks, orders, products, point entries,
venues, friendships, blocks, check-ins and their walk contexts, live walk sessions/samples, goal snapshots,
Quest qualifications, evidence versions and entitlements, feed cursors, admin logs
and sessions. Breed reference data and
schema migrations remain. Account ID sequences are preserved so old tokens and
local route archives cannot become another user's data.

1. Confirm that Compose points to the intended **local** database. Stop `api`,
   `expiry` and `social_presence` so no service writes during the reset; leave MySQL running.
2. Take and verify a private SQL backup of that database.
3. Create `backend/.local-demo/` and run the command in a one-off API container.
   Replace the database name below if the verified local configuration differs;
   choose a new output filename for every reset:

   ```bash
   docker compose run --rm --no-deps api python manage.py reset_demo_data \
     --confirm-database vitail \
     --credentials-file /app/.local-demo/demo-credentials.json
   ```

   An existing credentials file, incorrect database confirmation or `DEBUG=False`
   prevents the reset. `--owner-points` accepts 1 through 1,000,000. All deletions
   and creations share a transaction; failure to save credentials rolls it back.
4. Verify five users, three populated and geocoded Venues, fifteen available products,
   the owner's balance, and an empty order/walk history. Restart `api`, `expiry`
   and `social_presence`.
5. Sign out of any old iOS session, then sign in with the generated credentials.
   The admin uses the web admin; the owner and cafés use the iOS app.

Database rows and private credentials are local state; a Git pull does not copy
them to teammates. Physical iPhone layout and network acceptance remain separate
from automated API and view-model tests.

## Five-point redemption test

With the local Docker services running, add the test product without resetting
accounts or changing wallets:

```sh
docker compose exec api python manage.py demo_reward --state available
```

The product is labelled **DUMMY reward — no real redemption value**, costs exactly
5 points, and uses the normal registration, catalogue, wallet, and order rules.
Its dedicated fictional café has no usable login password. The command requires
`DEBUG=True`; both listing and purchasing this café's rewards are disabled when
`DEBUG=False`. No registration checks are bypassed and no points are granted.

To test an empty catalogue in a disposable development database:

```sh
docker compose exec api python manage.py demo_reward --state unavailable --exclusive
```

`--exclusive` also disables all other rewards in that development database. It
does not delete orders or change balances. Re-enable those products through café
product settings when finished. Restore just the test reward with:

```sh
docker compose exec api python manage.py demo_reward --state available
```

Refresh Redeem after each change. Check these cases using a development owner:

| State | Expected result |
| --- | --- |
| Any current dog lacks accepted microchip registration | Purchase disabled; registration explanation and a link for each incomplete dog, even with no rewards |
| No current reward | “No rewards available”; a stale purchase is rejected without a debit |
| Registered, balance 0 or 4 | Purchase disabled with the points shortfall; direct requests rejected |
| Registered, balance 5 | One order and one 5-point debit; balance 0 |
| Registered, balance 12 | One order and one 5-point debit; balance 7 |
| Repeated taps or retry after a lost response | Same request recovers one order; one debit only |
| Transaction fails after debit | Order and debit both roll back; balance unchanged |

Complete registration through the registration link; collecting the separate
registration points is optional. Use existing development wallet administration
to set up the balance cases. Backend regression tests create isolated wallets
for all these cases, including real MySQL row-lock tests for simultaneous requests.

```sh
docker compose run --rm --no-deps -e DATABASE_ENGINE=sqlite api python manage.py test rewards.tests.test_redemption_eligibility
```

The SQLite run skips the concurrency cases; run the same test module against an
isolated MySQL test database to exercise those. iOS regression cases live in
`RedemptionTests.swift`; run the Vitail test scheme in Xcode for full app checks.
