# Friends and Net-Walking

SCRUM-47 / Tony Su. Built on main `660149a` without bundling the unmerged
daily-goal PR. Confluence's 25 September **New Features Listings** and the
24 September client meeting require discovery, friends, consented positions
and two-person walking without a friendship prerequisite. Chat is still an
iteration decision, not delivered here.

## Available flow

Friends shows your public ID, name/ID search, incoming and outgoing requests,
accepted friends and blocks. Only minimal public profile fields are returned;
login email is never used as the public identifier. Removing a friend removes
friend-based position access. Blocking hides both users from discovery and
ends their pairing; unblocking does not restore friendship or consent.

Two independent switches are off by default:

- **Share walk location with friends:** accepted friends may see your fresh
  position only during recording.
- **Find Net-Walking partners:** other opted-in, actively walking users nearby
  see an approximate position. A separately accepted invitation allows exact
  partner positions. Becoming friends is not required or sufficient.

The existing walk coordinator supplies GPS; there is no second location manager.
Pause, finish, logout or turning both channels off stops publishing. Pausing
or withdrawing Net-Walking ends the pairing; resume requires a new invitation.
Offline/unavailable positions expire and must not remain as live markers.

Together-distance is verified on the server from overlapping plausible GPS
segments after acceptance. GPS gaps, inaccurate/simulated readings and excessive
speed do not earn distance. Only one open pairing is allowed per person and
previously counted time cannot be counted twice. Normal completed-walk upload
links the session by its existing stable UUID; no second wallet is introduced.

## Policy and privacy boundary

`NET_WALK_REWARDS_ENABLED` defaults to **false**. The app shows verified
together-distance and **estimated**, not credited, points. The documented
proposal is an extra 2 points/km, rounded down, at most 10/day. Client documents
do not settle its membership in the combined 72-point activity cap. If explicitly
enabled after approval, this implementation conservatively counts walking,
check-in, daily-goal and Net-Walking against 72; confirm that policy before
enabling. A disabled settlement is final and retrying an old upload will not
retroactively credit it.

Implementation parameters requiring product/device review:

- Fresh presence: 30 seconds; iOS publishes at most every 5 seconds and uses
  server `expires_at` when removing pins.
- Server ingestion: at least 1 second between new readings and at most 180
  retained samples per session. Rate-limited readings return 429 and interrupt
  sharing/matching rather than bridging a suppressed location.
- Nearby discovery: 2 km; coordinates rounded to 3 decimals and distance to
  100 m. This is approximate, not anonymised location.
- Together proximity: 50 m at both ends of overlapping walking segments.
- Invitation expiry: 2 minutes; unavailable/pause/invalid-GPS ends consent.
- Accuracy: at most 30 m; speed: at most 3 m/s; segment gap: at most 60 seconds,
  using existing walking checks. There is no invented minimum reward duration.
- Raw GPS: rolling 15-minute verification buffer, deleted on pause/finish.
  At-rest cleanup may lag by one sweep (up to a minute). Summary intervals
  store distance/time, never a returned route.

Compose includes a social-presence worker running
`python manage.py purge_social_presence --watch --interval 60`. Other deployments
must schedule the same sweep at least once a minute. Reads already reject stale
presence, but the worker is necessary for at-rest cleanup when traffic stops. Australian-region hosting
and a full account-erasure policy remain deployment/product work.

## API

All `/api/social` routes require an authenticated OWNER and use no trailing
slash. Public IDs are existing 32-character hex IDs. No route exposes raw GPS
history. `409 SOCIAL_CONFLICT` denotes an invalid state or conflicting pairing;
`400` denotes validation failure, `404` an unavailable/non-authorised resource.

- `GET overview`, `GET users?q=…` (2–100 characters, at most 20 profiles).
- `POST friend-requests {public_id}`;
  `POST friend-requests/{id}/respond {accept}`;
  `POST friends/{public_id}/remove {}`.
- `POST blocks {public_id}`; `POST blocks/{public_id}/remove {}`.
- `PATCH preferences {location_visibility: OFF|FRIENDS, net_matching_enabled}`.
- `GET map` returns `{friends, nearby, partner}` with `recorded_at`,
  `expires_at`, `is_approximate` and `is_net_partner` on each peer.
- `POST walk-sessions {request_id, started_at}`;
  `GET walk-sessions/current`;
  `POST walk-sessions/{id}/state {state: RECORDING|PAUSED|FINISHED|CANCELLED}`.
- `POST walk-sessions/{id}/location {latitude, longitude, accuracy_m,
  recorded_at, is_simulated}` returns the live session. Invalid GPS clears
  presence, ends pairing and returns a validation error rather than a position.
- `GET net-walk-invitations` returns `{incoming, outgoing, active}`;
  `POST net-walk-invitations {public_id}`;
  `POST net-walk-invitations/{id}/respond {accept}`;
  `POST net-walk-invitations/{id}/end {}`.

Live session feedback includes `shared_distance_m`, `estimated_bonus_points`,
`bonus_points` and `bonus_status` (`awaiting_rules`, `provisional`, `settled`).
Only `bonus_points` represents a credited wallet award.

## Acceptance before release

Run backend tests plus Django checks/migration drift, and the Vitail iOS suite.
Use two physical iPhones/accounts on one reachable backend for these cases:

1. Search/copy public ID; send, decline/re-send, accept, cancel and remove requests.
2. Start both walks with both switches off: neither position appears.
3. Accept friendship and enable friend sharing: only that friend sees the exact
   fresh position; a third non-friend cannot.
4. Enable Net-Walking on both, including two non-friends: approximate discovery,
   invitation and explicit acceptance, then exact partner position and verified
   together-distance while walking side by side. No wallet credit by default.
5. Pause, finish, block, disable matching, lose GPS/network or sign out: marker
   expires/clears and no gap is counted. Reconnect after five minutes using the
   same ongoing local walk; fresh consent/readings are required.
6. Lock both screens during an outdoor walk and verify background GPS feeding,
   battery behaviour, expiry and stop controls. Simulator points cannot earn.
7. Finish/confirm dogs and retry upload: the normal walk and optional bonus are
   each repeat-safe. Test real MySQL concurrency on an isolated test database.

Automated tests do not certify locked-phone GPS, field accuracy, production-scale
concurrency or product approval of the provisional parameters.

## Verification — 7 October

- Complete backend suite on isolated MySQL 8.4: **374 passed**, including real
  concurrent endings, ending versus matching withdrawal and maintenance expiry.
- Complete SQLite suite: 374 tests, 23 MySQL-only skips, no failures.
- Complete iOS simulator suite: 337 passed, one file-protection check skipped;
  build and API specification validation passed.
- Independent simulator connected to the real local API: default-off privacy,
  public-ID display, search, request, cancellation and acceptance, independent
  row actions and empty-map/Net-Walking states checked with fictional accounts.
- The MySQL run exposed mutable foreign-key-support-index deadlocks; migration
  0003 replaces them with stable indexes. Both fresh migration and upgrading the
  isolated local database were verified. No production/user database was reset.

The isolated review backend is `http://127.0.0.1:18017`; choose it through the
Debug login-page backend setting. The app otherwise defaults to port 8000,
which may still run another checkout. All policy and physical-device limits
above remain; passing tests is not a claim that the whole team backlog is done.
