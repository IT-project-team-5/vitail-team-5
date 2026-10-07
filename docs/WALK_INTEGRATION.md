# Walk + connected MVP integration

The active map flow shares authentication, dogs, the canonical wallet, redemption
and café services. It is also the only live social map: friend, nearby-partner
and active-partner pins use each owner's selected profile/map avatar. OwnerHome
owns one WalkSessionCoordinator. The unreachable
legacy WalkView/WalkViewModel/WalkRecorder stack has been removed; recording and
recovery use the coordinator, tracker, location, draft, history and sync stores.

## Finish confirmation

The map now fills the Walk page with a draggable bottom menu. Start does not
choose dogs. Pause exposes Resume and Finish; Finish creates a protected pending
summary outside uploadable history. The owner selects participants and confirms
completion before it can earn points. No dogs saves a local zero-point record.
Pending confirmation survives relaunch and can be reopened with Review walk.
Automatic stops/logout save this pending state without choosing dogs or awarding
points. Earlier confirmed finished archives keep their retry behavior.

## Data and recovery

- The map extends behind the bottom menu. Idle exposes Start, Walking exposes
  Pause, and Paused exposes Resume/Finish. Expand the menu for local history,
  upload status and walking information. No pre-start dog choice is required.
- New route points preserve reported accuracy and the simulated-source flag.
  Optional metadata and receipts keep version-1 history/draft JSON readable.
- Old records without measured metadata stay local-only, including restored
  mixed legacy drafts. Do not fabricate accuracy or award historical test data.
- Pause → Finish stops capture and checkpoints a summary with
  `requiresDogConfirmation: true`, outside uploadable history. The owner chooses
  dogs and taps Complete walk before the record can become uploadable. Later
  dismisses it; Review walk reopens it. A new Start is blocked until the finished
  record has been confirmed and safely saved.
- Confirming with no dogs saves local history with zero points. Its upload request
  is deliberately absent. It cannot earn points through a later refresh or retry.
- Confirmation freezes participants and measured samples under the existing
  record UUID, which becomes request_id. The immutable request is reused across
  retries. The summary shows estimated points before confirmation, pending status
  while awaiting a receipt, and actual points after the server accepts it.
- Foreground entry/refresh and confirmed completion reconcile GET /api/walks
  receipts by request_id before POST. Only durably saved, confirmed, eligible
  records participate; an unconfirmed summary is never included. Reconciliation
  handles a committed request whose response was lost, even after relaunch.
  Terminal 400/409 errors are displayed on the local record; transport errors
  leave it pending. A receipt does not delete the local route.
- Relaunch restores an active checkpoint as Paused and a finished unconfirmed
  checkpoint as its pending summary. The optional confirmation marker preserves
  compatibility: pre-update finished archives were already confirmed and retain
  their retry behavior. A crash between saving history and clearing its draft
  reuses the same record rather than duplicating it.
- Receipt metadata uses the existing account/backend-scoped history store.
  Storage failures stay visible; failed writes do not erase the old archive.
- Confirming completion during an existing upload queues another reconciliation
  pass. Explicit logout checkpoints a current walk for later dog confirmation;
  it may reconcile previously confirmed records before clearing credentials.
  Logout does not confirm its newly ended walk. Changing tabs does not cancel a
  durable upload. Account shutdown cancels synchronization and ignores late
  responses. Terminal 400/409 errors remain recorded even without server text.
- No background network worker is added. Confirmed eligible records may wait
  offline on this device; server submission must still be within 12 hours of
  starting. Waiting in the summary does not extend the submission window.
  Rejected or expired walks keep their route but do not earn points.
- Other devices show server summaries without claiming a local route exists.

## Recording and server policy

- The production coordinator enables a basic 3 m/s speed filter and a
  maximum of 5,000 GPS samples. A jump/weak fix starts another visible segment.
  This is a sanity filter, not a guarantee of precise GPS or full anti-cheat.
- segment_id defaults to zero for older clients. New clients use consecutive
  indices. The backend validates order and never credits distance across
  segment boundaries; all previous speed/accuracy/time/cap/role checks remain.
- A new segment does not reset server inactivity. After five minutes without
  accepted movement the server stops crediting distance. The client checks
  inactivity on a timer, new batches and foreground/Resume; a manual pause of
  five minutes also ends the session on the next opportunity to run. iOS may
  suspend timers, so exact background stop timing is not promised.
- Active drafts recovered after termination restore as Paused and retain their
  original inactivity window. Expired active drafts stop into a pending summary
  on the next inactivity check; Resume does not restart that window. Automatic
  stops (including the sample limit) never choose dogs or confirm an award.
  Missing movement cannot be recovered. Long gaps can make the remaining route ineligible under server
  inactivity/12-hour rules; the local route survives.
- Explicit logout ends/saves the current walk for later dog confirmation. It
  may retry previously confirmed records before credentials clear.
  Authentication expiry instead stops active capture and leaves a protected
  paused checkpoint; an already pending summary remains unconfirmed. Neither
  path sends data as the next account.
- Live/local distance and pre-confirmation points are estimates. Actual awarded
  points and accepted distance come from the server and may differ. The estimate
  uses known walking receipts and the walking cap; the server also applies the
  shared walking/check-in activity cap. The local estimate may therefore exceed
  the final award if another activity consumed allowance. Multiple dogs do not
  multiply points. [Quest policy](QUESTS.md) is the canonical rate/cap reference;
  the coffee comparison never changes walking earnings or menu prices.

The completed-walk API stores validated summaries, not raw routes. Its stable
request UUID also links the authenticated social `WalkSession`. During recording,
the coordinator may send the same fresh Core Location fixes to that separate
social endpoint; Friends never starts a second location manager. Ordinary walk
uploads do not populate social samples.

Friend sharing and nearby Net-Walking discovery are independent and off by
default. Friends may receive an exact fresh position only when sharing is on;
other opted-in walkers receive an approximate position until both people accept
an invitation. Pause, finish, logout, blocking or withdrawing matching clears
presence and ends the pairing. The server derives together-distance from
overlapping plausible samples and returns the verified distance only. Net-Walk
wallet points and estimates remain hidden while the feature flag is off.

Presence expires after 30 seconds. Raw social GPS is retained in a rolling
15-minute verification buffer and deleted on pause/finish, with the
`social_presence` worker sweeping at least once a minute. Summary intervals keep
distance/time without exposing a route. Broader completed-route and account
erasure policy remains an open decision. See [Friends and Net-Walking](SOCIAL.md).

## Verification

Run the complete iOS suite and `make test` from the repository root, or
`DATABASE_ENGINE=sqlite python manage.py test` from `backend/` in an isolated
environment. SQLite skips the MySQL-only concurrency checks;
run those separately against a disposable MySQL test database, not shared data.

### Current regression and device acceptance scope

Regression coverage includes pause boundaries, invalid segment indices,
unchanged legacy request fingerprints, retry reconciliation after a committed
timeout, offline durable history, stopped-account isolation and old archive
decoding. The confirmation flow adds checks for starting without dogs, a durable
unconfirmed summary after Finish/relaunch/logout/automatic stop, zero-dog local
completion, exactly-once submission after choosing dogs, and daily-cap estimates.
Map and summary snapshots cover the new controls and light/dark appearances.
Social tests cover default-off privacy, friendship/block permissions, stale
presence, invitations, exact versus approximate map positions and repeat-safe
together-distance. They do not certify field GPS accuracy.

Real iPhone acceptance still needs lock-screen capture, paused movement,
permission changes, active recovery, pending-summary recovery, offline confirmed
completion/retry, logout without an award, and zero-dog completion. A connected
happy path is Start → Pause → Finish → choose dogs → Complete walk → inspect
receipt and Redeem balance → purchase → collect. Follow `WALK_TESTING.md` and
record the current build/device results without treating simulator tests as
physical GPS acceptance.

Social field acceptance additionally requires two real owner accounts and two
iPhones: verify default-off invisibility, friend-only sharing, nearby discovery,
invitation consent, partner position, together-distance, background behavior and
prompt disappearance after pause/finish/disable/block/network loss.

Personal signing/server settings and real route exports remain outside the
repository.
