# Decisions and Open Questions

Current as of 10 October 2026. The latest confirmed conversation and
24 September **New Point Retrieval / Calculation** policy supersede conflicting
older proposals. Canonical reward amounts and delivery status are in
[QUESTS.md](QUESTS.md); do not duplicate them across overview documents.

Earlier Android, SwiftData, memory-only Walk, one-time-only streak, lifetime-only or fixed-calendar
Council rewards, annual microchip rewards, 60-point coffee and submission-immediately-awards proposals are
superseded. Their full history remains in Git. Existing decision identifiers
below are retained where other project documents cite them.

## Current decisions

| Reference | Decision |
|---|---|
| R1 / R2 | Melbourne pilot; local partners fund the reward catalogue |
| R6–R10 | Walks start manually, require accurate GPS, use basic speed/accuracy checks, and stop after the inactivity limit; this is not advanced anti-cheat |
| R12 / R15 / R16 / R33 | Expiring point credits; order creation deducts once and issues a reference; uncollected orders expire at Melbourne midnight and refund |
| R26 | Personal-data deployment must use an Australian region; provider remains undecided |
| R31 | Confirmed 10 October: each dog explicitly collects 20 points per Melbourne day after completing its own goal. Walking, both dogs' goals and check-ins share one 72-point account cap. Full awards only; no partial goal points |
| R32 | Maximum two dogs per owner, enforced in API, model/Admin and SwiftUI. Existing accounts with more dogs retain their records and edit access; new creation/transfer into a full account is rejected |
| R35 / R41 | Native SwiftUI app for iOS 17+; feature-first structure, shared services and a small design system |
| R37 / R38 | Explicit venue check-in start/resume is connected through live GPS and authenticated APIs; physical acceptance remains pending. OWNER and CAFE use one iOS app; ADMIN uses Django Admin |
| R39 | Order collection has no location gate in this delivery |
| R36 / R40 | Current auth is email/password, owner self-registration and admin-created café accounts. Apple sign-in follows project-owned developer-account setup; password reset and in-app deletion remain later requirements |
| R42 / R43 | Admin onboards cafés; cafés edit their own venue and menu. Product unlisting preserves existing order snapshots |
| R44 / R45 | Minimal owner UI, guided account → dog → goal onboarding, avatar-based profile editing/logout, photo picker/crop, café Maps links and role-specific photo placeholders |
| R46 | Start before selecting dogs; Finish saves an unconfirmed summary. Explicit dog confirmation enables upload. No-dog completion saves locally for zero points; automatic stops/logout do not choose participants |
| R47 | Café-first menus; purchase confirmation opens the receipt; collection uses an owner slide gesture |
| R48 | Latest policy replaces the temporary coffee estimate. It is display guidance only and does not reprice products or old orders |
| R49 / R50 | Same-page login accordions; persisted appearance selection; the whole Walk drawer scrolls; large receipt photo opens café details; café cards show customer dogs |
| R51 / R54 | Account / Walk / Quest / Venues / Redeem in the merged app. Leaderboard is outside this team's delivery. Quest is a compact actionable list, not a dashboard of unavailable features |
| R52 | Use actual nullable dog birthdays; preserve legacy age-only records; birthday qualification is per dog/year |
| R53 / R55 | Care rewards are per dog and self-reported. Submission reserves eligibility; explicit Collect credits once. Later spot checks replace up-front approval; audit tooling is separate work |
| R56 | Up to four daily venue opportunities, one per venue kind. Below the walking/check-in cap active Quest rows remain; at the cap uncollected Quest rows hide. The Venues map still shows configured places as unavailable. Today's collected rows remain below until Melbourne midnight |
| R57 | Registration Quests are fixed to one dog and document kind. PDF/JPEG/PNG upload is the default, with on-device reading and user confirmation; entered details remain secondary. Council requires council, animal reference and actual expiry. Microchip has no expiry and supports proof-backed older identifiers. Submissions remain self-reported, never automatically verified |
| R58 / O16 resolved | Microchip registration awards 300 points once per dog in its lifetime. No certificate start/end dates or annual renewal reward. Existing credits and receipts remain unchanged; previous microchip rewards prevent another credit |
| R59 / O18 resolved | Streak counts valid walking days per account in Melbourne. A missed day breaks the run; each new run can earn seven-day points, then 30/60/90… milestones. One progress bar shows only x / target, stays full until explicit Collect, then advances |
| R60 (corrected) | Council registration awards 300 points per dog per actual registration period. Renewal opens after the confirmed document expiry, not a fixed 10 April date. Expired/superseded pending rewards disappear and cannot be collected. Unknown legacy expiry requires an evidence update without re-awarding paid points. Historical files, receipts and ledger entries remain private |
| R61 | Dog settings manages current Council/microchip records, including paid/expired documents. Corrections retain the same entitlement and award zero points. Actual expiry is editable; its maximum confirmed expiry remains the renewal boundary, so edits never advance a reward. Original evidence and receipts remain private and unchanged |
| R62 | Owners may create a local image card for a completed walk and choose its date, dog names and confirmed points. Routes, coordinates and place details are excluded; the system share sheet is the only distribution path. |
| R63 | Friends and Net-Walking open from Account; Walk is the walk/social map and supplies the sole walk/social location stream. Venues remains a separate check-in discovery map. Friend sharing and nearby matching are independent, default-off choices. A selectable virtual avatar may replace the profile photo on the social map. Explicit invitation acceptance reveals the exact partner position and enables verified together-distance. Net-Walk wallet points remain disabled and unapproved estimates are absent from UI/API. |
| R64 | Social presence expires after 30 seconds. Raw session samples form a rolling 15-minute verification buffer and are purged by a once-per-minute worker; interval summaries retain distance/time without exposing a route. Leaderboard is outside this team's delivery. |

| R65 | New owners resume dog/goal setup until explicit completion. Existing accounts default complete. Weight replaces manual size selection; established breed defaults supply internal size. Request UUIDs protect dog and goal retries |
| R66 | New purchases require accepted microchip registration for every current dog. Collecting document points and mandatory admin approval are not prerequisites. The selected product remains available after completing registration |
| R67 | Council selection uses real VEC locality/postcode data, supports overlapping postcodes and validates canonical names. Originals remain private; Django Admin supports secure preview/download |
| R68 | No PR until iOS automated verification and physical-iPhone scenarios A–E are complete, recorded and sent to Chien. Current acceptance is recorded separately from backend results |

The database normalizes Venue, keeps one PointEntry ledger and adds specific
daily-goal, check-in, live-location, Net-Walk invitation/interval and friendship
records. Friends, consented live location and verified together-distance are
connected; this does not authorize inventing wallet qualification rules or
claim a leaderboard. The six optional identity/chat/charity/push tables
are deferred. See [database design](database-design-2026-09-25/README.md).

## Implementation boundaries

Protected JSON Walk checkpoints/history and foreground retry replace the older
memory-only/SwiftData proposals. This is a bounded recovery feature, not general
offline login or a background upload worker. The server submission deadline
still applies. Completed-walk uploads store validated summaries. The separate
authenticated social session endpoint stores the short-lived samples used for
current map presence and together-distance; it does not alter a completed-walk
payload.

The Quest API projects actionable tasks, server date metadata and typed daily
goal calendars. Unused legacy daily-goal, streak, birthday and document
dashboard projections are removed; `/api/dogs/{id}/goal` now previews and saves
personalised targets. Enabling a QuestDefinition does not activate a missing
payout policy or provider.

Council, microchip and vet entitlements preserve evidence versions and one
credit per qualification. Council awards once per dog per actual registration period;
microchip awards once per dog in its lifetime. Legacy
microchip annual records are retained but do not reopen reward eligibility.
Private evidence and public profile/venue media remain separate.

The current cap service always counts walking/goal/check-in earnings, never wallet
balance, admin grants, refunds or care/birthday rewards. If the guarded
Net-Walk settlement is explicitly enabled, it also counts Net-Walk credits;
the flag defaults off while cap policy remains open. Partial check-in awards
are rejected until their policy is agreed. The client does not qualify dwell
from its clock or fabricate venue opportunities.

## Open decisions

| Reference | Decision still needed | Current safe behavior |
|---|---|---|
| O5 | Does the cap include net-walk rewards? | Net earning stays disabled. Daily goals are resolved in R31; partial goal/check-in awards remain disabled |
| O6 (resolved) | Daily-goal duration formula confirmed 6 October 2026 | Weight baseline × breed energy × calendar age × brachycephalic factor, then owner adjustment 50–200% exactly once. Immutable owner/Admin history; no invented heat factor. Reward scope resolved in R31. See DAILY_GOALS.md |
| O7 | Final rounding/minimum-walk policy | Current walking implementation rounds cumulative daily distance down; it invents no minimum-duration reward requirement |
| O8 | Weather source and heat-adjustment inputs | No weather-based goal calculation or provider claim |
| O9 | Broader retention, access and account-erasure policy for routes, evidence and history | Social raw GPS has a working rolling 15-minute purge and stale-read rejection. Check-in keeps only current server-timed progress and its latest fix, not raw sample rows; local completed routes and private originals retain their documented behavior. Account-wide erasure/anonymisation remains unresolved |
| O10 | Evidence spot-audit procedure and consequences | Submission is self-reported; protected originals/history remain. No authenticity guarantee or automatic penalty |
| O11 | Approved charity partners and how point donations are fulfilled | No donation feature or charity tables in this foundation |
| O12 | Admin evidence/reason requirements, dispute actions and account-deletion/anonymization rules | Existing grants/refunds stay constrained; do not delete or rewrite ledger history to simulate deletion. Django admin logging alone is not a full audit workflow |
| O13 | Release deadline and measurable product acceptance | Build/test results and physical-device checks are recorded separately; schema completion does not certify release readiness |
| O17 | Birthday treatment for 29 February in non-leap years | Actual anniversary only; no invented observed date |
| O19 | Final Net-Walk wallet rate/cap membership and field acceptance of proximity/time parameters | Friends/search/blocks, default-off privacy, approximate nearby discovery, explicit invitation consent, exact active-partner position and verified together-distance are connected. Wallet settlement stays disabled; no estimate or credit is exposed |
| O20 | Minimum café purchase/offer duration and daily inventory policy | Preserve configured product prices and historical terms; no fiat checkout or automatic merchant settlement |

Account reset/deletion, OAuth delivery, notifications/quiet hours and chat need
their own acceptance work. Exact location remains private by default; friend
sharing, nearby discovery, partner acceptance and any future earning are
separate choices. Never infer consent from a friendship or an account role.
