# Feature Status

Keep this table lightweight. Update it when a feature starts or reaches its MVP
acceptance criteria; detailed behaviour remains in `README.md`.

| Feature | Status | MVP acceptance |
|---|---|---|
| Authentication | Ready for device test | User chooses owner or café context; owner can register; both can log in and log out from Account; backend role controls routing |
| App navigation shell | Ready for device test | Owner sees Account/Walk/Redeem with fixed `0 pts`; café sees Account/Orders; domain pages remain placeholders |
| Owner and dog profiles | Ready for device test | Owner can edit their display name, view read-only email, and add/edit/delete up to 10 persistent dogs using backend breed reference data; dog data is owner-isolated. Goal API exposes stored inputs but returns no duration until numeric welfare and heat rules are agreed |
| Walk tracking | Planned | A valid manually started walk records and awards points |
| Venue check-in | Planned | A user-started dwell check awards points once per venue per day |
| Redemption | Planned | Owner orders, points deduct once, café sees order, owner redeems |
