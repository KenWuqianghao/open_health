# iOS background sync

The iOS app syncs the ring without the user opening it. This page says what keeps
a sync alive, when the app syncs, what the user must do, and what iOS does not allow.

## What keeps the sync alive

- The app declares the `bluetooth-central` background mode. An active Bluetooth
  session with traffic keeps the process alive. Each delegate callback gives the
  app more time.
- The sync engine holds a short background-task assertion (`KeepAlive`) for the
  phases with no Bluetooth traffic: the pause between attempts and the post-sync
  work.
- Scheduled runs hold the `BGTask` assertion for their budget.
- The screen-awake lock (`IdleTimerLock`) is only for the user's view. It does not
  keep the app alive.

## When the app syncs

| Trigger | When | Budget |
| --- | --- | --- |
| `manual` | The user taps Sync now. | No limit. Six attempts. |
| `foreground` | The app becomes active. | Ten minutes. Two attempts. A cooldown of three minutes applies. |
| `postPair` | Pairing finished. | No limit. Reuses the pairing link. |
| `bgRefresh` | iOS runs the refresh task (about every few hours). | About 22 seconds. One attempt. Batches of 512 events. No models. |
| `bgProcessing` | iOS runs the processing task (usually at night, on charge). | Five minutes for the sync. Models run only when the device is not in Low Power Mode and has memory. |
| `bleRestore` | The ring reconnected and iOS relaunched the app. | Five minutes. Reuses the connected link. |
| HealthKit wake | Apple Health changed (the Watch synced, another app wrote) and the hub switch with Apple Health is on. | About 20 seconds. No ring sync: only the Apple Health push to the hub. |

After each run the app submits both scheduled tasks again. The sync cursor is
saved after every batch, so a run that stops early loses nothing.

After the summary is rebuilt, the app pushes it and the new ring rows to the
health hub when one is set up (see `health-hub.md`). A refresh run gives the push
8 seconds; the other runs give it 40. The push cursor is saved after every page.

## The link after a sync

The setting "After a sync" in the Sync screen has two values:

- **Keep the ring connected** (default). The app keeps the Bluetooth link and goes
  quiet. iOS can wake the app when the ring sends data. The next refresh task needs
  no connect step.
- **Release the ring after each sync**. The app disconnects and asks iOS to
  reconnect later. Use this if you also sync the same ring from the desktop client.
  The ring has one link. A wake that finds no new data waits 15 minutes before it
  asks iOS to reconnect again.

## How the app finds the ring again

When no link is up, the app "arms" two things at once:

- a pending connect on the ring's last known CoreBluetooth identifier, and
- a scan filtered on the Oura service UUID.

iOS wakes the app for either. The scan matters because an unbonded ring rotates its
Bluetooth address, and then the identifier iOS gave the ring changes. Every scan that
finds the ring saves the new identifier. All sync scans use the service filter: iOS
drops an unfiltered scan as soon as the app leaves the foreground.

A Ring 3 (Gen3) drops the link about two seconds after a configuration write, for
example the key install during pairing. The pairing keeps the key and retries over a
fresh link. A missing reply to the auth challenge counts as a link problem and is
retried; only a verdict from the ring counts as a rejected key.

## What you must do

1. Keep Background App Refresh on for Open Oura (Settings > General > Background
   App Refresh).
2. Put the ring on its charger near the iPhone for the most reliable background
   sync. A worn ring advertises only now and then.
3. Remove the official Oura app or turn off its Bluetooth permission. The ring
   holds one link at a time.
4. Unlock the phone once after a restart. The auth key is readable after the first
   unlock.

## Known limits

- iOS decides when the scheduled tasks run. "Usually" is the honest word.
- Low Power Mode delays the tasks.
- A force-quit (swipe up in the app switcher) stops all background wakes until the
  user opens the app again.
- Bluetooth off stops everything.
- The ring's radio is weak. A worn ring a few metres from the phone connects and then
  times out. Keep the phone within arm's reach for a sync.
- Apple Health writes need the phone unlocked once. A pass that runs while the
  phone is locked is deferred and finishes after the next unlock.

## How to test

1. Run the app from Xcode on a physical iPhone and pair a ring.
2. Pause in the debugger and run:
   ```
   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"md.thomas.openoura.sync.refresh"]
   ```
   Then resume. The Sync screen lists the run with `trigger=bgRefresh`.
3. Repeat with `md.thomas.openoura.sync.processing`, and with
   `_simulateExpirationForTaskWithIdentifier:` while a drain runs.
4. Background the app, stop it from Xcode (not a swipe-kill), take the ring off the
   charger and put it back. The app relaunches and the Sync screen shows a run with
   `trigger=bleRestore`.
5. Lock the phone and repeat step 4. The run line shows `key=true`.
