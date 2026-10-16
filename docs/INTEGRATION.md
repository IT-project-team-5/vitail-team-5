# Product integration and acceptance

Updated 16 October 2026. This record identifies the combined implementation and
the boundaries of its evidence. Current feature requirements and acceptance
criteria remain in the linked Confluence records; do not duplicate their policy
here. Exact run results belong in the [Testing evidence index](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/13795332).

| Implementation | Requirement / work item | Original PR head |
|---|---|---|
| Walk venue check-ins and finish settlement | [Venue Check-in](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/35815426), [SCRUM-57](https://group5-vitail-project.atlassian.net/browse/SCRUM-57) | [PR #13](https://github.com/IT-project-team-5/vitail-team-5/pull/13), `031c19fb39ea90e593df03f6f6f3216e3c8d329d` |
| Owner onboarding, per-dog goals and registration-gated redemption | [Dog Registration / Daily Goal](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/35913729), [SCRUM-58](https://group5-vitail-project.atlassian.net/browse/SCRUM-58) | [PR #14](https://github.com/IT-project-team-5/vitail-team-5/pull/14), `dcbcbcb5b7bdfa198463ecd2e6d669d975bc84e5` |
| Public dog profiles and points-based clothing shop | [Net-Walking](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/35684355), [SCRUM-56](https://group5-vitail-project.atlassian.net/browse/SCRUM-56) | [PR #15](https://github.com/IT-project-team-5/vitail-team-5/pull/15), `fb26860f7bb11275f95b86e26a6d17325cd01a35` |

## Statistics integration — 16 October

The integration combines [PR16](https://github.com/IT-project-team-5/vitail-team-5/pull/16),
`abd902d`, and Jocelyn's [PR17](https://github.com/IT-project-team-5/vitail-team-5/pull/17),
`50e3e1a`, with privacy, activity-calculation and client integration fixes.
Tony's latest published work is already in main through PR15; no newer Tony
branch was published at this check. The combined change is ready for teammate review.

Statistics and the friends leaderboard open from Friends, preserving the five
main navigation tabs. The API reads existing validated, completed walks; it
creates no points or separate activity counters. Daily-goal progress combines
actual dog participation, capped at each eligible dog's own target.

The candidate leaderboard uses walking minutes over today and the preceding six
Melbourne calendar days. Accepted friends appear only after opting in, with
blocked, inactive, deleted and non-owner accounts excluded. Names and public IDs
are shown; login emails are omitted. The owner's own row remains private when
sharing is off. Equal exact walking seconds share a competition rank (1, 1, 3).
The opt-in affects leaderboard sharing independently of location/Net-Walking
consent. These are reviewable candidate choices under
[SCRUM-46](https://group5-vitail-project.atlassian.net/browse/SCRUM-46) and
[SCRUM-63](https://group5-vitail-project.atlassian.net/browse/SCRUM-63), pending
team/client confirmation. The API contract is in [OpenAPI](openapi.yaml).

Real-phone testing is complete for integration candidate `a0414b5`, separately
from the earlier PR13–15 tests below. The device model and individual case
observations are not recorded here. Client acceptance and non-author review
remain separate completion steps.

## Acceptance evidence

We completed real-phone testing for the merged PRs 13–15. We retain that
PR-level acceptance and test later changes according to their impact.

The existing record contains no device model, original execution date or
individual case observations. Final client acceptance is recorded separately. The
[venue checklist](VENUE_CHECKIN_TESTING.md), [goal verification](DAILY_GOALS.md#migration-and-verification)
and [social acceptance cases](SOCIAL.md#release-acceptance) remain reusable test
instructions, not results for a later build.

## Integration choices

- Preserve original PR commits and merge their distinct features. Owner
  navigation is Redeem / Quest / Walk / Friends / Account. Walk retains its sole
  GPS stream and venue settlement; the onboarding gate, registration recovery
  route, current Quest wallet balance and wardrobe balance refresh remain wired.
- Preserve both `accounts.0006` migrations and `0007_user_public_dog`.
  `0008_merge_onboarding_and_public_dog` joins the two migration leaves without
  rewriting already-applied migration history or resetting accounts.
- Keep all Walk venue and social/XCTest source references. Signing uses the
  existing `.xcconfig` and local override mechanism; no personal development team
  is hardcoded into the shared Xcode project.
- Preserve one wallet and existing full-award daily-cap rules. Net-Walk payout
  remains disabled. Integration does not approve new avatar prices or extend
  coffee-registration eligibility rules to other purchases; open product
  decisions remain in [DECISIONS.md](DECISIONS.md) and the feature records.
- Preserve the original failed main baseline. PR #13 contains the cross-date
  document-ledger replay fix; the combined test run must verify it alongside
  daily-goal and avatar behavior.

## Required candidate verification

1. Django system/migration checks and a fresh isolated MySQL migration.
2. Upgrade a disposable database from main `7332210` with synthetic account,
   dog, ledger and document records; verify their identities and values survive.
3. Full MySQL tests, including real row-lock/concurrency cases and reset replay.
4. Full iOS build/tests for combined navigation, onboarding, check-ins and shop.
5. Non-author review and affected regression for new integration changes.

Record commands, environment, SHA, timestamp, failures/skips and raw evidence in
the Testing index. A green branch run, a populated checklist or a merged PR alone
is not a completed release or client handover.
