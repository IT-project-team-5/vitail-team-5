# Quest rewards

`GET /api/quests` projects the authenticated owner's available tasks without
creating qualifications, awarding points or changing walk records. The catalogue
controls visibility and new collections; already-collected rewards remain
replayable by their recipient after a capability is disabled.

## Walking streak

An enabled `STREAK` produces exactly one task. A day qualifies from a persisted
`Walk` whose `walk-gps-v2` validator recorded positive movement distance,
positive active time and a positive integer `accepted_moving_segments` count.
Unknown/legacy validation versions, absent or malformed evidence, stationary
walks, impossible active durations, future end times and mismatched `point_date`
values do not qualify. The day is the walk end's Melbourne calendar date. Several
walks on the same day count once; zero-point walks still qualify when movement
was validated, including after the walking/activity point cap was reached.

Consecutive local days form runs. A run ending yesterday stays active throughout
today so the user can still walk; it resets only after a whole day is missed.
This uses calendar dates across daylight-saving changes, not 24-hour intervals.
Daily Goal completion is independent and is not required.

Each run earns 20 points at 7 days, then 100 points at 30, 60, 90 days and every
further multiple of 30. The full progress bar remains `READY` until explicit
collection. It then advances to the next milestone; streak tasks never produce
a separate `COLLECTED` row. Earned, unclaimed milestones survive a later missed
day with no new claim expiry. The oldest unclaimed milestone across runs is
shown first; after those are collected, the current run (or idle 0/7) appears.

The normal task fields are supplemented by `current_days` (actual run length,
which can exceed a ready target), `milestone_days` and nullable
`run_start_date`. IDs are `streak:YYYY-MM-DD:milestone`, or `streak:idle:7` for
idle. `progress` is clamped to 0–1. Generic dog, entitlement, photo and collection
fields are null for a streak.

`POST /api/quests/streaks/collect` (optional trailing slash) accepts
`{"run_start_date":"2026-09-20","milestone_days":7}`. The server derives all
qualification evidence and requires the displayed next earned milestone.
It returns `{award:{id,kind,run_start_date,milestone_days,points,awarded_at},
balance,created}` with 201 for a new collection and 200 for an existing receipt.
The owner row lock shared with walk submission serializes validation and credit;
the qualification/ledger key contains owner, run start and milestone.
Failures roll back qualification and wallet changes together.

The existing `QuestAward` stores `kind=STREAK`, qualification time/date from the
earliest valid walk on the milestone day, the run start, milestone, promised
points and an evidence summary. The canonical `PointEntry` uses earning category
`STREAK`, the qualified Melbourne date and `streak-walk-days-2026-09-26` rules.
Collection time remains separate, and no second wallet or progress table exists.
Pending stored qualifications are not accepted as movement proof: they must
still match trusted walk evidence and retain their stated points and any explicit
existing expiry. New streak qualifications have no claim expiry.

Malformed fields return 400 `INVALID_STREAK_REQUEST`; unsupported milestone
numbers return 400 `INVALID_STREAK_MILESTONE`. Unearned/out-of-order collection
returns 409 `STREAK_NOT_READY`, disabling returns 409 `QUEST_DISABLED`, and an
incompatible existing pending qualification returns 409
`QUALIFICATION_UNAVAILABLE`. These errors have `{code,message}` bodies. Only
active dog-owner accounts can collect. A successful exact milestone retry reuses
its original award without another credit, even after the run breaks or the
catalogue is disabled.

## Birthday

Birthday tasks and collection retain their existing per-dog, annual entitlement,
owner/transfer checks and explicit collection path. `QuestAward` preserves the
dog snapshot and its promised points. Other unimplemented catalogue capabilities
do not generate pretend actionable tasks.
