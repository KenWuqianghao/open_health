# Open Oura for iOS — build, install, pair, sync

The iOS app talks to an Oura ring over Bluetooth without an Oura account. It pairs
the ring on the phone, pulls the ring's history into a local SQLite database,
computes the metrics on the phone, and writes the measured data to Apple Health.
Nothing leaves the phone unless you connect your own hub.

This page is the full path from a clean Mac to a synced ring. Follow it in order.

## What you need

| Item | Notes |
| --- | --- |
| Mac with Xcode 26 or newer | The iOS 26 SDK. Install the iOS simulator platform when Xcode asks. |
| `xcodegen` | `brew install xcodegen`. It turns `project-ci.yml` into the Xcode project. |
| Rust 1.93 or newer | `rustup update stable`. The build script adds the two iOS targets. |
| An iPhone with iOS 17 or newer | Plus a USB cable. Bluetooth does not work in the simulator. |
| An Apple ID | A free Apple ID gives a "Personal Team". That is enough to install the app on your own phone for 7 days at a time. TestFlight needs the paid program. |
| An Oura ring and its charger | Ring 3, 4, and 5 use the same protocol. The app pairs only a factory-reset ring. |

Remove the official Oura app from the phone, or turn off its Bluetooth permission.
The ring keeps one link at a time.

## Quick path: one command

On the phone, turn on Settings → Privacy & Security → Developer Mode and restart. In
Xcode → Settings → Accounts, add your Apple ID once. Connect the phone with the cable,
unlock it, and tap **Trust**. Then:

```bash
git clone https://github.com/KenWuqianghao/open_health.git && cd open_health && ./apps/ios/install.sh
```

The script installs `xcodegen` and Rust 1.93 when they are missing, builds the Rust
core, generates the Xcode project, finds your team and your iPhone, signs, installs,
and launches the app. It keeps the team and the bundle identifier in
`apps/ios/.install.env`. Run it again every 7 days (free Apple ID) or after a pull.
`./apps/ios/install.sh --check` checks the tools, the team, and the phone without a
build. On the first launch, trust your Apple ID on the phone (see
[First launch](#first-launch)), then go to [4. Prepare the ring](#4-prepare-the-ring).

Steps 1 to 3 below are what the script does, for a build by hand.

## 1. Clone and build the Rust core

```bash
git clone https://github.com/KenWuqianghao/open_health.git
cd open_health
./apps/ios/build-xcframework.sh
```

The script builds `oura-core` for the device and the simulator, regenerates the
Swift bindings in `apps/ios/generated/`, and writes `apps/ios/OuraCore.xcframework`.
Both outputs are ignored by git. Run the script again after every change to the Rust
code.

If your default Rust toolchain is older than 1.93, run
`RUSTUP_TOOLCHAIN=1.93.0 ./apps/ios/build-xcframework.sh`.

## 2. Generate the Xcode project

```bash
cd apps/ios/OuraApp
xcodegen generate --spec project-ci.yml
```

`project-ci.yml` is the model-free app. `project.yml` adds the on-device PyTorch
models and needs LibTorch plus model files that are not in this repository. Start with
`project-ci.yml`.

## 3. Sign and install on your iPhone

On the phone: Settings → Privacy & Security → Developer Mode → on, then restart. Connect
the phone with the cable and tap "Trust" when the phone asks.

### With Xcode

1. Open `OuraApp.xcodeproj`.
2. Select the `OuraApp` target → Signing & Capabilities. Pick your Team. Change the
   bundle identifier to one you own, for example `com.yourname.openoura`.
3. Select your iPhone as the run destination and press Run.

### From the command line

Find the phone's identifiers:

```bash
xcodebuild -project OuraApp.xcodeproj -scheme OuraApp -showdestinations | grep iOS
xcrun devicectl list devices
```

`xcodebuild` wants the hardware id (`00008130-…`); `devicectl` wants the CoreDevice
id (the UUID). Then:

```bash
xcodebuild -project OuraApp.xcodeproj -scheme OuraApp \
  -destination 'platform=iOS,id=<hardware id>' -configuration Debug \
  -derivedDataPath build/DerivedData-device \
  DEVELOPMENT_TEAM=<your team id> PRODUCT_BUNDLE_IDENTIFIER=com.yourname.openoura \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

```bash
xcrun devicectl device install app --device <coredevice id> \
  build/DerivedData-device/Build/Products/Debug-iphoneos/OuraApp.app
xcrun devicectl device process launch --device <coredevice id> com.yourname.openoura
```

Your Team ID is in Xcode → Settings → Accounts, or at developer.apple.com → Membership.
The two overrides keep the repository files unchanged.

### First launch

The phone refuses the first launch of an app from a Personal Team. Open Settings →
General → VPN & Device Management, tap your Apple ID under "Developer App", and tap
Trust. Launch the app again.

Turn on Settings → General → Background App Refresh for Open Oura.

## 4. Prepare the ring

1. If the ring was used with the official app, open that app once so it syncs the
   ring's buffer. A factory reset erases what is still on the ring.
2. Delete the official Oura app from the phone.
3. On the phone, open Settings → Bluetooth. If an Oura ring is listed under "My
   Devices", tap its info button and choose Forget This Device. An old bond makes every
   connection fail with "Peer removed pairing information".
4. Factory-reset the ring. The charger-flip method needs no button and works on the
   Gen3 and Ring 4 dock: take the ring off the charger, put it back, wait about two
   seconds, then flip the charger with the ring on it: upside down until the light is
   blue, right side up until red, upside down until purple, right side up until yellow.
   Yellow means the reset started. After a few minutes the light blinks blue and the
   reset is complete. The full procedure, with the protocol alternative, is in
   [open_oura `docs/factory-reset.md`](https://github.com/KenWuqianghao/open_oura/blob/main/docs/factory-reset.md).
5. Do not set the ring up in the official app again. That installs Oura's key and locks
   this app out until the next reset.
6. Put the ring on its charger right next to the iPhone.

## 5. Pair in the app

1. Open Open Oura. Allow Bluetooth when the phone asks.
2. Tap **Scan for rings**. A reset ring shows as "Oura" plus its serial, or with no
   name. Both are normal.
3. Tap the ring. The app asks the ring who owns it.
4. On **Ready to pair**, tap **Pair**. The app makes a 16-byte key on the phone, stores it
   in the Keychain, installs it on the ring, sets the ring clock, and turns on daytime
   heart rate and blood oxygen.
5. **Paired** appears and the first sync starts. Keep the app open until it finishes.

A Ring 3 drops the Bluetooth link once, about two seconds after it takes the key. The
app reconnects and finishes the setup by itself. The status line shows it.

The key never leaves the phone. Settings → Ring → **Show auth key** reveals it, so the
desktop client in `open_oura` can use the same ring (`oura --key-file`). If the key is
lost, the ring needs another factory reset.

## 6. Apple Health

Tap the profile icon → Apple Health → turn on **Write ring data to Apple Health** →
**Turn On All** → **Allow**.

The app writes only measured data: in-bed time and sleep stages (stages need the
on-device models), heart rate per minute, resting heart rate, HRV (SDNN, only when
measured), breathing rate and blood oxygen during sleep, steps (a MET estimate), active
energy, and resting energy if you turn it on. Workouts come with the models.

Not written: readiness, sleep and activity scores, skin temperature, distance.

Every day is deleted and rewritten as one unit, so a second export never duplicates.
**Remove Open Oura data from Health** deletes everything the app wrote.

## Optional: your own health hub

The [oura-hub](https://github.com/KenWuqianghao/oura-hub) keeps a copy of your data on
a server that is always on, and lets an AI agent read it over MCP. Install it with
`./deploy/install.sh` on the server, open the sign-in link it prints, and scan the QR
code on its **Connect** page with the Camera. The app asks, then sends the ring data
after every sync. Tap **Include Apple Health data** in Settings → Health hub to add
the Apple Watch.

## 7. Day to day

- Wear the ring. It records heart rate, blood oxygen, temperature, and movement while
  worn. Sleep appears after the first night.
- Open the app near the ring to sync. The app also syncs in the background when iOS
  lets it; see [`docs/ios-background-sync.md`](../../docs/ios-background-sync.md).
- Keep the phone within arm's reach of the ring during a sync. The ring's radio is
  weak; a few metres away the link connects and then times out.
- A Personal Team install expires after 7 days. Build and install again; the data on
  the phone stays.

## Optional: the on-device models

Sleep stages, cardiovascular age, workout detection, the Ring 5 step decoder, and
illness detection run Oura's own TorchScript models on the phone. They are Oura's
proprietary files and are not in this repository. Without them the app still
syncs, shows in-bed time, heart rate, blood oxygen, steps, and energy, and exports
all of that to Apple Health.

1. Put the decrypted models in `notes/models/` (ignored by git). This repository's
   `tools/pull_oura_apk.sh` and `tools/decrypt_oura_models.py` produce them from the
   official app on your own phone and your own account; the key is read from the
   `OURA_MODEL_KEY` environment variable and is never written to disk.
2. Export the lite-interpreter files the app bundles:
   ```bash
   python3 tools/export_mobile.py
   ```
   It writes `notes/models/mobile/*.ptl` and pins the versions the iOS bridge
   implements: `sleepnet_moonstone_1_2_0`, `cva_2_1_5`,
   `automatic_activity_detection_3_1_12`, `steps_motion_decoder_2_0_0`,
   `illness_detection_0_5_1`.
3. Build LibTorch for iOS once (it compiles PyTorch 2.9; count on an hour per slice
   and about 8 GB of disk for the source plus each slice). The device slice is
   enough for a phone; the simulator slice adds simulator runs of the torch build:
   ```bash
   ./apps/ios/spike/build_libtorch_ios.sh device
   ./apps/ios/spike/build_libtorch_ios.sh          # optional, simulator
   ./apps/ios/package-libtorch-xcframeworks.sh
   ```
4. Generate the torch project and build it the same way as above:
   ```bash
   cd apps/ios/OuraApp && xcodegen generate --spec project.yml
   ```
   The app then writes sleep stages and workouts to Apple Health as well.

## Troubleshooting

| What you see | Cause | Fix |
| --- | --- | --- |
| "Peer removed pairing information" | The phone still holds an old Bluetooth bond from the official app. | Settings → Bluetooth → Forget This Device, then try again. |
| "Reset needed" | The ring holds another key. | Factory-reset the ring. Do not set it up in the official app. |
| "no ring found" | The ring is out of range, asleep off its charger, or linked to another phone. | Ring on its charger next to the iPhone; official app removed. |
| "another app on this phone holds the ring" | Another app has the Bluetooth link. | Remove the official Oura app or turn off its Bluetooth permission. |
| "The connection has timed out unexpectedly" | Weak signal. | Move the phone next to the ring. |
| "Unable to launch … profile has not been explicitly trusted" | First launch of a Personal Team build. | Trust the developer in Settings → General → VPN & Device Management. |
| The app will not open after a week | Personal Team builds expire after 7 days. | Install again from Xcode or the command line. |

The app keeps a transcript at `Library/Application Support/diagnostics/session.log`
inside its container. Every Bluetooth step, sync run, and Health pass is in it. Pull it
from a connected phone with:

```bash
xcrun devicectl device copy from --device <coredevice id> \
  --domain-type appDataContainer --domain-identifier com.yourname.openoura \
  --source "Library/Application Support/diagnostics/session.log" --destination session.log
```

## Run the tests

```bash
cargo test --workspace
cd apps/ios/OuraApp && xcodebuild -project OuraApp.xcodeproj -scheme OuraApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The simulator has no Bluetooth. To see the screens with data, copy an `oura.db` into
the simulator app container at `Library/Application Support/oura.db`
(`xcrun simctl get_app_container booted <bundle id> data`).

## Where the code lives

| File | Role |
| --- | --- |
| `RingCentral.swift` | The one `CBCentralManager`: scan, connect, arm, park, state restoration. |
| `BLETransport.swift` | One GATT link: subscribe, write, frame stream to Rust. |
| `SyncCoordinator.swift` | The only code that syncs. One run at a time, per-trigger budgets, metrics. |
| `RingPairing.swift`, `Pairing.swift` | On-device pairing: probe, key install, retry, first sync. |
| `BackgroundSync.swift` | `BGTaskScheduler` registration and handlers. |
| `HealthPlanner.swift`, `HealthExporter.swift`, `HealthStoreClient.swift` | Apple Health export: plan, idempotent delete-then-write, state. |
| `HubPush.swift` | The hub: settings, the `openoura://hub` connect link and its prompt, the summary and ring-row pushes. |
| `HealthReader.swift`, `HealthBackground.swift` | Apple Health reads for the hub: anchored queries and background delivery. |
| `Theme.swift`, `Components.swift` | The design tokens and shared views. |
| `../../crates/oura-core` | The Rust FFI: pair, sync, cancel, health samples. |
| `../../crates/oura-summary` | The shared summary and the Apple Health sample brain. |

The protocol, the BLE client, the storage, and the metric algorithms live in
[open_oura](https://github.com/KenWuqianghao/open_oura).
