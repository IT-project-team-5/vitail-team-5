# Feature Status

Keep this table lightweight. Update it when a feature starts or reaches its MVP
acceptance criteria; detailed behaviour remains in `README.md`.

| Feature | Status | MVP acceptance |
|---|---|---|
| Authentication | Ready for device test | User chooses owner or café context; owner can register; both can log in and log out from Account; backend role controls routing |
| Debug backend selection | Ready for device test | Signed-out testers can save or reset a backend URL in Debug builds; it applies immediately to all requests and is absent from Staging/Release |
| App navigation shell | Ready for device test | Owner sees Account/Walk/Redeem with fixed `0 pts`; Account contains profiles and Walk supports foreground tracking; café sees Account/Orders; Redeem and café Orders remain placeholders |
| Owner and dog profiles | Ready for device test | Owner can edit their display name, view read-only email, and add/edit/delete up to 10 persistent dogs using backend breed reference data; dog data is owner-isolated. Goal API exposes stored inputs but returns no duration until numeric welfare and heat rules are agreed |
| Walk tracking | In progress | Owner selects one or more dogs, sees live location/route and can start, pause, resume and finish a foreground walk. Finished walks save date, active time, distance, dog names and segmented GPS route locally per account/backend; history and route details appear below the map. Participants stay fixed while walking/paused. Background tracking, server sync and point awards remain planned |
| Venue check-in | Planned | A user-started dwell check awards points once per venue per day |
| Redemption | Planned | Owner orders, points deduct once, café sees order, owner redeems |
