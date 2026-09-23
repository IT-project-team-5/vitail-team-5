# Walk tracking: iPhone test checklist

Status: **MVP checkpoint; full device verification pending**. An initial outdoor
iPhone test and local-history export have been reviewed. This does not complete
the lock-screen, recovery and permission checklist below; a simulator or attached
debugger also does not prove continued GPS tracking on a locked iPhone.

## Known MVP limitation

The 2026-09-09 field test exposed implausible GPS jumps. The integrated version
now breaks distance segments at speeds over 3 m/s and lets the backend validate
measured samples before awarding points. This is a basic sanity check, not full
GPS smoothing or anti-cheat. Local distance is still an estimate. The integrated
build needs another physical-device test; the old export does not verify it.
Real route exports and personal device/server settings stay outside the repository.

## Automated checks

In Xcode, select the Vitail scheme and a test simulator, then choose Product >
Test (Command-U). Current checks include deferred dog confirmation, zero-dog
local history, unconfirmed-summary recovery, automatic stop/logout without an
award, stable upload IDs, daily-cap estimates, and full-map/summary snapshots.
They do not replace the real-iPhone tests below.

The 2026-09-24 run for the minimal owner UI completed 203 simulator tests:
202 passed, zero failed, and one device-only file-protection check was skipped.
All 138 backend tests passed on disposable MySQL 9.3, and the unsigned Release
device build passed. Light/dark snapshots cover authentication, profiles, the
full map, finish summaries, café menus and collection; large-text snapshots cover
the main confirmation flows. Photo selection and real GPS/background behaviour
still require physical-iPhone acceptance.

The subsequent 2026-09-24 UI refinements run completed 212 simulator tests:
211 passed and the same device-only check was skipped. All 145 backend tests
passed on disposable MySQL, and the unsigned Release device build passed.
The final receipt-dismissal safeguard also passed 13 focused purchase and
presentation tests. Visual checks cover inline login, appearance settings,
play/pause controls, café menus and the automatically presented receipt.

The following counts are **historical verification records**, not results for
the current UI and finish-confirmation flow.

The 2026-09-09 simulator run completed 116 tests: 115 passed,
zero failed, and one file-protection attribute check was skipped because the
simulator did not expose it. Native snapshots also cover normal and large-text
recovery controls. These checks do not replace the real-iPhone tests below.

The 2026-09-15 integrated simulator run completed 158 tests: 157 passed, zero
failed, and one device-only file-protection check was skipped. Added checks cover
upload receipts, legacy archives, pause segments, speed jumps and inactivity.

The 2026-09-16 integration with current main completed 169 simulator tests:
168 passed, zero failed, and the same device-only check was skipped. Added
regressions cover delayed GPS inactivity, recovered inactivity windows, stale
weak fixes, concurrent Finish/upload and logout waiting, tab cancellation,
stopped-account responses, durable terminal errors and failed local saves.
All 100 backend tests passed on disposable MySQL 9.3; SQLite passed 95 and
skipped five MySQL-only checks. The unsigned Release device build also passed.

## What this version supports

- The map fills the Walk page behind a bottom menu. The menu can be expanded
  to roughly half the screen for history and walking information. Idle shows
  **Start**, Walking shows **Pause**, and Paused shows **Resume** and **Finish**.
- Tap Start while the app is in the foreground; no dog selection is required.
  Dogs are chosen in the Finish summary after recording. Start and Resume require
  a fresh location with accuracy of 30 m or better, While Using the App permission,
  and Precise Location enabled. Always permission is not required for this
  foreground-started recording flow.
- An active walk requests background updates with a visible system location
  indicator. Automatic Core Location pausing is disabled while recording.
  Changing owner tabs does not end the walk.
- Pause and Finish turn off background recording. A visible Walk page can still
  show a foreground location preview. Permission loss, restricted access, or
  disabling Precise Location pauses the walk. Five minutes without accepted
  movement, or a five-minute manual pause, ends the walk on the next timer,
  location batch or foreground/Resume check. Suspended iOS timers cannot promise
  an exact background stop time.
- All points in delivered location batches are processed in time order. Invalid
  or duplicate samples are ignored. Pause/Resume, an interruption, and gaps over
  60 seconds split the route; no straight-line distance joins those gaps.
- Active time excludes manual pauses and time after recovery while still paused.
  While a walk remains in Walking, active time can include GPS signal gaps. It is
  not yet a validated points-earning or welfare-goal time measurement.
- Local checkpoints preserve the walk ID, route, distance and accumulated time.
  Legacy checkpoints may also contain previously selected dogs; new walks do
  not choose participants until confirmation. Reopening restores the last
  successful active checkpoint as **Paused**. Resume starts a new route segment
  if the five-minute inactivity window has not expired; otherwise the next
  inactivity check stops into a pending summary. Time
  while the app was closed is not added.
- Pause → Finish stops capture and saves a pending summary outside uploadable
  history. Choose the dogs who came along, then tap **Complete walk** to confirm.
  The summary shows an estimate before confirmation and the actual receipt after
  server validation. Selecting multiple dogs does not multiply points.
- With no dogs selected, **Save without dogs · 0 pts** saves local history only;
  it does not upload a walk or award points. The record is labelled as a solo walk.
- **Later** dismisses the summary without confirming it. **Review walk** reopens
  it; starting another walk is blocked until this one is confirmed and safely
  saved. Pending summaries survive relaunch. Automatic stops and explicit logout
  also create pending summaries without selecting dogs or awarding points.
- A stable record ID prevents duplicate history and credits on retry. History
  and checkpoints are separate for each account and backend. Raw routes and
  checkpoints remain local. Only confirmed eligible records upload; awarded
  points and accepted distance come from the server. Old confirmed records keep
  their retry behavior, while records without measured accuracy/source metadata
  stay local.

## Before taking the phone outside

1. Install the current build on a real iPhone using Xcode. Note the branch/commit,
   iPhone model and iOS version in the results log.
2. Stop the Xcode debugging session, unplug the cable, and open Vitail from the
   phone's Home Screen. Do not use Xcode's simulated location for this test.
3. Connect to the backend, sign in with a test owner account, and add or verify
   its dog profiles for the later confirmation step. If the backend runs on a
   Mac, use a reachable Mac LAN address or configured test server, not `localhost`
   on the phone.
4. Enable Location Services and allow Vitail to use location **While Using the
   App**, with **Precise Location** on. Wait for an accurate position outdoors.
5. Ensure the iPhone has been unlocked at least once since its last restart.
   Checkpoint protection allows locked-screen writes after that first unlock;
   it does not enable automatic tracking before the first unlock or after reboot.
6. Start a walk before leaving the backend's network. Once started, GPS recording
   and local saving do not need that server. Sign-in, dog-list refresh, and login
   restoration after reopening may still need it. This is not a complete offline
   authentication workflow. Map imagery may also depend on network availability.

Use test data and a safe, familiar route. Stop walking before interacting with
the screen. Exact distance will vary with GPS conditions; compare the overall
route and distance trend, not centimetre-level accuracy.

## Device tests

### 1. Foreground baseline and tab changes

1. Tap Start without selecting dogs. Walk for about two minutes outdoors.
2. Open Account, then Redeem, and return to Walk without signing out.
3. Confirm the walk remains Walking, with Pause as its only main action, and the
   route and distance continue instead of resetting or starting a second walk.
4. Tap Pause, then Finish. Check the summary's distance and active time. No new
   walking award or confirmed history record should appear yet.
5. Select two dogs and tap Complete walk. Check date, both dogs, distance, active
   time and route in Walk History. Check the actual point receipt when online.
6. Expand/collapse the bottom menu by dragging its handle or tapping it. The map
   should remain visible, with history reachable inside the expanded menu.

### 2. Screen locked and other apps open

1. Start a new walk with Xcode disconnected.
2. Lock the phone and walk for at least five minutes along a recognisable route
   with several turns. Unlock and check the route before finishing.
3. Repeat with another app in the foreground for several minutes.
4. Confirm movement during each background period appears in the recorded route
   and contributes to distance. It should not consist only of a straight line
   between the last visible screen position and the return position.
5. Confirm the iPhone shows its system location-use indication while recording.
   Note battery level before/after, test length and any Low Power Mode setting.

A gap in a route can mean no usable GPS samples were delivered; it is not proof
that the app recorded the missing path. Document such gaps rather than assuming
the test passed because the total distance changed.

### 3. Pause, Resume and Finish

1. Walk a short section, tap Pause, then lock the phone and move somewhere else
   for about two minutes.
2. Return to Walk. Distance must remain unchanged during the pause. The visible
   map may update its current-position preview, but that is not a recorded route.
3. Wait for a fresh accurate location and tap Resume. Walk a further section,
   tap Pause, then Finish. Confirm the summary excludes paused time. Choose dogs
   and tap Complete walk; history must have separate route sections with no line
   or distance crossing the paused movement.
4. In a separate run, lock the phone after Finish but before completing its
   summary. Background capture must already have stopped; neither distance nor
   time may grow while awaiting confirmation. A foreground map preview should
   not be mistaken for continued background recording.

### 4. Permission and precise-location changes

1. During a short active walk, open iPhone Settings and turn off Vitail's Precise
   Location. Return to the app. Expect a paused/recovered walk or an access notice,
   not continued distance accumulation from approximate locations.
2. Restore Precise Location. Confirm the app does not silently restart the walk;
   wait for fresh accurate GPS and explicitly Resume.
3. Repeat by denying Vitail location permission, and separately by turning off
   global Location Services. Restore access and Resume manually.
4. Confirm Finish remains available for a paused walk even without fresh GPS.

Changing privacy settings can cause iOS to relaunch the app. In that case, follow
the recovery checks below and ensure the last checkpoint is shown as Paused.

### 5. Force-quit, recovery and stable history

1. Start a short walk and wait until route points and distance have appeared.
2. Force-quit Vitail from the app switcher. Wait or move for about two minutes.
   **The app cannot keep tracking after a user force-quit.**
3. Reopen Vitail, reconnecting to the backend if login restoration needs it.
4. Confirm the last successfully saved distance and route return as Paused
   with a recovery notice. The closed-app interval must not add time or distance.
   The unsaved tail after the last checkpoint may be missing; it is not recoverable.
5. Resume within the five-minute inactivity window, walk another section, then
   Pause → Finish. Confirm the new section is not connected across the closed-app
   interval. Choose dogs and tap Complete walk before checking confirmed history.
6. Separately reopen after the inactivity window and confirm the recovered walk
   stops into a pending summary instead of restarting its inactivity timer.
   Refreshing must not award this walk before explicit completion.
7. After confirmation, close and reopen again. Check history contains the walk
   exactly once and its route and total remain stable. Storage or upload Retry
   must not create another record or award.

### 6. Account isolation and sign-out

1. Start a short test walk, then open Account → profile → Sign Out. Background
   capture should stop and the walk should become a protected pending summary.
   Logout must not select dogs, add this walk to uploadable history, or award it.
   Previously confirmed records may still retry before credentials clear.
2. Sign in as a different test owner on the same backend. The first owner's
   pending summary, route and history must not appear or upload under that owner.
3. Sign back in as the original owner. Open Walk and check the pending summary
   returns with the same route and duration. Choose dogs and tap Complete walk;
   only now may this record upload and earn points.
4. Separately test authentication expiry: it leaves an unfinished checkpoint
   Paused for that owner, not automatically resumed. A summary that was already
   awaiting confirmation must remain unconfirmed. Do not change a shared server
   or delete another person's data for this test.

### 7. Storage and interruptions

- Check for storage warnings after returning to the app. If one appears, keep
  the app open and use Retry; do not assume the latest in-memory route is saved.
- A corrupt or unsupported checkpoint should display a recoverable error and
  block a new walk rather than silently overwrite the original file. Exercise
  this with automated fixtures, not by editing a real user's app data.
- For a device restart check, use test data: restart, unlock once, reopen and
  restore the login session if needed. Expect checkpoint recovery as Paused,
  never an uninterrupted recorded route through shutdown.
- After the baseline succeeds, repeat locked-screen testing with Low Power Mode
  if that mode is part of the intended usage. Record differences; reliable
  continuous updates still depend on iOS scheduling, permission and GPS access.

### 8. Connected points and retry

1. Record a real walk while online, then Pause → Finish. Choose dogs and check the
   estimated points before tapping Complete walk. Only after confirmation should
   the history card show accepted distance and awarded points, and Redeem update
   its balance. Awards use cumulative daily rounding at 8 points/km, capped at
   40 points per Melbourne day; multiple dogs do not increase the award.
2. Pause for less than 60 seconds and move while paused, then Resume, walk again
   and Pause → Finish → choose dogs → Complete walk. Neither local nor server
   distance should bridge that paused movement.
3. Load the dogs in a finish summary, choose participants, then make the backend
   unreachable before tapping Complete walk. The confirmed local record must
   survive. Reopen and Retry when connected; its award must occur once. If the
   dog list cannot be loaded, leave the summary pending until online instead of
   choosing the zero-point option as an upload workaround.
4. Submit within 12 hours of starting. Pending confirmation does not extend this
   limit; rejected late records retain their local route and earn no points.
5. Stay stationary or manually paused until the five-minute inactivity window
   expires, then return to Walk. Capture must stop into a pending summary, and
   later movement must not extend it. Refresh/Retry must not award anything
   until dogs are chosen and Complete walk is pressed.
6. Confirm legacy history remains readable without retrospective awards. A
   simulator-generated walk must not earn points. Do not remove its source flag.
7. Use earned points for a test order and verify the owner collection and café
   order views still agree. Redeem's coffee equivalent uses 60 points per cup;
   that estimate does not change either the walking rate or menu prices.

### 9. Pending summary recovery and zero-dog completion

1. Start a walk, record a short route, then Pause → Finish. Tap Later. The panel
   should offer Review walk and prevent a new Start until this walk is resolved.
2. Force-quit and reopen. Review the same pending summary: distance, time and
   route must remain unchanged, without a new credit or confirmed history item.
   Dog selections are made in the summary; verify the intended dogs again.
3. Refresh, switch tabs and retry storage before completing it. None of those
   actions may confirm the walk or send it for points. Choose dogs and tap
   Complete walk once; repeated taps/retries must not create another award.
4. In another run, leave every dog unselected and tap Save without dogs · 0 pts.
   Expect one solo-walk entry with its route/time preserved, no upload, and no
   points added to the wallet. Reopening or refreshing must not later award it.
5. Confirm another walk can start after the zero-dog record is safely saved.

## Limits and result log

Drawer interaction check: drag the handle from collapsed to expanded and back.
The controls, slogan and history should move together. Once expanded, scroll the
content until the controls leave the viewport; collapsing should return to the
controls. Repeat with large text and a paused walk to confirm Resume and Finish
remain reachable.

High-accuracy continuous GPS consumes battery. Finish or Pause when not walking;
the app does not run a perpetual background location service or silently restart
a walk after force-quit. Standard iOS location indication is intentional.

This checklist covers tracking, local history and the integrated distance-award
flow. It does not validate advanced anti-cheat or personalised welfare rules.

| Date / build | iPhone / iOS | Test | Result | Observed issue / evidence |
|---|---|---|---|---|
| 2026-09-09 / MVP checkpoint | Real iPhone | Initial outdoor walks and exported local history | Partial evidence | Saved history is readable and distance matches the within-segment sum; implausible GPS jumps remain a known issue. Export does not include lock-screen or pause event logs. |
| 2026-09-24 / drawer and receipt refinements | iPhone 17 Pro simulator / iOS 26.2 | 83 affected iOS tests, including drawer geometry, shared scroll hierarchy, redemption and café order compatibility; light/dark and large-text snapshots | Passed | Snapshot inspection confirms shared drawer scrolling and reachable controls. This is not evidence of physical-device gestures or background GPS behaviour. |
| Pending | — | Full physical-device checklist | Not yet completed | Add results for the remaining cases after testing |

Record route screenshots, expected versus observed pause/recovery behaviour,
backend availability, power mode and battery change. Do not label the full
background feature verified until the lock-screen and detached-debugger cases
have passed on a real phone.
