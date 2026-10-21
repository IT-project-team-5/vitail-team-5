# Venue check-in: physical iPhone acceptance

Implementation target: [SCRUM-57](https://group5-vitail-project.atlassian.net/browse/SCRUM-57),
[Venue-Checkin v5](https://group5-vitail-project.atlassian.net/wiki/spaces/G5VA/pages/35815426/Venue-Checkin)
(9 October 2026). We completed real-phone testing for the merged PRs 13–15;
see [acceptance evidence](INTEGRATION.md#acceptance-evidence).
We use the cases below for later affected builds and record automated, simulator
and phone results separately.

## Prepare the build and locations

Use a real iPhone, Precise Location and an owner account with a dog. Record the
branch/commit, phone/iOS version, API address, Melbourne date/time and starting
wallet/activity total. Apply migrations and explicitly import the
[Melbourne snapshot](MELBOURNE_VENUES.md) into your development database. Confirm
the points are safely reachable and within 20 metres of the displayed marker.
Configure an actual partner café in Admin for the café test; the public-place
import does not invent a partner business.

The standard venue radius remains 20 metres. A venue's `checkin_radius_m` can be
configured separately in Admin for development testing; the temporary
`Vitail Test Vet - Chien` uses 50 metres. The iOS map circle, entry detection,
details and backend validation all use the effective radius returned by the
venue API. Existing check-ins retain the radius captured when they started;
configuration changes apply to new attempts. A wider radius does not relax GPS
accuracy checks, change the required stay time or grant points automatically.

If the blue dot is inside the circle but the marker does not glow, confirm the
walk is recording and the phone has a fresh fix with accuracy within 20 metres.
The preview dot can appear with poorer accuracy. Inspect the actual check-in
requests as well as the venue-list GET: location and pause requests must succeed.
UUIDs in check-in URLs accept both cases, including Swift's uppercase UUIDs;
a successful initial check-in followed by 404s must not be treated as a GPS issue.

During a server-confirmed visit, the displayed timer advances each second between
GPS receipts. The detail sheet separately shows server-verified time. Verify that
a confirmed pause freezes the timer and a new receipt reconciles it; reaching
the displayed target alone must not produce READY or credit points. Also replay
an older cached GPS fix after a newer good fix: it must not pause the visit.

For a new phone run, use real GPS and the full dwell thresholds. If recording
video, keep the original file, including time spent outside and inside. Follow local access/leash rules. For clean success cases use an
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

## Result template for a new run

For each category tested on a new build, record:

- Venue, actual date/time, build and phone/iOS version.
- Expected venue points: 12 if eligible after walk settlement.
- Actual venue points, pass/fail result and issue or evidence link.
- The original recording, if one was captured.

Add actual walking points, summary total, wallet delta and starting/ending daily
activity totals to each result. Preserve failure recordings and document fixes,
then rerun the affected flow. Link available original recordings and results to the test run. Keep existing
PR-level acceptance separate from new case observations.
