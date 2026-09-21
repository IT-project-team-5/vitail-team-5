# Feature Status

Keep this table lightweight. Update it when a feature starts or reaches its MVP
acceptance criteria; detailed behaviour remains in `README.md`.

| Feature | Status | MVP acceptance |
|---|---|---|
| Authentication | Ready for device test | User chooses owner or café context; owner can register; both can log in and log out from Account; backend role controls routing |
| Debug backend selection | Ready for device test | Signed-out testers can save or reset a backend URL in Debug builds; it applies immediately to all requests and is absent from Staging/Release |
| App navigation shell | Ready for device test | Owner sees Account/Walk/Redeem; the points badge now reflects the real wallet balance; café sees Account/Orders; Walk remains a placeholder |
| Owner and dog profiles | Ready for device test | Owner can edit their display name, view read-only email, and add/edit/delete up to 10 persistent dogs using backend breed reference data; dog data is owner-isolated. Goal API exposes stored inputs but returns no duration until numeric welfare and heat rules are agreed |
| Walk tracking | Planned | A valid manually started walk records and awards points |
| Venue check-in | Planned | A user-started dwell check awards points once per venue per day |
| Redemption | In progress | Built on the shared `rewards` app (not a separate wallet/venues system): owner browses a café's rewards, redeems one and points deduct immediately (FIFO across point entries), owner marks it collected (Redeem). Café-scoped catalogues/offers, automatic expiry/refund of a pending redemption, and charity donations are not built yet |
