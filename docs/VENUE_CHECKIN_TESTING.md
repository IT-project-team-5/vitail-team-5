# Venue check-in: physical iPhone acceptance

Implementation target: [SCRUM-57](https://group5-vitail-project.atlassian.net/browse/SCRUM-57),
[Venue-Checkin v5](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/35815426/Venue-Checkin)
(9 October 2026). **Physical GPS acceptance and recordings are pending.**
Automated tests and simulator results do not satisfy this requirement.

## Prepare the build and locations

Use a real iPhone, Precise Location and an owner account with a dog. Record the
branch/commit, phone/iOS version, API address, Melbourne date/time and starting
wallet/activity total. Apply migrations and explicitly import the
[Melbourne snapshot](MELBOURNE_VENUES.md) into your development database. Confirm
the points are safely reachable and within 20 metres of the displayed marker.
Configure an actual partner café in Admin for the café test; the public-place
import does not invent a partner business.

Do not simulate GPS or shorten dwell thresholds for the acceptance recordings.
Keep the complete original recording for each test, including time spent outside
and inside. Follow local access/leash rules. For clean success cases use an
account/day whose category reward has not been collected and that has at least
12 points of activity allowance remaining **after walking settlement**.

## Record each complete flow

Repeat for **Vet (3 minutes), Park (5 minutes), Café (10 minutes)**:

1. Open Walk. Find/tap the venue and show its name, type, address and required stay.
2. Outside the circle, show **Go here to get points**.
3. Start a walk and enter its 20-metre circle. Show the glow and verified progress.
4. Leave before completion. Show that the glow fades and progress is retained.
5. Remain outside long enough to demonstrate no additional verified time.
6. Return in the same walk. Show progress resuming from the retained amount.
7. Reach the full stay time. Show **Check-in complete. Finish your walk.** and
   verify the wallet has not received the venue points yet.
8. Finish, select the dog and confirm **Complete walk**. Show the processing state
   followed by the checked venue row, actual 12-point award and saved total.
9. Show the wallet/ledger increase agrees with the actual walk and venue total.
10. Return to the map/Quest. Show today's collected category message and static
    marker. Tap another venue of the same category: it cannot earn another award.

Also record/check incomplete finish (no checked reward), repeated/reopened upload
(same receipt and balance), poor/denied GPS (frozen progress), a new walk (no
inherited partial dwell), and the daily cap (no excess or fake full reward).
Check Reduce Motion, large text and a paused/reopened walk. The café must remain
recording while receiving reliable stationary fixes for more than five minutes.

## Results to attach

| Category | Venue | Actual date/time | Expected venue points | Actual venue points | Full original video | Result |
|---|---|---|---|---|---|---|
| Vet | Pending physical test | Pending | 12 if eligible after walk settlement | Pending | Pending | Not run |
| Park | Pending physical test | Pending | 12 if eligible after walk settlement | Pending | Pending | Not run |
| Café | Pending physical test | Pending | 12 if eligible after walk settlement | Pending | Pending | Not run |

Add actual walking points, summary total, wallet delta and starting/ending daily
activity totals to each result. Preserve failure recordings and document fixes,
then rerun the affected flow. Supply original video links and the results to
Chien; record that delivery before marking the PR ready and the Jira task done.
