# Product integration and acceptance

Updated 14 October 2026. This record identifies the combined implementation and
the boundaries of its evidence. Current feature requirements and acceptance
criteria remain in the linked Confluence records; do not duplicate their policy
here. Exact run results belong in the [Testing evidence index](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/13795332).

| Implementation | Requirement / work item | Original PR head |
|---|---|---|
| Walk venue check-ins and finish settlement | [Venue Check-in](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/35815426), [SCRUM-57](https://group5-vitail-project.atlassian.net/browse/SCRUM-57) | [PR #13](https://github.com/IT-project-team-5/vitail-team-5/pull/13), `031c19fb39ea90e593df03f6f6f3216e3c8d329d` |
| Owner onboarding, per-dog goals and registration-gated redemption | [Dog Registration / Daily Goal](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/35913729), [SCRUM-58](https://group5-vitail-project.atlassian.net/browse/SCRUM-58) | [PR #14](https://github.com/IT-project-team-5/vitail-team-5/pull/14), `dcbcbcb5b7bdfa198463ecd2e6d669d975bc84e5` |
| Public dog profiles and points-based clothing shop | [Net-Walking](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/35684355), [SCRUM-56](https://group5-vitail-project.atlassian.net/browse/SCRUM-56) | [PR #15](https://github.com/IT-project-team-5/vitail-team-5/pull/15), `fb26860f7bb11275f95b86e26a6d17325cd01a35` |

## Acceptance evidence

On 14 October 2026, Chien confirmed in the project conversation: “目前 PR 有過的，
我都真機測試過了，可以標示完成” — the already-passed PRs had been tested on a real
phone and their physical acceptance may be marked complete. This is a direct
human attestation. It supersedes older blanket “physical testing pending” notes
for that stated scope; a new video is not required to recognise it.

The attestation does not supply a device model, execution date, per-case video or
third-party client sign-off. None is invented. A new combined candidate still
needs affected automated/integration regression at its actual SHA. The
[venue checklist](VENUE_CHECKIN_TESTING.md), [goal verification](DAILY_GOALS.md#migration-and-verification)
and [social acceptance cases](SOCIAL.md#release-acceptance) remain reusable case
definitions, not a claim that a later build has already passed them.

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
