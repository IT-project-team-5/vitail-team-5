# Feature Status

Keep this table lightweight. Update it when a feature starts or reaches its MVP
acceptance criteria; detailed behaviour remains in `README.md`.

| Feature | Status | MVP acceptance |
|---|---|---|
| Authentication | Ready for device test | User chooses owner or café context; owner can register; both can log in and log out from Account; backend role controls routing |
| Debug backend selection | Ready for device test | Signed-out testers can save or reset a backend URL in Debug builds; it applies immediately to all requests and is absent from Staging/Release |
| App navigation | Ready for device test | Owner sees Account/Walk/Redeem with real wallet points; café sees Account/Orders; logout stays in Account |
| Owner and dog profiles | Ready for device test | Owner can edit their display name, view read-only email, and add/edit/delete up to 10 persistent dogs using backend breed reference data; dog data is owner-isolated. Goal API exposes stored inputs but returns no duration until numeric welfare and heat rules are agreed |
| Walk tracking and history | Ready for integrated device test | Compact multi-dog controls, Start/Pause/Resume/Finish, background recording and segmented local route history. Protected drafts recover as Paused after termination; no tracking occurs while terminated. Legacy histories remain readable, without invented accuracy metadata |
| Walk-distance earning | Ready for integrated device test | New finished walks save locally before foreground upload. Actual accuracy/source and segment IDs go to the existing server validator; no distance crosses a pause. Server receipts update the canonical wallet (8 points/km, max 40/day). Stable UUID/payload retries and receipt reconciliation avoid repeat awards. Routes remain local, server stores summaries only; legacy/invalid/expired records remain local without points. Physical-device GPS/background testing remains required |
| Venue check-in | Planned | A user-started dwell check awards points once per venue per day |
| Wallet and ledger | Ready for device test | Unexpired point credits produce the real balance; spending consumes soonest-expiring credits; Admin grants are positive-only; old ledger rows are read-only |
| Redemption | Ready for device test | One reward/quantity 1 per order; owner confirmation deducts once and returns a reference; retry UUID is idempotent; only that owner can collect; history includes terminal states |
| Café orders | Ready for device test | Café feed reads the same canonical owner redemptions, snapshots customer/item/café data, refreshes while visible, supports deltas/304 and cannot mutate orders |
| Café venue profile | Ready for device test | Café Account edits its own name/address/description/opening hours; name uses the same user display name as the catalogue, email stays read-only, and offers/prices remain Admin-managed |
| Expiry and refunds | Ready for device test | Compose worker refunds uncollected orders at next local midnight and expires old point lots; read paths enforce order expiry; Admin can cancel/refund pending orders once; audit records cannot be deleted |
| Personalised goal awards | Planned | Numeric welfare/heat rules and goal evaluation unit still require decisions; stored dog inputs do not fabricate targets or award 20 points |
| Charity, streaks, vet/council rewards, social sharing | Planned | No UI/API completion is claimed by the connected MVP |

Backend tests include cross-role owner → café → collect/refund flows, existing-data
migration safety, Admin restrictions and MySQL-only concurrent-spend/refund
regressions. iOS tests/builds are separate from physical iPhone acceptance.
