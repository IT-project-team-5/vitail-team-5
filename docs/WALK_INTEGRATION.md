# Walk + connected MVP integration

This branch adapts the existing walk-tracking implementation to main's shared
authentication, dog service, wallet, redemption and café flows. It does not
replace the reward ledger or add another wallet. OwnerHome owns one active
WalkSessionCoordinator; the older main WalkView/WalkRecorder are not mounted.

## Data and recovery

- Start/Pause/Resume/Finish and a segmented route use the original compact UI.
- New route points preserve reported accuracy and the simulated-source flag.
  Optional metadata and receipts keep version-1 history/draft JSON readable.
- Old records without measured metadata stay local-only, including restored
  mixed legacy drafts. Do not fabricate accuracy or award historical test data.
- Finish saves the route durably before an upload can begin. That record UUID
  becomes request_id. Its measured payload never changes between retries.
- Foreground entry/refresh/Finish reconcile GET /api/walks receipts by request_id
  before POST. This handles a committed request whose response was lost, even
  after relaunch. Terminal 400/409 errors are displayed on the local record;
  transport errors leave it pending. A receipt does not delete the local route.
- Receipt metadata uses the existing account/backend-scoped history store.
  Storage failures stay visible; failed writes do not erase the old archive.
- No background network worker is added. Finished records may wait offline on
  this device; server submission must still be within 12 hours of starting.
  Rejected or expired walks keep their route but do not earn points.
- Other devices show server summaries without claiming a local route exists.

## Recording and server policy

- The production coordinator enables main's basic 3 m/s speed filter and a
  maximum of 5,000 points. A jump/weak fix starts another visible segment.
  This is a sanity filter, not a guarantee of precise GPS or full anti-cheat.
- segment_id defaults to zero for older clients. New clients use consecutive
  indices. The backend validates order and never credits distance across
  segment boundaries; all previous speed/accuracy/time/cap/role checks remain.
- A new segment does not reset server inactivity. After five minutes without
  accepted movement the server stops crediting distance. The client checks
  inactivity on a timer, new batches and foreground/Resume; a manual pause of
  five minutes also ends the session on the next opportunity to run. iOS may
  suspend timers, so exact background stop timing is not promised.
- Active drafts recovered after termination remain Paused until user action.
  Missing movement cannot be recovered. Long gaps can make the remaining
  route ineligible under server inactivity/12-hour rules; local route survives.
- Explicit logout ends/saves the current walk and attempts upload before
  credentials clear. Authentication expiry instead stops capture and leaves
  a protected paused checkpoint. Neither path sends data as the next account.
- Live/local distance is an estimate. Displayed awarded points and accepted
  distance come from the server; server and local distance may differ.

## Verification

Run the complete iOS suite and `DATABASE_ENGINE=sqlite python manage.py test`
in an isolated environment. SQLite skips the MySQL-only concurrency checks;
run those separately against a disposable MySQL test database, not shared data.

Local verification on 2026-09-15: iOS Simulator 158 tests (157 passed, one
file-protection check skipped); isolated SQLite backend 96 tests (92 passed,
four database-lock checks skipped). No failures. Migration dry-run reports no
new changes; the integration adds no migration beyond main's existing ones.

Integrated regression coverage includes pause boundaries, invalid segment
indices, unchanged legacy request fingerprints, retry reconciliation after a
committed timeout, offline durable history, stopped-account isolation and old
archive decoding. Real iPhone acceptance must still cover lock screen, pause
and movement, permission changes, offline Finish, relaunch/Retry, logout,
and owner → café redemption after a walking award.

No icon assets or personal signing/server settings belong in this merge.
