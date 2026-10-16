# Local pilot operations and recovery

The [handover record](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/39911425)
owns the agreed delivery mode, recipient, dates, accounts and acceptance evidence.
This runbook covers the existing Docker-based local pilot. A final hosted service
or iOS distribution method still requires a client decision.

## Start and stop

Use the repository README on a clean checkout. Record its commit, Docker version,
Python packages and Xcode/iOS versions. Start Docker Desktop, then run `make up`.
Compose starts MySQL, applies migrations, serves the API and starts both workers:
`expire_rewards` refunds expired orders and expires points; `purge_social_presence`
removes stale social positions. Check `docker compose ps` and service logs.

The simulator uses the Mac's API; a phone needs the reachable LAN address and
local signing settings. Public photos and private originals are stored under
`backend/media` and `backend/private_uploads`; MySQL uses the Compose volume.
`make down` stops services without deleting that volume. Do not add `-v` when
stopping a database you need to retain.

Compose uses development defaults and Django's development server. Before any
public deployment, agree actual HTTPS, application server, public media serving,
private-file access, secrets, allowed hosts, database access and maintenance.
Do not expose the local default database/password setup as a production service.

## Consistent backup

Choose a maintenance window and keep backups private. Stop the API and both
workers before capturing files and database together; otherwise an upload or
point change can occur between the two copies. These commands are for the
explicitly selected local project:

```bash
umask 077
backup_dir="$PWD/backend/.local-demo/backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"
git rev-parse HEAD > "$backup_dir/source-sha.txt"
docker compose stop api expiry social_presence
docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot --single-transaction --routines --triggers --events --set-gtid-purged=OFF --no-tablespaces --column-statistics=0 "$MYSQL_DATABASE"' > "$backup_dir/database.sql"
tar -cpf "$backup_dir/files.tar" -C backend media private_uploads
shasum -a 256 "$backup_dir/database.sql" "$backup_dir/files.tar" > "$backup_dir/SHA256SUMS"
docker compose up -d api expiry social_presence
```

Check each command succeeds before continuing. If either upload directory does
not yet exist, record that it is empty and archive only the existing directory.
If a backup step fails, keep the error and restore service deliberately; do not
label the partial backup usable. Record the source, time, environment and hashes.
Store secrets separately through the agreed secure handover channel. Backups and
private documents do not belong in public GitHub or publicly shared evidence.

## Restore into a separate rehearsal environment

Never test a restore over the only working database. Use another checkout at the
saved source SHA, a distinct Compose project such as `vitail-restore`, and free
host ports through `API_PORT` and `MYSQL_PORT_EXTERNAL` in that checkout's `.env`.
Keep the same database name or deliberately adjust the restore command. Use new
local-only credentials and set the intended feature flags explicitly.

1. Start only the new database: `docker compose -p vitail-restore up -d db`.
2. Verify backup hashes. Restore the SQL into that new database with
   `docker compose -p vitail-restore exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot "$MYSQL_DATABASE"' < /private/path/database.sql`.
3. Extract the saved `media` and `private_uploads` under the new checkout's
   `backend`. Preserve private file/directory permissions (600/700), and never
   mount private originals as public media.
4. Start that project's API and workers. Check migrations and logs. Compare
   selected account/dog IDs, balances, pending orders, image/document hashes and
   original permission boundaries with the recorded pre-backup values.
5. Log in as owner and cafe. Verify the same pending order and wallet balance.
   Confirm the document owner can download the original; an anonymous or other
   owner request must be denied, and its path must not resolve as public media.
6. Restart the restored API and repeat the connected check. In synthetic data,
   exercise overdue-order refunds and stale-GPS cleanup; repeat the worker sweep
   to verify it does not refund twice.

Record elapsed recovery time as an observation, not an unagreed service promise.
An automated synthetic rehearsal supports recovery confidence; a recipient must
still try the agreed installation and operating instructions before handover.
Keep production data, signing, hosting, costs and support ownership explicit.
