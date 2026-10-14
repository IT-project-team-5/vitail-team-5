# Friends and Net-Walking

Friends and consented live location are connected end to end. The feature lives
under **Account → Friends and Net-Walking** so the owner navigation stays at five
primary destinations: Account, Walk, Quest, Venues and Redeem. **Walk is the
walk/social map and owns the sole walk/social location stream**: it records the
route, publishes allowed presence, displays friend/partner pins and hosts
Net-Walking invitations. Venues has a separate check-in discovery map. There is
no duplicate social map or leaderboard page.

## Client meeting 8 October — Net-Walking (Tony)

Show nearby friends and their dog map icons during a walk, subject to explicit
location-sharing consent. Tapping a marker opens a detail panel with the walker,
the dog information the owner chooses to share, distance when available and
friend/Net-Walking actions. Owners can customise their map dog face and bandana:
red means "My dog is reactive", yellow means "Please give space, nervous dog",
green means "Friendly", and no bandana makes no designation. These are
owner-selected handling messages, not a guarantee of temperament.

Support searching by display name or public ID, sending friend requests,
accepting/declining/cancelling requests and removing/blocking users. Keep the
owner's editable map-profile card at the top; place discovery and requests in
the add-friends page, with a red dot for pending incoming requests. Net-Walking
requires an invitation and acceptance, shows verified together-distance and can
be ended by either walker. Do not promise unapproved bonus points.

Provide a cart entry to a clothing shop for hats, bandana patterns and extra
decorations. Changing a pattern must preserve the bandana's colour and message.
Purchased items can be worn, switched or removed without buying them again.

Implementation decisions confirmed on 14 October: the owner explicitly selects
one public dog (name, breed, age and size only); all other dog information stays
private. The shop uses real server-backed pt, not the old Demo wallet. Initial
catalogue prices (15–70 pt) are retained from the prototype with Tony's approval
on 14 October; they are not a separately confirmed client pricing policy.
No existing Demo points or clothes are imported. The
old Demo's 2/8-row list and distance-based marker styling are UX refinements,
not evidence of an additional client requirement. The five-tab navigation change
is tracked separately from this feature.

## Owner flow

Friends supports display-name or 32-character public-ID search, incoming and
outgoing requests, accepted friends, removal and directional blocking. Login
email is never a social identifier. Removing a friend removes friend-based map
access. Blocking hides both users from discovery, removes friendship and ends
open pairing; unblocking does not restore any of those states.

The owner can use their profile photo or choose one of the supported virtual map
avatars: walker, paw, dog or coffee. The selected key is part of the public
social profile and is used consistently in friend rows and Walk map pins.

The Friends page starts with the owner's own map-profile card. Its Edit map
profile page saves the appearance explicitly to the authenticated owner's
server preferences, rather than storing it only on the phone. The dog option
offers eight dog faces and a cat easter egg. A bandana has four choices: red
("My dog is reactive"), yellow ("Please give space, nervous dog"), green
("Friendly"), or no bandana (no designation). This is owner-selected handling
guidance, not an assessment or a guarantee about the animal. Friends and map
details show the same guidance. Older profiles without these new fields use the
default face and no bandana; unknown colours never imply friendliness.

Appearance saves do not opt into location sharing or Net-Walking. A failed or
unconfirmed save keeps the selection available for retry and does not claim it
was saved. As with other preference failures, this device's location sharing
stays paused until the server confirms the retry. Apply the account migration
before using the new appearance fields. This feature includes no Demo balance,
venue rewards or changes to navigation order.
The appearance editor sends only the three appearance fields. In particular it
does not replay consent from a cached overview: another device may have changed
privacy settings since this phone last refreshed. Appearance retries preserve
the same partial PATCH and adopt the server's current privacy settings.

The editor also offers an optional public dog selection, hidden by default.
Saving a selection publishes only name, breed, derived age and size in social
profiles, including search and map details. It is not an assertion that the dog
is participating in the current walk: walking dog selection still happens when
the completed walk is saved. No public dog ID, exact birthday, microchip,
documents, health data or other owner dogs are returned. Clearing selection
immediately hides the summary. Transfer, archive and deletion suppress it too.
An appearance-only save leaves an untouched public-dog selection unchanged,
including when another device has withdrawn it.

## Clothing shop

The cart in **Friends → You on the map → Clothing shop** loads the server
catalogue, the same unexpired-pt balance used by Redeem, owned items and the
current outfit. It does not create a second wallet or award sample points.
Buying requires explicit confirmation; the server controls the price and
atomically spends pt and grants permanent ownership. A purchase does not
automatically equip its item. Wear changes one category; removing clothing or
restoring the classic bandana pattern is free and preserves ownership.

Purchase UUIDs are owner-scoped and persist across same-device ambiguous retries.
Replaying the same purchase or buying an already-owned item cannot debit twice;
using a UUID for another item returns 409. Lost responses retain the UUID until
retry or an authoritative wardrobe read confirms ownership. Definite rejection
does not trap the shop in an unresolved purchase. Insufficient or expired points
create neither ownership nor a spend entry. Purchases and worn outfits sync
across devices, and public map profiles contain only worn outfit enums, never
balance, purchase history or the wardrobe inventory. Outfit changes never alter
bandana colour, public dog choice or location consent.

Apply account migration `0007_user_public_dog` and social migration
`0005_avatar_shop` before deploying this client. Old clients ignore the new
profile fields; newer clients display hidden dog/plain clothing fallbacks when
those fields are absent, but need the updated server to save/buy. These changes
have been validated locally; physical-phone acceptance is still pending.

Local validation on 14 October: the full iOS suite passed 404 tests with one
existing simulator device-lock check skipped, and the additional clothing
snapshot test passed across light/dark and large-text variants. The MySQL
social/rewards/Demo-reset suite passed all 175 tests, including shop concurrency.
The full SQLite backend suite ran 517 tests: 481 passed, 35 MySQL-only checks were
skipped, and the existing Quest debug-reset idempotency test errored. The same
error was reproduced on unchanged main; it is not evidence of a new shop failure.
Migration drift and build checks passed. These results do not replace the
physical-phone acceptance steps below.

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
  `net_matching_enabled`, `virtual_avatar_key`, `dog_avatar_breed` and
  `bandana_color`, plus optional nullable `public_dog_id`. Omitted fields remain
  unchanged; `public_dog_id: null` removes the public summary. Breeds are
  `goldenRetriever|corgi|husky|dalmatian|beagle|shiba|poodle|dachshund|cat`;
  bandanas are `none|red|yellow|green`.
- `GET /avatar-shop` returns server products, real balance, owned product codes
  and the current outfit. No Demo values are injected.
- `POST /avatar-shop/purchases {product_code, request_id}` atomically purchases
  with a UUID idempotency key. Prices come from the server catalogue.
- `PATCH /avatar-shop/outfit {category, product_code}` wears an owned matching
  category item; a null product code removes it. Categories are
  `hats|bandanas|extras`.
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
`photo_url`, `avatar_key`, `dog_avatar_breed`, `bandana_color`, optional `dog`
summary and `avatar_outfit`. Only own preferences include `public_dog_id`.
Bonus estimates, bonus status and raw sample data
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
8. On one phone choose Dog, a face and each bandana; save, reopen and refresh the
   other phone's Friends/Walk details. Verify the same appearance and exact
   guidance, including no designation for no bandana. Reject unknown API values.
   Disconnect while saving, retry after reconnecting, and verify no success is
   claimed before confirmation. Neither appearance editing nor its retry may
   silently enable location sharing. Physical two-phone results remain pending.
9. Choose a public dog, save, refresh the other phone's search/friend/map detail
   and check the four-field summary. Clear it and verify an open detail updates;
   archive/transfer/delete must suppress it. Check that other dogs and private
   fields never appear and a cosmetic face does not change the actual breed.
10. With an isolated test account's real balance, buy each clothing category,
    choose Wear, reopen on both phones and check matching map pins. Retry after
    a lost response, repeat Buy, spend from another device and try insufficient
    funds. Verify one ledger debit per owned product, consistent balance, free
    outfit switching/removal and unchanged red/yellow/green/none semantics.

Simulator and automated results do not certify locked-phone GPS, real field
accuracy, production-scale concurrency or approval of the candidate point rule.
