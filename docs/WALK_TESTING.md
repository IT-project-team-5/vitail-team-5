# Walk tracking: iPhone test checklist

Status: **MVP checkpoint; full device verification pending**. An initial outdoor
iPhone test and local-history export have been reviewed. This does not complete
the lock-screen, recovery and permission checklist below; a simulator or attached
debugger also does not prove continued GPS tracking on a locked iPhone.

## Known MVP limitation

The initial field test exposed implausible GPS position jumps that can inflate
the displayed and saved distance. The tracker currently accepts fixes based on
reported accuracy and timestamps, without rejecting sudden jumps. This is a known
measurement limitation accepted for this MVP checkpoint on 2026-09-09; spike
handling and regression tests are deferred to the next iteration. Distance must
not yet be treated as a verified basis for point awards. Real route exports and
personal device/server settings are kept outside the repository.

## Automated checks

In Xcode, select the Vitail scheme and a test simulator, then choose Product >
Test (Command-U). The 2026-09-09 simulator run completed 116 tests: 115 passed,
zero failed, and one file-protection attribute check was skipped because the
simulator did not expose it. Native snapshots also cover normal and large-text
recovery controls. These checks do not replace the real-iPhone tests below.

## What this version supports

- Select one or more dogs, then manually Start Walk while the app is in the
  foreground. Start and Resume require a fresh location with accuracy of 30 m or
  better, While Using the App permission, and Precise Location enabled. Always
  permission is not required for this foreground-started recording flow.
- An active walk requests background updates with a visible system location
  indicator. Automatic Core Location pausing is disabled while recording.
  Changing owner tabs does not end the walk.
- Pause and Finish turn off background recording. A visible Walk page can still
  show a foreground location preview. Permission loss, restricted access, or
  disabling Precise Location pauses the walk; there is no general inactivity
  auto-pause or five-minute auto-end in this version.
- All points in delivered location batches are processed in time order. Invalid
  or duplicate samples are ignored. Pause/Resume, an interruption, and gaps over
  60 seconds split the route; no straight-line distance joins those gaps.
- Active time excludes manual pauses and time after recovery while still paused.
  While a walk remains in Walking, active time can include GPS signal gaps. It is
  not yet a validated points-earning or welfare-goal time measurement.
- Local checkpoints preserve the walk ID, dogs, route, distance and accumulated
  time. Reopening restores the last successful checkpoint as **Paused**. Resume
  starts a new route segment; time while the app was closed is not added.
- Finishing saves a stable record ID, so a retry after interruption does not
  create a second history entry. History and checkpoints are separate for each
  account and backend. They do not sync to the server or other devices.

## Before taking the phone outside

1. Install the current build on a real iPhone using Xcode. Note the branch/commit,
   iPhone model and iOS version in the results log.
2. Stop the Xcode debugging session, unplug the cable, and open Vitail from the
   phone's Home Screen. Do not use Xcode's simulated location for this test.
3. Connect to the backend, sign in with a test owner account, and load its dog
   profiles. If the backend runs on a Mac, use a reachable Mac LAN address or
   configured test server, not `localhost` on the phone.
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

1. Select two dogs and Start Walk. Walk for about two minutes outdoors.
2. Open Account, then Redeem, and return to Walk without signing out.
3. Confirm the walk remains Walking, the same dogs remain fixed, and the route
   and distance continue instead of resetting or starting a second walk.
4. Finish. Check date, dogs, distance, active time and route in Walk History.

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
3. Wait for a fresh accurate location and tap Resume. Walk a further section and
   Finish. Confirm history excludes paused time and has separate route sections,
   with no line or distance crossing the paused movement.
4. Lock the phone again after Finish. Background walk collection must stop. A
   foreground map preview should not be mistaken for continued background use.

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
4. Confirm the last successfully saved dogs, distance and route return as Paused
   with a recovery notice. The closed-app interval must not add time or distance.
   The unsaved tail after the last checkpoint may be missing; it is not recoverable.
5. Resume, walk another section, and Finish. Confirm the new section is not
   connected across the closed-app interval.
6. Close and reopen again. Check the finished walk appears exactly once and its
   route and total remain stable. A storage Retry action must not duplicate it.

### 6. Account isolation and sign-out

1. Start a short test walk, then sign out from Account. Background collection
   should stop; the unfinished walk remains saved for that account, paused.
2. Sign in as a different test owner on the same backend. The first owner's
   draft, participants and history must not appear.
3. Sign back in as the original owner. Check recovery is paused, then Resume or
   Finish it. Do not change a shared server or delete another person's data to
   perform this test.

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

## Limits and result log

High-accuracy continuous GPS consumes battery. Finish or Pause when not walking;
the app does not run a perpetual background location service or silently restart
a walk after force-quit. Standard iOS location indication is intentional.

These tests cover tracking and local history, not server sync, real point awards,
anti-driving checks, automatic inactivity ending, or personalised welfare rules.

| Date / build | iPhone / iOS | Test | Result | Observed issue / evidence |
|---|---|---|---|---|
| 2026-09-09 / MVP checkpoint | Real iPhone | Initial outdoor walks and exported local history | Partial evidence | Saved history is readable and distance matches the within-segment sum; implausible GPS jumps remain a known issue. Export does not include lock-screen or pause event logs. |
| Pending | — | Full physical-device checklist | Not yet completed | Add results for the remaining cases after testing |

Record route screenshots, expected versus observed pause/recovery behaviour,
backend availability, power mode and battery change. Do not label the full
background feature verified until the lock-screen and detached-debugger cases
have passed on a real phone.
