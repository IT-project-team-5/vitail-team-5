# Requirements coverage — historical snapshot

**Recorded state: 8 October 2026; Jira snapshot: 25 September. English editorial revision: 15 October.** Keep the statuses below as historical observations. Later changes are tracked in the [Feature System](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/39976961), [current point rules](../QUESTS.md) and [decisions](../DECISIONS.md).

This snapshot maps 37 visible Jira issues and 14 user stories to 24 business-model tables. Six proposed tables were absent. Table coverage and Jira Done do not prove a complete, accepted feature.

## Sources and interpretation

The query `project = SCRUM ORDER BY key ASC` returned 37 issues with `isLast=true`. It covers that visible result set, not unread attachments or other projects. Empty issue descriptions were not supplemented with invented acceptance criteria.

Later explicit user decisions took priority, followed by [New Point Retrieval / Calculation v3](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/27525122/New+Point+Retrieval+Calculation), then meeting records, and older requirements where not superseded. At this snapshot, the 20-point daily-goal amount was confirmed but multi-dog eligibility was unresolved; leaderboard was outside this workstream.

| Source | Snapshot | Limit |
|---|---|---|
| [Client Requirements](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/294913/Client+Requirements), 294913 | live_doc, draft, d1:56; full body | Draft metadata was not treated as a published final specification. |
| [User Story](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/10518529/User+Story), 10518529 | live_doc, draft, d1:1; full body | All 14 stories retained; newer decisions override old conditions. |
| [Client Meeting 09/24](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/26738689/Client+Meeting+09+24), 26738689 | current, v7; full body | Four work areas and demonstration plans, not complete acceptance criteria. |
| Points policy, 27525122 | current, v3; full body | User-confirmed post-meeting decisions. |
| [Detailed Meeting Minutes](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/27787267/Detailed+Meeting+Minutes), 27787267 | current, v4; full body | Separate client direction, team plans, proposals and open questions. |
| [Design Preference](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/28606465/Design+Preference), 28606465 | current, v3; full body | Visual direction, not justification for new tables. |
| [New Features Listings](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/28377100/New+Features+Listings), 28377100 | Reported empty; outside the six full-body snapshots | No additional requirements inferred. |
| Linked Google Docs, motivational model and transcripts | Links retained; full bodies not included | No claim to have read their complete contents. |

“Connected” means a working API/app path used the data, not that every old story condition passed. “Foundation” means models or internal services without the full public flow. “Pending policy” means eligibility was unresolved even if an amount was known. “Deferred” means the related table did not exist. Documentation/process work needs no product table.

The [schema snapshot](README.md) includes WalkDog, DogGoalTarget and NetWalkInvitation; it excludes Django infrastructure tables. Deferred names were ExternalIdentity, ChatMessage, Charity, Donation, PushDevice and NotificationDelivery. Wallet and Leaderboard had no separate table. Reusing LogEntry did not mean every API action was audited.

## All 37 Jira issues

Original English issue titles and Jira statuses are retained. Delivery observations describe the dated snapshot.

| Jira | Title | Jira status | Recorded coverage |
|---|---|---|---|
| [SCRUM-4](https://group5-vitail-project.atlassian.net/browse/SCRUM-4) | Delegate this work item to GitHub Copilot | To Do | Tool tutorial, not a feature or new table. Embedded branch/PR/comment instructions were source content, not authority to act. |
| [SCRUM-5](https://group5-vitail-project.atlassian.net/browse/SCRUM-5) | Implement this work item from your IDE or terminal | To Do | Tool tutorial; no product table or action based on its embedded agent instructions. |
| [SCRUM-8](https://group5-vitail-project.atlassian.net/browse/SCRUM-8) | Client Requirements | Done | Requirements document; product scope mapped through the stories below. |
| [SCRUM-10](https://group5-vitail-project.atlassian.net/browse/SCRUM-10) | Who/Do/Be/Feel Requirement Table | Done | Interview analysis; roles/behavior map to User and feature models. |
| [SCRUM-12](https://group5-vitail-project.atlassian.net/browse/SCRUM-12) | Create Github Repo | Done | Development setup; no business table. |
| [SCRUM-17](https://group5-vitail-project.atlassian.net/browse/SCRUM-17) | Motivational model | Done | Analysis informs recommendations, tasks and reward policy; no motivation database. |
| [SCRUM-18](https://group5-vitail-project.atlassian.net/browse/SCRUM-18) | Determining the Tech Stack | Done | MySQL/Django, location and deployment choices; no extra business table. |
| [SCRUM-19](https://group5-vitail-project.atlassian.net/browse/SCRUM-19) | StandUp Notes | To Do | Collaboration records; no Meeting table. |
| [SCRUM-20](https://group5-vitail-project.atlassian.net/browse/SCRUM-20) | Development Minimium Viable Product | To Do | Epic groups User, Dog, Walk, PointEntry, Venue, Reward and Redemption work. |
| [SCRUM-21](https://group5-vitail-project.atlassian.net/browse/SCRUM-21) | Full Development | To Do | Epic groups tasks, check-ins, social and UI; no Epic business table. |
| [SCRUM-22](https://group5-vitail-project.atlassian.net/browse/SCRUM-22) | Project Documentation | To Do | Documentation epic; no product table. |
| [SCRUM-23](https://group5-vitail-project.atlassian.net/browse/SCRUM-23) | Project Deliverables | To Do | Delivery epic; no product table. |
| [SCRUM-24](https://group5-vitail-project.atlassian.net/browse/SCRUM-24) | Use Case | Done | Roles, saved state and transactions support use cases. Empty Jira description supplied no extra requirements. |
| [SCRUM-25](https://group5-vitail-project.atlassian.net/browse/SCRUM-25) | Further Questions Requirement Clarification | Done | Clarifies rules, limits and conflicts; no product table. |
| [SCRUM-26](https://group5-vitail-project.atlassian.net/browse/SCRUM-26) | Login Implementation | Done | User email/password, roles, photos, credentials and auth_version worked. Reset/deletion were incomplete; Apple ExternalIdentity absent; Google outside then-current scope. |
| [SCRUM-27](https://group5-vitail-project.atlassian.net/browse/SCRUM-27) | User Story | Done | Source document; US-01–US-14 mapped below. |
| [SCRUM-28](https://group5-vitail-project.atlassian.net/browse/SCRUM-28) | Progress Report | Done | Reporting and links; no product table. |
| [SCRUM-29](https://group5-vitail-project.atlassian.net/browse/SCRUM-29) | Track Dog Walk | Done | Walk/WalkDog stored validated summaries and participation. Phone pause/recovery and social sessions shared Core Location; UUID links avoided copying full routes. |
| [SCRUM-30](https://group5-vitail-project.atlassian.net/browse/SCRUM-30) | Manage Dog Profile | Done | Dog/Breed photos, actual birthdays, weight, profiles and personalised goal preview/settings worked. Chip/archive fields were foundations. |
| [SCRUM-31](https://group5-vitail-project.atlassian.net/browse/SCRUM-31) | Order Page | Done | Redemption was the one-product order/receipt; PointEntry handled spend/refunds and CafeOrderFeedState supported updates. No second order model. |
| [SCRUM-32](https://group5-vitail-project.atlassian.net/browse/SCRUM-32) | Redeem Rewards Page | Done | Venue/Reward/Redemption/PointEntry supported menus, purchase, collection and refunds. Chip-format/dog-eligibility policy and the full redemption restriction were unresolved. |
| [SCRUM-33](https://group5-vitail-project.atlassian.net/browse/SCRUM-33) | Cafe Management Page | Done | Café users managed their own Venue/Reward; orders retained the café user at purchase. Venue/account photos were separate. |
| [SCRUM-34](https://group5-vitail-project.atlassian.net/browse/SCRUM-34) | Database Setup | Done | 24 business tables; Venue replaced CafeProfile. WalkDog, effective-dated DogGoalTarget and revocable NetWalkInvitation consent were present. Deployment migration still required verification. |
| [SCRUM-35](https://group5-vitail-project.atlassian.net/browse/SCRUM-35) | review & merge usecase | Done | Review process; no product table. |
| [SCRUM-36](https://group5-vitail-project.atlassian.net/browse/SCRUM-36) | Seeking Suggestion on Built Product | In Progress | Feedback; confirmed changes map to features, not every suggestion automatically becoming a requirement. |
| [SCRUM-37](https://group5-vitail-project.atlassian.net/browse/SCRUM-37) | Identify Front End Problem and Polish | In Progress | Existing photos/activity supported UI; expansion, scroll, dialogs and appearance needed no new table. |
| [SCRUM-38](https://group5-vitail-project.atlassian.net/browse/SCRUM-38) | Update Documentation for Last Sprint and Code Implementation | In Review | Documentation maintenance; no product table. |
| [SCRUM-40](https://group5-vitail-project.atlassian.net/browse/SCRUM-40) | Create App Icons and Decide Brand Image | Done | Static app icons and virtual_avatar_key in Friends/public profile/Walk pins; no avatar shop. |
| [SCRUM-41](https://group5-vitail-project.atlassian.net/browse/SCRUM-41) | Test Current MVP and Resolve Identified Bugs | In Review | Tests/fixes, not product tables. Checks needed retries, concurrent spending/claims, role isolation and date boundaries. |
| [SCRUM-42](https://group5-vitail-project.atlassian.net/browse/SCRUM-42) | Venue check-in | To Do | Shared Venue/CheckIn/PointEntry with SCRUM-43. Latest location/server progress and Collect worked; device acceptance pending in this snapshot. |
| [SCRUM-43](https://group5-vitail-project.atlassian.net/browse/SCRUM-43) | Venue check-in | To Do | CheckIn stored category/date slot, attempt, radius/dwell snapshot, verified seconds and unique point reference. Map/API/shared state worked; outdoor/background acceptance pending. |
| [SCRUM-44](https://group5-vitail-project.atlassian.net/browse/SCRUM-44) | Task system | To Do | Quest definitions, birthdays, document models and Collect worked. Goal progress worked with awards disabled; check-ins shared server progress and streaks reused Walk/QuestAward. |
| [SCRUM-45](https://group5-vitail-project.atlassian.net/browse/SCRUM-45) | Daily goals & rewards | To Do | Goal targets/results, participation and awards had model support. Formula and 50–200% owner adjustment worked. Amount 20/day confirmed; multi-dog eligibility unresolved and collection disabled. |
| [SCRUM-46](https://group5-vitail-project.atlassian.net/browse/SCRUM-46) | Statistics & leaderboard | To Do | Outside this workstream; no ranking table/API/page. Friends activity was not a delivered leaderboard. |
| [SCRUM-47](https://group5-vitail-project.atlassian.net/browse/SCRUM-47) | Friends system, show friends location on map | To Do | Relationships, blocking, invitations, live sessions and preferences supported discovery, consent, avatars, map pins and verified shared distance. Awards disabled; device acceptance pending. |
| [SCRUM-48](https://group5-vitail-project.atlassian.net/browse/SCRUM-48) | UI & sharing | To Do | Existing summaries/photos; no Sharing/Post table. Public sharing, location removal and withdrawal remained incomplete in this issue snapshot. |
| [SCRUM-49](https://group5-vitail-project.atlassian.net/browse/SCRUM-49) | Client Meeting | In Review | Meeting record; feature and policy implications appear below. |

## All 14 user stories

Original IDs and priorities are retained from [User Story](https://group5-vitail-project.atlassian.net/wiki/pages/viewpage.action?pageId=10518529). Newer decisions took precedence.

| Story | Recorded coverage | Remaining or superseded conditions |
|---|---|---|
| US-01 Account and Sign-in (Must) | User login, roles and credential invalidation | Reset/deletion incomplete; Apple deferred. iOS/email replaced the earlier Android/Google priority. |
| US-02 Dog Profile and Daily Goal (Must) | Dog, Breed, DogGoalTarget, DogDailyGoal | Then-current limit ten dogs; formula, adjustment, effective dates and seven-day progress connected. Multi-dog award eligibility unresolved. |
| US-03 Track a Walk with GPS (Must) | Recording/pause/Finish, Walk/WalkDog validation and separate social live sessions | Upload summaries rather than full routes; social GPS retained 15 minutes with default-off consent. Full account/route retention unresolved. |
| US-04 Earn and View Points (Must) | Expiring PointEntry credits, walking awards and shared cap | Goals included in 72-point cap but awards disabled; Net inclusion unresolved. More dogs did not multiply walking points. |
| US-05 Check In at a Place (Must) | Venue, CheckIn, Core Location and Collect; latest location/server progress only | Device/background acceptance pending. Shared 72-point cap, no partial awards; additional venues could not bypass four category slots. |
| US-06 Vet and Registration Proof (Should) | Three document models, private files, READY → Collect | Council per actual period; microchip once per dog for life. Typed/uploaded details self-reported; mandatory approval superseded; full spot checks/recovery absent. |
| US-07 Use Points for Rewards (Must) | Venue menus, dated/limited Reward, Redemption and ledger | Purchase deducted points; swipe confirmed collection. Store-purchase terms displayed without cash verification. |
| US-08 History and Charity Donations (Should) | Redemption/PointEntry history | Charity/Donation absent; partners, confirmation, refunds and reconciliation unresolved. |
| US-09 Recommendations and Streaks (Should) | Personalised goals, daily results and QuestAward | No broader behavioral/weather engine. Valid-walk streaks reset after missed days, rewarded 7/30/60/90… days per run and retained earned unclaimed milestones. |
| US-10 Notifications (Should) | Empty notification_preferences JSON foundation | Preferences, quiet hours and delivery undefined; PushDevice/NotificationDelivery absent. |
| US-11 Photos, Sharing and Walking Together (Could) | Photos, friends, avatars, location preferences, discovery, invitations and verified distance | Completed-walk local sharing connected; Net awards disabled. Exact partner location required acceptance, not merely friendship. |
| US-12 Manage Merchants and Offers (Must) | Admin setup, café-owned Venue/Reward and orders | Earlier no-portal wording superseded. API price changes not all logged; multiple branches/staff permissions outside scope. |
| US-13 Review User Proof (Should) | Original files/versions; audit/review/freeze foundations | No mandatory review gate, full spot-check/recovery service or ADMIN_DEBIT. Original ledger records preserved. |
| US-14 Review Transactions and Possible Misuse (Should) | References, point sources, location and disablement foundations | No complete warning/suspension/adjustment workflow; LogEntry did not cover every API and one GPS anomaly did not justify a ban. |

## Meeting decisions and remaining work at the snapshot

| Area | Recorded support and limit |
|---|---|
| Shared Walk/Quest/Venues progress | CheckIn, authenticated location API and shared app state; outdoor/background acceptance pending, no local-timer-only awards. |
| Ready/collected ordering | Real dog/document tasks and server dates; collected tasks hid after midnight without deleting history. Unknown goals had no placeholder; the then-recorded streak design used one progress bar. |
| Document submission and collection | Submission reserved eligibility; Collect credited points. Spot checks, disputes and recovery remained open. |
| Birthday, goals and streaks | Birthday 60, personalised progress and valid-day streaks worked. No inferred birthdays; 29 February alternative and multi-dog goal awards unresolved. |
| Friends and live location | Relationship/block/preferences/avatar models and 30-second presence. Friends under Account, Walk social map, separate Venues discovery; both sharing controls default off. |
| Net-Walking with non-friends | Explicit invitation acceptance and each participant's verified distance. Approximate discovery before acceptance, exact partner location afterward; no wallet award or estimate. |
| Friends statistics/leaderboard | No ranking table, page or endpoint; outside this workstream. |
| Chat/nudges/push | Deferred models; retention, frequency, lock-screen content and quiet hours unresolved. |
| Microchip before redemption | Dog chip fields and evidence qualifications were separate. No full redemption restriction or multi-dog selection rule. Document entry accepted 15 digits without requiring 9 first; other formats needed proof. |
| Café setup and management | Venue replaced CafeProfile; Reward belonged to one venue. Parks needed no account. No branch organisation/payment platform; cafe_id identified a user, venue_id a place. |
| Puppuccino and collection | Offer terms/store-purchase flag and order snapshots existed. The 504-point coffee estimate did not change prices; cash spend and the dog's presence were not verified. |
| Location misuse checks | Walk validation and social evidence existed; 15-minute social cleanup did not define full route/account erasure. |
| Recommendations/weather | Goal calculation inputs and daily results existed; no weather provider, broad recommendation engine or weather-history table. |
| Visual design/sharing | Static assets and existing photos/activity; animation needed no new tables. Public sharing/location handling still needed acceptance. |
| Australian hosting and service operation | Deployment policy, database and private storage; region, capacity, retention and maintenance needed actual deployment checks. |

## Point-source mapping

Amounts and current policy live in [QUESTS.md](../QUESTS.md); this table preserves the historical data mapping.

| Source | Data | Recorded status |
|---|---|---|
| Walking | Walk/WalkDog → PointEntry | Connected; account distance, not multiplied per dog. |
| Net-Walking | Invitation, interval, session and Walk net fields | Consent/matching/distance connected; reward disabled, no unapproved estimate. |
| Daily exercise | DogGoalTarget, DogDailyGoal, QuestAward | Personalised progress connected; 20/day confirmed, multi-dog eligibility unresolved. |
| Café/restaurant/park/vet check-in | Venue/CheckIn category slot → PointEntry | Connected; device acceptance pending. Vet check-in was distinct from vet documents. |
| Seven-day streak | Valid Walk dates → QuestAward run/milestone → PointEntry | Connected; each new run could qualify and collection prevented repeats. |
| 30/60/90-day streak | Same records | Connected; the then-recorded bar advanced after collection. |
| Vet checkup | Document event-date qualification → PointEntry | Connected. |
| Council registration | Per-dog actual-expiry qualification → PointEntry | Renewal after expiry; old unclaimed task expired while receipts/points remained. |
| Microchip certificate | Per-dog lifetime qualification → PointEntry | Connected; retained old periods/points without repeat awards. |
| Dog birthday | Dog.date_of_birth and QuestAward → PointEntry | Once per dog/year, including ownership-transfer protection. |

Walk/Goal/Check-in services enforced the shared 72/day cap; goal awards were disabled and Net inclusion remained open at this snapshot. Balance, birthdays, documents and refunds were not that day's activity earnings. Less than 12 remaining points prevented check-in collection; partial awards were not implemented.

## Historical conflicts retained

Later decisions had superseded older one/two-dog limits, lifetime council rewards, the 60-point coffee estimate, preapproval and charging on swipe. The snapshot allowed ten dogs and used the 27 September actual-expiry council correction. Daily-goal amount was known; multi-dog eligibility was not. Walking streaks were agreed, while Net rate/cap remained open in these records.

Deletion/archive fields, document review fields and LogEntry did not implement complete deletion, audits or point recovery. The six deferred models remained absent. These records map all 37 visible issues and 14 stories; they do not claim every feature was ready for delivery.
