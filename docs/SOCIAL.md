# Friends and Net-Walking

Friends and consented live location are connected end to end. The feature lives
under **Account → Friends and Net-Walking** so the owner navigation stays at four
primary destinations: Account, Walk, Quest and Redeem. **Walk is the
walk/social map and owns the sole walk/social location stream**: it records the
route, publishes allowed presence, displays friend/partner pins and hosts
Net-Walking invitations and venue discovery/check-ins using the same location
stream. There is
no duplicate social map or leaderboard page.

## Owner flow

Friends supports display-name or 32-character public-ID search, incoming and
outgoing requests, accepted friends, removal and directional blocking. Login
email is never a social identifier. Removing a friend removes friend-based map
access. Blocking hides both users from discovery, removes friendship and ends
open pairing; unblocking does not restore any of those states.

The owner can use their profile photo or choose one of the supported virtual map
avatars: walker, paw, dog or coffee. The selected key is part of the public
social profile and is used consistently in friend rows and Walk map pins.

Two independent controls default **off**:

- **Share walk location with friends:** an accepted friend may see an exact fresh
  position while both the walk and sharing are active.
- **Find Net-Walking partners:** another opted-in active walker within the nearby
  radius may see an approximate position. An explicit invitation and acceptance
  is required before either side receives the exact partner position.

Friendship never implies location consent or Net-Walking consent. Becoming
friends is not required for a Net-Walking invitation. Pause, finish, logout,
blocking, disabling the applicable control, invalid GPS or an expired presence
removes the marker and ends any active pairing. Resume requires fresh readings
and, after a pairing ends, a new invitation.

The existing `WalkSessionCoordinator` supplies GPS to the social session; there
is no second location manager. Server-verified together-distance is shown while
an accepted pairing is active. The social API and UI expose no estimated or
unapproved point value.

## Verification and privacy

The server derives together-distance from overlapping plausible GPS segments
after acceptance. GPS gaps, inaccurate or simulated readings, excessive speed
and time before consent do not count. One person can have only one active pairing,
and a reading/interval cannot be counted twice. The normal completed-walk upload
links the social session through the same stable walk UUID.

Operational limits:

- Fresh presence: 30 seconds. iOS publishes at most every 5 seconds and removes
  pins according to server `expires_at`.
- Ingestion: at least 1 second between accepted readings and at most 180 retained
  samples per session. A rate-limited reading returns 429 instead of extending a
  hidden gap.
- Nearby discovery: 2 km. A dateline- and pole-safe database bounding box and a
  200-candidate ceiling run before exact distance checks; at most 50 matches are
  returned. Coordinates are rounded to 3 decimals and distance to 100 m until
  invitation acceptance. Approximation reduces precision; it does not make a
  position anonymous.
- Together proximity: 50 m at both ends of each overlapping segment.
- Invitation lifetime: 2 minutes.
- Accepted accuracy: at most 30 m; speed: at most 3 m/s; segment gap: at most
  60 seconds.
- Raw social GPS: rolling 15-minute verification buffer. Samples are deleted on
  pause/finish and by a periodic sweep; persisted interval summaries contain
  distance/time, never a returned route.

Compose runs `python manage.py purge_social_presence --watch --interval 60` as
the `social_presence` service. Every deployment must schedule the same sweep at
least once a minute. API reads reject stale presence even before the next sweep.
Australian-region hosting and broader account-erasure rules remain deployment
work; the short social retention policy does not settle retention for completed
local routes, evidence or financial history.

## Point boundary

`NET_WALK_REWARDS_ENABLED` defaults to **false**. In that state the backend saves
verified together-distance on the completed walk, finalises the decision and
creates no Net-Walk ledger entry. Replaying the walk after a later configuration
change cannot retroactively award it.

The guarded settlement code exists for an explicitly approved rollout. Its
current candidate is 2 points per whole kilometre, at most 10 per Melbourne day,
inside the shared 72-point activity cap. That candidate is not a client-facing
promise: the UI/API expose only verified distance while the flag is off. Enable
it only after the rate and cap membership are formally accepted and field tests
pass.

## HTTP contract

All `/api/social` routes require an authenticated active OWNER, accept no
trailing slash and return `Cache-Control: private, no-store`. `409
SOCIAL_CONFLICT` denotes a conflicting state or pairing; `400` denotes invalid
input; `404` hides unavailable or unauthorised resources. No route exposes raw
GPS history.

- `GET /overview` returns the current public profile/preferences, relationships,
  blocks and active session.
- `GET /users?q=…` searches 2–100 characters and returns at most 20 profiles.
- `POST /friend-requests {public_id}`;
  `POST /friend-requests/{id}/respond {accept}`;
  `POST /friends/{public_id}/remove {}`.
- `POST /blocks {public_id}`; `POST /blocks/{public_id}/remove {}`.
- `PATCH /preferences` accepts `location_visibility: OFF|FRIENDS`,
  `net_matching_enabled` and `virtual_avatar_key`.
- `GET /map` returns `{friends, nearby, partner}`. Each peer has a public profile,
  coordinates, `recorded_at`, `expires_at`, `is_approximate` and
  `is_net_partner`.
- `POST /walk-sessions {request_id, started_at}`;
  `GET /walk-sessions/current`;
  `POST /walk-sessions/{id}/state {state}`.
- `POST /walk-sessions/{id}/location` accepts latitude, longitude, accuracy,
  recorded time and simulated-source flag. Invalid GPS clears presence and ends
  pairing rather than returning a usable marker.
- `GET /net-walk-invitations` returns incoming, outgoing and active rows;
  `POST /net-walk-invitations {public_id}`;
  `POST /net-walk-invitations/{id}/respond {accept}`;
  `POST /net-walk-invitations/{id}/end {}`.

A live session returns `id`, `request_id`, `state`, `net_consent` and
`shared_distance_m`. Public profiles return `public_id`, `display_name`,
`photo_url` and `avatar_key`. Bonus estimates, bonus status and raw sample data
are intentionally absent.

## Release acceptance

Run the backend checks, migration-drift check, complete backend suite and complete
iOS suite from the current checkout. Automated tests cover permissions,
relationship transitions, default-off preferences, stale-presence rejection,
invitation conflicts, interval deduplication, retention and repeat-safe walk
linking. MySQL remains necessary for real locking/concurrency coverage.

Before release, use two owner accounts and two physical iPhones on one reachable
backend to verify:

1. Search/copy public IDs; send, decline, repeat, accept, cancel, remove and block.
2. Start both walks with both controls off; neither position appears.
3. Enable friend sharing; only accepted friends receive the exact fresh pin.
4. Enable partner discovery for two non-friends; verify approximate discovery,
   invitation, acceptance, exact partner pin and together-distance.
5. Pause, finish, disable, block, lose GPS/network and sign out; verify pins and
   pairing disappear and gaps do not earn distance.
6. Lock both screens during an outdoor walk; verify background delivery, battery
   behavior, expiry and stop controls.
7. Finish, choose dogs and retry the completed-walk upload; verify one base walk,
   one saved together-distance result and no Net-Walk wallet credit by default.

Simulator and automated results do not certify locked-phone GPS, real field
accuracy, production-scale concurrency or approval of the candidate point rule.
