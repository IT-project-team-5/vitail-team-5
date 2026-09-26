# Decisions and Open Questions

Current as of 27 September 2026. The latest confirmed conversation and
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
| R31 | Per-dog goal progress; the agreed daily goal reward is once per account when participating dogs meet their targets. Formula/evaluation details remain open |
| R32 | Current app limit: 10 dogs per owner; the relational model supports multiple dogs |
| R35 / R41 | Native SwiftUI app for iOS 17+; feature-first structure, shared services and a small design system |
| R37 / R38 | Explicit venue check-in start is intended. OWNER and CAFE use one iOS app; ADMIN uses Django Admin. A table alone does not implement check-in |
| R39 | Order collection has no location gate in this delivery |
| R36 / R40 | Current auth is email/password, owner self-registration and admin-created café accounts. Apple sign-in follows project-owned developer-account setup; password reset and in-app deletion remain later requirements |
| R42 / R43 | Admin onboards cafés; cafés edit their own venue and menu. Product unlisting preserves existing order snapshots |
| R44 / R45 | Minimal owner UI, first-dog modal, avatar-based profile editing/logout, photo picker/crop, café Maps links and role-specific photo placeholders |
| R46 | Start before selecting dogs; Finish saves an unconfirmed summary. Explicit dog confirmation enables upload. No-dog completion saves locally for zero points; automatic stops/logout do not choose participants |
| R47 | Café-first menus; purchase confirmation opens the receipt; collection uses an owner slide gesture |
| R48 | Latest policy replaces the temporary coffee estimate. It is display guidance only and does not reprice products or old orders |
| R49 / R50 | Same-page login accordions; persisted appearance selection; the whole Walk drawer scrolls; large receipt photo opens café details; café cards show customer dogs |
| R51 / R54 | Account / Walk / Quest / Redeem. Leaderboard belongs to another teammate. Quest is a compact actionable list, not a dashboard of unavailable features |
| R52 | Use actual nullable dog birthdays; preserve legacy age-only records; birthday qualification is per dog/year |
| R53 / R55 | Care rewards are per dog and self-reported. Submission reserves eligibility; explicit Collect credits once. Later spot checks replace up-front approval; audit tooling is separate work |
| R56 | Up to four daily venue opportunities. Below the walking/check-in cap active rows remain; at the cap uncollected rows hide. Today's collected rows remain below until Melbourne midnight |
| R57 | Registration Quests are fixed to one dog and document kind. PDF/JPEG/PNG upload is the default, with on-device reading and user confirmation; entered details remain secondary. Council requires council, animal reference and actual expiry. Microchip has no expiry and supports proof-backed older identifiers. Submissions remain self-reported, never automatically verified |
| R58 / O16 resolved | Microchip registration awards 300 points once per dog in its lifetime. No certificate start/end dates or annual renewal reward. Existing credits and receipts remain unchanged; previous microchip rewards prevent another credit |
| R59 / O18 resolved | Streak counts valid walking days per account in Melbourne. A missed day breaks the run; each new run can earn seven-day points, then 30/60/90… milestones. One progress bar shows only x / target, stays full until explicit Collect, then advances |
| R60 (corrected) | Council registration awards 300 points per dog per actual registration period. Renewal opens after the confirmed document expiry, not a fixed 10 April date. Expired/superseded pending rewards disappear and cannot be collected. Unknown legacy expiry requires an evidence update without re-awarding paid points. Historical files, receipts and ledger entries remain private |

The database foundation normalizes Venue, keeps one PointEntry ledger and adds
specific daily-goal, check-in, live-location, net-walk and friendship records.
It does not authorize inventing qualification rules or claim completed social,
location or leaderboard APIs. The six optional identity/chat/charity/push tables
are deferred. See [database design](database-design-2026-09-25/README.md).

## Implementation boundaries

Protected JSON Walk checkpoints/history and foreground retry replace the older
memory-only/SwiftData proposals. This is a bounded recovery feature, not general
offline login or a background upload worker. The server submission deadline
still applies. Current walk uploads store validated summaries; the new raw
sample/session schema is not populated by that endpoint.

The Quest API now projects only actionable tasks plus server date metadata.
Unused daily-goal, streak, birthday and document dashboard projections and the
placeholder dog-goal endpoint are removed. Enabling a QuestDefinition does not
activate a missing calculator/provider.

Council, microchip and vet entitlements preserve evidence versions and one
credit per qualification. Council awards once per dog per actual registration period;
microchip awards once per dog in its lifetime. Legacy
microchip annual records are retained but do not reopen reward eligibility.
Private evidence and public profile/venue media remain separate.

The current cap service counts walking/check-in earnings, never wallet balance,
admin grants, refunds or care/birthday rewards. Partial check-in awards are
rejected until their policy is agreed. The client does not qualify dwell from
its clock or fabricate venue opportunities.

## Open decisions

| Reference | Decision still needed | Current safe behavior |
|---|---|---|
| O5 | Does the combined daily cap also include goal and net-walk rewards? How should an otherwise valid check-in behave when less than its full reward remains? | Walking/check-in share the cap. Goal/net awards and partial check-in awards are disabled |
| O6 | Numeric daily-goal formula: duration versus distance, breed/age/size/flat-face adjustments, heat guardrails and live participant attribution | Reward amount is already agreed; targets, percentages and awards remain absent until evaluation rules exist |
| O7 | Final rounding/minimum-walk policy | Current walking implementation rounds cumulative daily distance down; it invents no minimum-duration reward requirement |
| O8 | Weather source and heat-adjustment inputs | No weather-based goal calculation or provider claim |
| O9 | Retention, access and erasure policy for GPS, routes, evidence and account history | No new public GPS ingestion; local routes/private originals retained by current behavior. Schema TTL fields alone do not implement a retention job |
| O10 | Evidence spot-audit procedure and consequences | Submission is self-reported; protected originals/history remain. No authenticity guarantee or automatic penalty |
| O11 | Approved charity partners and how point donations are fulfilled | No donation feature or charity tables in this foundation |
| O12 | Admin evidence/reason requirements, dispute actions and account-deletion/anonymization rules | Existing grants/refunds stay constrained; do not delete or rewrite ledger history to simulate deletion. Django admin logging alone is not a full audit workflow |
| O13 | Release deadline and measurable product acceptance | Build/test results and physical-device checks are recorded separately; schema completion does not certify release readiness |
| O17 | Birthday treatment for 29 February in non-leap years | Actual anniversary only; no invented observed date |
| O19 | Net-walk proximity/time/consent, overlap calculation and cap membership; friend discovery/privacy/blocking behavior | Data foundations only. No matcher, exact live-position sharing or net-walk credit |
| O20 | Minimum café purchase/offer duration and daily inventory policy | Preserve configured product prices and historical terms; no fiat checkout or automatic merchant settlement |

Account reset/deletion, OAuth delivery, notifications/quiet hours, sharing and
chat need their own acceptance work. Keep exact location private by default;
location consent, social visibility and ability to earn together are separate
choices. Never infer consent from a friendship or an account role.
