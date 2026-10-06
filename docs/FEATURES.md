# Feature Status

Updated 4 October 2026. **Connected** means a real client/API
flow exists; it does not certify every physical-device acceptance case.
**Foundation** means data/services are prepared but the end-user feature is not
complete. Reward amounts and limits live in [Quest policy](QUESTS.md).

| Feature | Delivery | Current boundary |
|---|---|---|
| Email authentication | Connected | Owner registration; admin-created café login; authoritative role routing; shared Keychain refresh and logout |
| Login and appearance | Connected | Same-page role accordions; Debug-only backend override below the fold; persisted System/Light/Dark |
| Owner/dog profiles | Connected | Profile photos, name editing and logout; up to 10 owner-scoped dogs; birthday-derived age with safe legacy unknown birthdays; new-owner Add Dog modal |
| Owner navigation | Connected | Account / Walk / Quest / Redeem; Vitail title; wallet/coffee estimate only in Redeem |
| Walk tracking/history | Connected; physical acceptance pending | Full map, draggable/scrollable drawer, Start/Pause/Resume/Finish, protected drafts/history and paused recovery; no tracking while terminated |
| Walking points | Connected | Explicit finish/dog confirmation, measured segmented GPS, durable retries and server receipts; no-dog records remain local with zero points |
| Compact Quest list | Connected | Available tasks only; READY first, IN_PROGRESS next, today's COLLECTED last; detail sheets and explicit collection; stale/session responses guarded |
| Birthday reward | Connected | Actual birthday qualification and once-per-dog/year credit; no invented birthdays |
| Care documents | Connected | Council expiry-based and microchip lifetime rewards per dog; default PDF/JPEG/PNG reading with confirmed fields or secondary entered details; vet visit evidence; submit reserves, Collect credits; dog-settings viewing/corrections and attachment replacement without another award; private files, immutable versions and replay safety; later spot-audit workflow remains unbuilt |
| Wallet/orders | Connected | Canonical expiring ledger; café-first menus, real prices, purchase confirmation/receipt, owner slide-to-collect and history |
| Café account/products | Connected | Own Venue details/photo/Maps, own Reward products/prices/availability; venue photo separated from account avatar; unavailable products preserve historical orders |
| Café orders | Connected | Read-only café-scoped feed, product/customer/profile-dog cards and receipt details; current profile data refreshes while open |
| Expiry/refunds/admin | Connected | Automatic due expiry/refunds; positive admin grants and repeat-safe pending-order cancellation; these controls do not constitute a full audit/dispute system |
| Venue normalization | Foundation plus existing café integration | Canonical Venue and Reward relationship; café APIs preserved. Public discovery/start-check-in flow is not delivered |
| Check-in progress/collection | Foundation; provider pending | Persisted service and one shared iOS map/Quest store; no public GPS ingestion or enabled iOS provider. Verified qualification required; shared daily cap, no partial awards |
| Daily goals | Personalised targets and progress connected; payouts disabled | Server recommendations with owner 50–200% adjustment share Admin's effective-dated target history. Frozen daily results and seven-day goal streaks remain in Quest. Reward scope and any/all-dog qualification remain open; see [daily goals](DAILY_GOALS.md) |
| Streak rewards | Connected | Verified walking days per Melbourne date; missed-day reset; one x / milestone bar and explicit collection; each run earns 7-day then 30/60/90… rewards; earned claims survive a break |
| Live sessions/location/net-walk | Foundation | Session, bounded sample and interval schema; no live location API, peer matcher or net-walk award |
| Friends/blocks/leaderboard | Foundation / teammate integration | Friendship/block schema only; no social API or working leaderboard tab/endpoint in this app |
| OAuth, password reset, account deletion | Later delivery | Email login remains current; social identity/account erasure flows are not complete |
| Chat, push, charity | Later delivery | Optional identity/chat/charity/push tables are not created; no working UI/API is claimed |
| Social sharing | Connected | Completed walks can render a local image card with optional date, dog names and confirmed points; route and location are excluded, and sharing uses the system sheet with no public-post database |

The 22-table core foundation includes a Walk–Dog relation and excludes Django
system tables. A migrated table is not proof that its feature is enabled.
See [database coverage](database-design-2026-09-25/README.md),
[Walk device acceptance](WALK_TESTING.md) and [open decisions](DECISIONS.md).
