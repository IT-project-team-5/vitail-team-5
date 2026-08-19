# Decisions and Open Questions

Requirements captured from the client on 2026-08-19.

Two kinds of entry live here. **Resolved** decisions are locked and should not be
relitigated in code review. **Open** decisions have no answer yet — do not invent
behaviour for them, raise them instead.

---

## Resolved

| # | Decision | Detail |
|---|---|---|
| R1 | Pilot market | Melbourne first, not built to scale from day one |
| R2 | Business model | B2B2C — insurers, councils and merchants fund the reward catalogue |
| R3 | Platform | Android only |
| R4 | Roles | Dog owner and Vitail admin only. Merchants are records, not accounts |
| R5 | Dogs | Multiple dogs per account. Reversed after delivery-team pushback |
| R6 | Walk start | Manual only, no background auto-detection |
| R7 | Walk auto-end | After 5 minutes inactive, or on logout |
| R8 | Pause forgiveness | Stationary periods under 5 minutes are forgiven |
| R9 | GPS accuracy floor | Ignore samples worse than 30 m; require a lock before tracking |
| R10 | Speed check | Exclude driving and cycling by implied speed |
| R11 | Offline | No offline tracking or queued sync. Local buffering during a walk only |
| R12 | Point expiry | 12 months from earning |
| R13 | Merchant onboarding | Admin portal only; merchants contact Vitail to change offers |
| R14 | Merchant pricing | Merchants set their own point prices at partnership signing |
| R15 | Redemption model | Order first, points deducted on order, collected in store |
| R16 | Redemption record | Every redemption gets a reference number, visible in owner history |
| R17 | Charity donations | Points can be donated to a selected charity |
| R18 | Auth | Google social login, plus password reset and account deletion |
| R19 | Task model | Tasks are not assigned. Owners choose, with recommendations surfaced |
| R20 | Missed tasks | Progress lost, no penalty, retryable the same day |
| R21 | Streaks | Daily walking streak, 7 days and 30 days, one-time bonuses |
| R22 | Photo check-ins | Desirable optional feature, not pilot scope |
| R23 | Social sharing | Instagram sharing of walk stats is wanted |
| R24 | Reviews | Not needed |
| R25 | Net-walking | Nice to have, explicitly not pilot scope |
| R26 | Data residency | Personal data hosted in an Australian region |
| R27 | Disputes | Email contact is sufficient at pilot |
| R28 | Budget | Free-tier and low-cost usage-based services preferred |
| R29 | Points economics | Client owns the earn rates and the points-to-dollar peg |
| R30 | Café interface | Café staff sign in to the Android app with a `CAFE` account |
| R31 | Daily goal, multiple dogs | Once per day per account, when every dog on that day's walks met its own goal |
| R32 | Max dogs per account | 10 |

### On R29

The delivery team raised that the published earn rates imply a large annual
reward liability per user, and that this interacts with whatever
points-to-dollars conversion is chosen. The client has acknowledged the concern
and retained the decision. The rates in `README.md` are built as specified.

This is recorded so the reasoning is not lost, not to reopen it.

---

## Open

O2, O14 and O15 were resolved and moved to the table above. Numbering is not
reused, so earlier references stay valid.

### O1 — Vet checkup confirmation

200 points is the largest single award, capped at 2 per year and 60 days apart,
but the confirmation method is undefined. Who confirms, and against what
evidence? Admin review of an uploaded invoice is the assumed default, but it is
unverified and forgeable.

**Blocks:** `rewards` app, Engineer 4.

### O3 — Order abandonment

Points are deducted when the order is created, so an owner who never collects
has already paid.

**Assumed default, pending confirmation:** uncollected orders expire at end of
day and points are refunded automatically, with a ledger entry.

**Blocks:** expiry job, Engineer 4.

### O4 — Geofence gate on collection

Proposed by the delivery team: the in-store Redeem button only becomes tappable
inside the venue geofence, so an order cannot be marked collected from home.
Reuses existing check-in geofencing at near-zero extra cost.

**Assumed default, pending confirmation:** implemented.

### O5 — Daily cap suppresses multi-venue check-ins

Maximum walking (40) plus the daily goal (20) is 60. The cap is 72. That leaves
room for exactly **one** 12-point check-in per day, even though check-ins are
specified as once per venue per day and merchant foot traffic is what partners
pay for.

Options: exclude check-ins from the cap, cap them separately, or raise the
ceiling.

**Built as specified (72) until the client decides.**

### O6 — Goal units

The personalised goal is a recommended **duration**, but walk points are earned
per **kilometre**. Is the 20-point goal met by minutes walked or distance
covered?

**Blocks:** goal evaluation, Engineers 1 and 3.

### O7 — Rounding granularity and minimum walk

Round down per walk, or per day? And does a minimum walk length still apply —
the earlier draft had 10 minutes, the current requirements do not mention one.

Note: the supplied example "4.5 km = 36 points, not 36.8" is arithmetically off.
4.5 × 8 is exactly 36. The 36.8 figure implies 4.6 km.

### O8 — Weather provider

Heat adjustment needs a temperature source for Australian locations. Provider
not chosen. Bureau of Meteorology has no clean public API; OpenWeather free tier
is the likely default.

### O9 — GPS retention period

How long raw route samples are kept. Matters for privacy posture with councils
and insurers, and for database growth.

### O10 — Council registration evidence

Registration documents contain name, address and sometimes microchip number.
This is the most sensitive data in the product, awarded at 300 points. Confirm
whether pilot needs it at all, and define storage, access and retention if so.

### O11 — Charity partners

Which charities, and how funds actually move from Vitail to them.

### O12 — Admin capabilities

The client did not answer what platform admins should be able to do beyond
onboarding. Assumed: approve venues, review evidence, cancel and refund orders,
investigate suspected farming, view basic metrics.

### O13 — Success criteria and deadline

"Creativity aligned with the vision" is not testable. Concrete acceptance
criteria are proposed in `TECH_STACK.md` section 23. The client deferred to the
project deadline, which the delivery team still needs to state.

---

## Reference: cost estimate

Requested by the client. Figures are indicative and should be verified before
any commitment — Google changed its maps pricing structure in 2025.

| Item | Pilot cost |
|---|---|
| Google Maps SDK for Android (map display) | No cost |
| Android Geofencing API | No cost |
| Firebase Cloud Messaging | No cost |
| Play Integrity | Free tier |
| Weather API | Free tier |
| Australian hosting (small instance + managed MySQL) | ~AUD 50–150/month |

The core mechanic is cheap because **geofencing needs no maps API**, and because
partner coordinates are stored by Vitail rather than looked up through a paid
place-search service.
