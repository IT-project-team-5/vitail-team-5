# Feature Status

Updated 8 October 2026. **Connected** means a real client/API
flow exists; it does not certify every physical-device acceptance case.
**Foundation** means data/services are prepared but the end-user feature is not
complete. Reward amounts and limits live in [Quest policy](QUESTS.md).

| Feature | Delivery | Current boundary |
|---|---|---|
| Email authentication | Connected | Owner registration; admin-created café login; authoritative role routing; shared Keychain refresh and logout |
| Login and appearance | Connected | Same-page role accordions; Debug-only backend override below the fold; persisted System/Light/Dark |
| Owner/dog profiles | Connected | Profile photos, name editing and logout; selectable social map avatar; up to 10 owner-scoped dogs; birthday-derived age with safe legacy unknown birthdays; new-owner Add Dog modal |
| Owner navigation | Connected | Account / Walk / Quest / Venues / Redeem; Friends opens from Account and Walk is the single live map; wallet/coffee estimate only in Redeem |
| Walk tracking/history | Connected; physical acceptance pending | Full map, draggable/scrollable drawer, Start/Pause/Resume/Finish, protected drafts/history and paused recovery; no tracking while terminated |
| Walking points | Connected | Explicit finish/dog confirmation, measured segmented GPS, durable retries and server receipts; no-dog records remain local with zero points |
| Compact Quest list | Connected | Available tasks only; READY first, IN_PROGRESS next, today's COLLECTED last; detail sheets and explicit collection; stale/session responses guarded |
| Birthday reward | Connected | Actual birthday qualification and once-per-dog/year credit; no invented birthdays |
| Care documents | Connected | Council expiry-based and microchip lifetime rewards per dog; default PDF/JPEG/PNG reading with confirmed fields or secondary entered details; vet visit evidence; submit reserves, Collect credits; dog-settings viewing/corrections and attachment replacement without another award; private files, immutable versions and replay safety; later spot-audit workflow remains unbuilt |
| Wallet/orders | Connected | Canonical expiring ledger; café-first menus, real prices, purchase confirmation/receipt, owner slide-to-collect and history |
| Café account/products | Connected | Own Venue details/photo/Maps, own Reward products/prices/availability; venue photo separated from account avatar; unavailable products preserve historical orders |
| Café orders | Connected | Read-only café-scoped feed, product/customer/profile-dog cards and receipt details; current profile data refreshes while open |
| Expiry/refunds/admin | Connected | Automatic due expiry/refunds; positive admin grants and repeat-safe pending-order cancellation; these controls do not constitute a full audit/dispute system |
| Venue normalization | Connected | Canonical Venue and Reward relationship; café APIs preserved; authenticated owner map exposes one configured venue per category |
| Check-in progress/collection | Connected; physical acceptance pending | Live Core Location and authenticated start/resume/location/cancel/collect APIs; Walk/Quest share progress. Server-verified dwell, attempt UUIDs, daily category uniqueness and ledger cap; no partial awards |
| Daily goals | Personalised targets and progress connected; payouts disabled | Server recommendations with owner 50–200% adjustment share Admin's effective-dated target history. Frozen daily results and seven-day goal streaks remain in Quest. Reward scope and any/all-dog qualification remain open; see [daily goals](DAILY_GOALS.md) |
| Streak rewards | Connected | Verified walking days per Melbourne date; missed-day reset; one x / milestone bar and explicit collection; each run earns 7-day then 30/60/90… rewards; earned claims survive a break |
| Friends and blocks | Connected | Search by display name/public ID, requests, removal, directional blocks, selectable map avatar and privacy controls; login email is never exposed |
| Live sessions/location/Net-Walking | Connected; physical acceptance pending; wallet rewards disabled | Walk publishes through authenticated session APIs from its existing Core Location stream. Friend and nearby-partner visibility are independent and default off; invitations grant exact partner position; server shows verified together-distance. Raw GPS has a 15-minute rolling retention worker. No reward estimate or credit is shown while policy is disabled |
| Leaderboard | Outside this delivery | No tab, endpoint or table; this team does not present it as a partial Friends feature |
| OAuth, password reset, account deletion | Later delivery | Email login remains current; social identity/account erasure flows are not complete |
| Chat, push, charity | Later delivery | Optional identity/chat/charity/push tables are not created; no working UI/API is claimed |
| Social sharing | Connected | Completed walks can render a local image card with optional date, dog names and confirmed points; route and location are excluded, and sharing uses the system sheet with no public-post database |

The 24-table core foundation includes a Walk–Dog relation and explicit
`NetWalkInvitation`, and excludes Django system tables. A migrated table is not
proof that its feature is enabled.
See [database coverage](database-design-2026-09-25/README.md),
[Walk device acceptance](WALK_TESTING.md) and [open decisions](DECISIONS.md).
