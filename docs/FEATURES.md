# Feature Status

Keep this table lightweight. Update it when a feature starts or reaches its MVP
acceptance criteria; detailed behaviour remains in `README.md`.

| Feature | Status | MVP acceptance |
|---|---|---|
| Authentication | Ready for device test | User chooses owner or café context; owner can register; both can log in and log out from Account; backend role controls routing |
| Debug backend selection | Ready for device test | Signed-out testers can save or reset a backend URL in Debug builds; it applies immediately to all requests and is absent from Staging/Release |
| Appearance settings | Ready for device test | Owner profile settings and Café Account provide persisted System/Light/Dark selection across login, pages and sheets |
| App navigation | Ready for device test | Owner sees Vitail above Account/Walk/Quest/Redeem; wallet and 60-point coffee estimate only in Redeem; owner logout inside profile editor; café sees Account/Products/Orders |
| Owner and dog profiles | Ready for device test | People/dogs/cafés have uploaded photos with a picker/crop flow; new owners see Add Dog. Owner can edit their display name, view read-only email, and add/edit/delete up to 10 persistent dogs using backend breed reference data; dog data is owner-isolated. Goal API exposes stored inputs but returns no duration until numeric welfare and heat rules are agreed |
| Walk tracking and history | Ready for integrated device test | Full-height map, draggable bottom menu, state-specific Start/Pause/Resume/Finish, background recording and segmented local route history. Protected drafts recover as Paused after termination; no tracking occurs while terminated. Legacy histories remain readable, without invented accuracy metadata |
| Walk-distance earning | Ready for integrated device test | Finish summaries persist before confirmation; dogs are selected after the walk. Only explicitly confirmed walks with dogs upload; no-dog records remain local with zero points. Actual accuracy/source and segment IDs go to the existing server validator; no distance crosses a pause. Server receipts update the canonical wallet (8 points/km, max 40/day). Stable UUID/payload retries and receipt reconciliation avoid repeat awards. Routes remain local, server stores summaries only; legacy/invalid/expired records remain local without points. Physical-device GPS/background testing remains required |
| Venue check-in | Quest/map integration ready; provider pending | One shared verified progress/collect store for the map drawer and Quest; stable retry IDs and session isolation. Maximum four daily rows; uncollected rows hide at the 72-point walking/check-in cap, collected rows remain today. Location validation, venue start flow, caps and HTTP provider belong to the venue feature |
| Quest list | Ready for device test | Compact avatar rows and detail sheets; only eligible tasks; READY highlighted first, IN_PROGRESS next, COLLECTED muted below until Melbourne midnight. Undefined daily goals and unenabled streak rewards are hidden |
| Walking streak | Rules available; award delivery pending | Legacy API reports accepted walking streaks, but no actionable Quest row appears while awards are disabled |
| Dog birthdays | Ready for device test | Explicit nullable birthday, computed age, safe legacy profiles; 60-point birthday collection once per dog/year linked to the canonical ledger |
| Care document rewards | Ready for device test | Per-dog council/microchip/vet tasks; self-reported submissions reserve rewards; explicit Collect credits once; immutable re-uploads, idempotent retries, private authenticated files and read-only admin evidence |
| Leaderboard | Owned by another teammate | Removed this slice's tab, service, stores, views, backend endpoint and tests |
| Wallet and ledger | Ready for device test | Unexpired point credits produce the real balance; spending consumes soonest-expiring credits; Admin grants are positive-only; old ledger rows are read-only |
| Redemption | Ready for device test | Café-first menus with Maps links; centred product/café/deadline confirmation opens the receipt after success, even if a follow-up refresh fails. One reward/quantity 1 per order; owner confirmation deducts once; retry UUID is idempotent; only that owner can slide to collect; history includes terminal states |
| Café orders | Ready for device test | Item-first cards show customer and current profile dogs with avatars, with details on tap and no update-time header. Feed remains read-only and café-scoped. Profile-aware clients request fresh pending-order snapshots; legacy deltas/304 remain supported |
| Café venue profile | Ready for device test | Café Account edits its own photo/name/address/description/opening hours/Google Maps link; name uses the same user display name as the catalogue, email stays read-only; products/prices are managed separately in Products |
| Café products | Ready for device test | Café can list, create and edit only its own canonical Reward products, including descriptions, positive whole-number point prices and availability; unavailable products leave the owner catalogue and existing orders keep their snapshots |
| Expiry and refunds | Ready for device test | Compose worker refunds uncollected orders at next local midnight and expires old point lots; read paths enforce order expiry; Admin can cancel/refund pending orders once; audit records cannot be deleted |
| Personalised goal awards | Planned | Numeric welfare/heat rules and goal evaluation unit still require decisions; stored dog inputs do not fabricate targets or award 20 points |
| Charity and social sharing | Planned | No UI/API completion is claimed by the connected MVP |

Backend tests include cross-role owner → café → collect/refund flows, existing-data
migration safety, Admin restrictions and MySQL-only concurrent-spend/refund
regressions. iOS tests/builds are separate from physical iPhone acceptance.
