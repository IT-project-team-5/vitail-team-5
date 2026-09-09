# Feature Status

Keep this table lightweight. Update it when a feature starts or reaches its MVP
acceptance criteria; detailed behaviour remains in `README.md`.

| Feature | Status | MVP acceptance |
|---|---|---|
| Authentication | Ready for device test | User chooses owner or café context; owner can register; both can log in and log out from Account; backend role controls routing |
| Debug backend selection | Ready for device test | Signed-out testers can save or reset a backend URL in Debug builds; it applies immediately to all requests and is absent from Staging/Release |
| App navigation shell | Ready for device test | Owner sees Account/Walk/Redeem with fixed `0 pts`; an active walk is owned by the signed-in owner screen and continues across tab changes; sign-out stops collection and leaves a paused local checkpoint. Café sees Account/Orders; Redeem and café Orders remain placeholders |
| Owner and dog profiles | Ready for device test | Owner can edit their display name, view read-only email, and add/edit/delete up to 10 persistent dogs using backend breed reference data; dog data is owner-isolated. Goal API exposes stored inputs but returns no duration until numeric welfare and heat rules are agreed |
| Walk tracking | Ready for device test | Owner selects one or more dogs and manually starts with fresh, precise GPS. A foreground-started walk requests lock-screen/background updates with While Using permission; Pause/Finish stop background tracking. Complete location batches feed a segmented route, with no straight-line distance across pauses or GPS gaps over 60 seconds. Account/backend-scoped protected checkpoints recover as Paused, not as uninterrupted tracking after force-quit. Finished walks keep dates, active time, distance, dog names and route locally, with retry-safe history IDs. Participants stay fixed while walking/paused. Real-iPhone verification is still required; see [Walk testing](WALK_TESTING.md). Server sync, inactivity auto-end, speed validation and point awards remain planned |
| Venue check-in | Planned | A user-started dwell check awards points once per venue per day |
| Redemption | Planned | Owner orders, points deduct once, café sees order, owner redeems |
