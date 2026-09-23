# Local café demo data

The `reset_demo_data` management command replaces a deliberately selected local
development database's accounts and activity with:

- `owner@vitail.test`: one dog owner with 10,000 points by default.
- `admin@vitail.test`: one Vitail administrator.
- `riverside@vitail.test`: Riverside Paws Café.
- `garden@vitail.test`: Garden Tails Café.
- `laneway@vitail.test`: Laneway Bark Espresso.

Each café has an introduction, demo address, opening hours and five available
products with descriptions and prices between 40 and 180 points. These venues
are fictional. Products use the existing Reward catalogue and can be edited
after signing in as the café and opening Products. The owner can redeem them
using the same wallet and order flow.

All five passwords are independently generated for each reset. They are written
to a new JSON file with owner-only permissions, never to source control or command
output. Keep credentials and SQL backups under the ignored `backend/.local-demo/`
directory. No fixed demo password is included in this repository.

## Reset procedure

This deletes existing users, dog profiles, walks, orders, products, point entries,
venue profiles, feed cursors, admin logs and sessions. Breed reference data and
schema migrations remain. Account ID sequences are preserved so old tokens and
local route archives cannot become another user's data.

1. Confirm that Compose points to the intended **local** database. Stop the API
   and expiry worker so nothing writes during the reset; leave MySQL running.
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
4. Verify five users, three populated café profiles, fifteen available products,
   the owner's balance, and an empty order/walk history. Restart API and expiry.
5. Sign out of any old iOS session, then sign in with the generated credentials.
   The admin uses the web admin; the owner and cafés use the iOS app.

Database rows and private credentials are local state; a Git pull does not copy
them to teammates. Physical iPhone layout and network acceptance remain separate
from automated API and view-model tests.
