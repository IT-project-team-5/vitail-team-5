# Feature Status

Updated 14 October 2026. **Connected** means a real client/API
flow exists; it does not certify every physical-device acceptance case.
**Foundation** means data/services are prepared but the end-user feature is not
complete. Reward amounts and limits live in [Quest policy](QUESTS.md).
We completed real-phone testing for the merged PRs 13–15. We record integrated
checks and client acceptance separately; see [acceptance evidence](INTEGRATION.md).

| Feature | Delivery | Current boundary |
|---|---|---|
| Email authentication | Connected | Owner registration; admin-created café login; authoritative role routing; shared Keychain refresh and logout |
| Login and appearance | Connected | Same-page role accordions; Debug-only backend override below the fold; persisted System/Light/Dark |
| Owner/dog profiles | Connected | Profile photos, name editing and logout; selectable social map avatar; up to two owner-scoped dogs; required new-profile weight and derived internal size; guided resumable onboarding; birthday-derived age with legacy preservation |
| Owner navigation | Connected | Redeem / Quest / Walk / Friends / Account; Walk owns the walk/social/venue map and its sole location stream; Quest and Redeem use the current wallet balance |
| Walk tracking/history | Connected; acceptance recorded separately | Full map, draggable/scrollable drawer, Start/Pause/Resume/Finish, protected drafts/history and paused recovery; no tracking while terminated |
| Walking points | Connected | Explicit finish/dog confirmation, measured segmented GPS, durable retries and server receipts; no-dog records remain local with zero points |
| Compact Quest list | Connected | Available tasks only; READY first, IN_PROGRESS next, today's COLLECTED last; detail sheets and explicit collection; stale/session responses guarded |
| Birthday reward | Connected | Actual birthday qualification and once-per-dog/year credit; no invented birthdays |
| Care documents | Connected | Council expiry-based and microchip lifetime rewards per dog; default PDF/JPEG/PNG reading with confirmed fields or secondary entered details; vet visit evidence; submit reserves, Collect credits; dog-settings viewing/corrections and attachment replacement without another award; private files, immutable versions and replay safety; later spot-audit workflow remains unbuilt |
| Wallet/orders | Connected | Canonical expiring ledger; café-first menus, real prices, purchase confirmation/receipt, owner slide-to-collect and history |
| Café account/products | Connected | Own Venue details/photo/Maps, own Reward products/prices/availability; venue photo separated from account avatar; unavailable products preserve historical orders |
| Café orders | Connected | Read-only café-scoped feed, product/customer/profile-dog cards and receipt details; current profile data refreshes while open |
| Expiry/refunds/admin | Connected | Automatic due expiry/refunds; positive admin grants and repeat-safe pending-order cancellation; these controls do not constitute a full audit/dispute system |
| Venue normalization | Connected | Canonical Venue and Reward relationship; café APIs preserved; Walk shows active eligible geocoded places. Explicit attributed Melbourne park/vet import preserves existing records |
| Check-in progress/collection | Implemented; acceptance recorded separately | Walk-map markers/details, same-walk dwell retention, verified GPS and finish-upload settlement; only actual successful rewards appear checked in the summary. One daily award per venue kind and shared ledger cap; no partial awards |
| Daily goals | Implemented; integration verification recorded separately | Backend-authoritative 50–200% slider previews; immutable targets, independent progress and 20-point collection per dog/day; one 72-point account activity cap. See [daily goals](DAILY_GOALS.md) |
| Streak rewards | Connected | Verified walking days per Melbourne date; missed-day reset; one x / milestone bar and explicit collection; each run earns 7-day then 30/60/90… rewards; earned claims survive a break |
| Friends and blocks | Connected | Search by display name/public ID, requests, removal, directional blocks, selectable map avatar and privacy controls; login email is never exposed |
| Live sessions/location/Net-Walking | Connected; acceptance recorded separately; wallet rewards disabled | Walk publishes through authenticated session APIs from its existing Core Location stream. Friend and nearby-partner visibility are independent and default off; invitations grant exact partner position; server shows verified together-distance. Raw GPS has a 15-minute rolling retention worker. No reward estimate or credit is shown while policy is disabled |
| Leaderboard | Outside this delivery | No tab, endpoint or table; this team does not present it as a partial Friends feature |
| OAuth, password reset, account deletion | Later delivery | Email login remains current; social identity/account erasure flows are not complete |
| Chat, push, charity | Later delivery | Optional identity/chat/charity/push tables are not created; no working UI/API is claimed |
| Social sharing | Connected | Completed walks can render a local image card with optional date, dog names and confirmed points; route and location are excluded, and sharing uses the system sheet with no public-post database |

The [archived database coverage](database-design-2026-09-25/README.md) describes
the earlier 24-table foundation. Current models and migrations define the schema;
a table alone does not establish an enabled feature. See
[Walk device acceptance](WALK_TESTING.md) and [open decisions](DECISIONS.md).

New onboarding, council selection and registration-gated redemption are implemented.
See [daily-goal behavior](DAILY_GOALS.md) and
[integration and acceptance evidence](INTEGRATION.md).
