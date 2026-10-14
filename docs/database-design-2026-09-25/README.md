# Database design — historical snapshot

**Recorded state: 8 October 2026. English editorial revision: 15 October.** This document preserves the design and delivery status at that date. Later integrations changed goals, check-ins, navigation and registration eligibility. For current behavior, use [Feature System](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/39976961), [QUESTS.md](../QUESTS.md), [DAILY_GOALS.md](../DAILY_GOALS.md), [SOCIAL.md](../SOCIAL.md) and [DECISIONS.md](../DECISIONS.md).

The snapshot describes **24 business-model tables**, including `WalkDog`, `DogGoalTarget` and `NetWalkInvitation`. It excludes Django authentication/admin/session/token tables and automatic permission relationships. Six proposed tables were deferred. A model or migration file does not prove that a deployment has applied it.

- [Fields, keys, indexes and constraints](schema.dbml), generated from Django models.
- [Relationship diagram](schema.mmd) and [overview](overview.svg).
- [Coverage of 37 Jira issues and 14 user stories](coverage.md).
- [API reference](../openapi.yaml), maintained separately from this historical narrative.

## Implementation recorded on 8 October

Venue check-ins and Friends/Net-Walking location flows were connected. Daily-goal and Net-Walking **awards were disabled**. Walking streaks supported valid-day counting, progress and collection. These are historical statements, not current release status.

| Models | Recorded behavior and limits |
|---|---|
| `User`, `Breed`, `Dog` | Email/password, roles, photos, dog details and birthdays worked. Social visibility, matching and map-avatar preferences were connected. Microchip redemption eligibility and full account deletion were unfinished. |
| `Venue`, `Reward` | Venue details and menus worked; `Venue` replaced `CafeProfile`. Offers supported dates, daily quantities and terms. Enabled locations with coordinates supported check-in. |
| `Redemption`, `CafeOrderFeedState` | Purchase deductions, receipts, swipe collection, expiry refunds and café order updates worked. |
| `PointEntry` | One points ledger handled expiring awards, spending, refunds, source categories and the shared Walk/Goal/Check-in cap. Goal awards were disabled. |
| `Walk`, `WalkDog` | Confirmed uploads validated distance, active seconds and participating dogs, with safe retries and walking awards. Unknown historical seconds or snapshots stayed null. |
| `WalkSession`, `LocationSample`, `NetWalkInterval` | Live sessions and limited GPS evidence supported the Walk map and verified shared distance. Completed walks linked by UUID without copying full routes. Raw social GPS used a rolling 15-minute retention window. |
| `DogGoalTarget`, `DogDailyGoal` | Goals had effective dates, daily saved targets, seven-day progress and final results. Recommendations used weight, breed activity, age and short-nose factors; owners could adjust 50–200%. The multi-dog policy for the 20-point award was still undecided. |
| `QuestDefinition`, `QuestAward` | Quest definitions, birthdays, streak eligibility and collection worked. Streaks reused Walk and QuestAward rather than a separate progress table. Goal progress came from DogDailyGoal; its award service was not publicly callable. |
| `CheckIn` | Location lookup, Start/Resume, reports, cancellation, progress and Collect worked through shared Walk/Quest/Venues state. Reports updated the latest location and server-timed progress without separate raw sample rows. Radius, dwell, category limits and cap were checked. Device/background acceptance was pending in this snapshot. |
| `DocumentEntitlement`, `DocumentSubmission`, `EvidenceFingerprint` | Private dog documents, versions, reuse protection and submission → READY → Collect worked. Council qualifications used confirmed actual expiry; microchip eligibility was once per dog for life. Confirmed values and reading suggestions were separate. Audit/freeze fields existed, but complete spot checks and point recovery did not. |
| `Friendship`, `UserBlock`, `NetWalkInvitation` | Search, invitations, responses, removal, directional blocking, default-off privacy, avatars, nearby discovery and explicit Net-Walk consent worked. Friends was under Account; Walk owned the shared walk/social map and location stream, while Venues had a separate check-in map. No leaderboard existed. |

Deferred and absent: `ExternalIdentity` (Apple sign-in), `ChatMessage` (chat/nudges), `Charity`/`Donation`, and `PushDevice`/`NotificationDelivery`. Proposed fields are not presented as existing schema.

No separate Wallet, Leaderboard, generic QuestProgress, daily points counter, shopping cart, order-item, payment or general rules-engine tables were planned. One redemption represented one product; balances and rankings could be calculated from point/activity records.

## Relationships and safeguards

**Venues and accounts are separate.** `Venue.manager_user` is optional and unique: parks need no login, and one café account manages at most one venue. Venue photos are separate from account photos. `Reward.venue_id` is the product's single venue reference. The compatibility API field `cafe_id` remains a café **User ID**; it is not interchangeable with `venue_id`.

**Orders preserve purchase details.** A redemption keeps its venue, responsible café user, product/store/customer names, price and terms. Daily stock uses Melbourne `order_date`; unexpired PENDING and COLLECTED orders consume stock, while cancellation/expiry releases it. `requires_store_purchase` describes a condition; it does not verify cash payment or minimum spend.

**The ledger determines the balance.** Available points are unexpired credits' `remaining_points`, not the sum of every `amount`. Unique source and qualification links prevent repeat awards or charges. Earnings store category, date and rules version; uncertain historical classifications stay unknown. A lock on the owner's record orders collection, purchase and refund changes safely.

**Eligibility is separate from collection.** `QuestAward.qualification_key` is unique. Birthday uniqueness also covers kind, dog snapshot and year, so ownership transfer cannot earn again. `point_entry` and `awarded_at` must both be set or both empty. Document entitlement, submission and fingerprint records represent different concepts. Submission reserves eligibility; Collect posts points, and re-uploading does not create another reward. Goal APIs expose progress/status and allow previewing and saving effective-dated targets.

**Dates and caps have defined sources.** Timestamps use UTC; daily rules use Australia/Melbourne. Walk awards use the finish date. A check-in is unique per owner/date/category, across at most four categories. Walk, goals and check-ins share 72 points/day; balance, birthdays, documents and refunds are not activity earnings. Goal awards were disabled; the internal service would recheck the cap under the same owner lock. Check-in collection required the full 12-point allowance; partial awards were absent. Net-Walk policy was recorded as unresolved at this date.

**Location evidence is limited.** CheckIn keeps current server progress, latest location and attempt UUID. It creates no LocationSample rows; cancelling an incomplete attempt removes that state. Social samples belong to a live session and are deduplicated by owner/stream/sequence. NetWalkInvitation records the two sessions and timed consent; NetWalkInterval stores each participant's verified distance and rejects overlapping intervals for the same ordered pair. Nearby discovery limits candidates before exact distance checks and returns approximate locations; precise partner location follows acceptance. Net-Walk awards and unapproved estimates were disabled.

**Database and service checks differ.** DBML shows real fields, database checks, keys and indexes. Services or model validation check cross-record ownership, roles, overlaps and quotas. Saving or bulk-writing a model does not automatically run all validation; new entry points must use the existing services.

## Privacy and open policies at the snapshot

Public photos use storage keys; documents use private storage and account access checks. Social GPS is a 15-minute verification buffer, cleared on pause/finish and swept every minute by the `social_presence` worker. Stale reads are rejected. This does not define retention for accounts, finished routes or documents.

`auth_version` invalidates credentials. `deleted_at` and `archived_at` support later deletion/disablement but are not full erasure APIs. Protected financial references mean deleting a user is not a complete personal-data cleanup. Retention, anonymisation and historical snapshots needed decisions.

Django Admin `LogEntry` was reused without a new AuditEvent table. It did not automatically cover every café price change, point action or document review. Audit/review fields and freeze reasons existed, but full spot-check services and `ADMIN_DEBIT` did not; editing old ledger entries was not point recovery.

Open items were multi-dog goal eligibility, Net-Walk awards/cap, registration eligibility, 29 February observance, retention/deletion, charity and push notifications. The approximate 504-point coffee display did not change actual prices or past orders. See the current [decision record](../DECISIONS.md) for later resolutions.

## Source history

The 25 September query `project = SCRUM ORDER BY key ASC` returned 37 visible issues with `isLast=true`. [Coverage](coverage.md) preserves those links and original statuses; Jira Done was not proof of every feature's completion.

Recorded precedence was later explicit user decisions → [points policy v3](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/27525122/New+Point+Retrieval+Calculation), published 24 September 15:06 UTC → [client meeting v7](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/26738689/Client+Meeting+09+24) and [detailed minutes v4](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/27787267/Detailed+Meeting+Minutes) → [Client Requirements](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/294913/Client+Requirements) and [User Story](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/10518529/User+Story), then live drafts. [Design Preference v3](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/28606465/Design+Preference) supplied visual direction; [New Features Listings v1](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/28377100/New+Features+Listings) was empty at that read.

Earlier mandatory approval, lifetime council rewards, 60-point coffee estimates, charging on swipe, 28 implemented tables and dual product ownership were superseded. The 27 September correction changed council renewal to actual expiry and removed fixed-10-April refresh and expired uncollected tasks. Original proposals remain in Git.

## Diagram generation

With `backend/requirements.txt` installed:

```bash
DATABASE_ENGINE=sqlite python docs/database-design-2026-09-25/render.py
DATABASE_ENGINE=sqlite python docs/database-design-2026-09-25/render.py --check
```

The tool reads model metadata without connecting to a database, applying migrations or reading user data. It generates DBML/Mermaid/SVG and validates model relationships plus the Jira/user-story index. Running it against later code can produce a newer schema; the narrative above remains dated. `--check` detects stale generated files.

DBML is a readable field reference, not a migration. Logical types, ORM defaults and `on_delete` notes are not SQL defaults/cascades; checks retain model expressions. Backend migrations and tests remain the source for upgrades, rollback and MySQL transaction behavior.
