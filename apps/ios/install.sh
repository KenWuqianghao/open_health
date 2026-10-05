#!/usr/bin/env bash
# Build Open Oura and install it on the iPhone connected to this Mac, in one command.
#
#   ./apps/ios/install.sh
#   ./apps/ios/install.sh --check   # only check the tools, the team, and the iPhone
#
# It checks the tools, builds the Rust core, generates the Xcode project, finds
# your Apple team and your iPhone, signs, installs, and launches the app. Run it
# again every 7 days with a free Apple ID (Personal Team builds expire); the data
# on the phone stays.
#
# Overrides (else detected, then saved in apps/ios/.install.env for the next run):
#   TEAM_ID=ABCDE12345   your Apple team (Xcode → Settings → Accounts)
#   BUNDLE_ID=com.you.openoura
#   DEVICE=<name or id>  which iPhone, when more than one is connected
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
IOS="$REPO/apps/ios"
APPDIR="$IOS/OuraApp"
SAVED="$IOS/.install.env"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# Values from the last run, unless the environment gives new ones.
if [ -f "$SAVED" ]; then
  while IFS='=' read -r k v; do
    case "$k" in TEAM_ID|BUNDLE_ID) [ -z "${!k:-}" ] && printf -v "$k" '%s' "$v" ;; esac
  done < "$SAVED"
fi

# ── 1. tools ──
command -v xcodebuild >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1 \
  || die "Install Xcode from the App Store, open it once, then run: sudo xcode-select -s /Applications/Xcode.app"
if ! command -v xcodegen >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || die "Install Homebrew (https://brew.sh), then run this again."
  say "installing xcodegen"
  brew install xcodegen
fi
command -v rustup >/dev/null 2>&1 || die "Install Rust: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
rustup toolchain list | grep -q '^1\.93\.0' || { say "installing Rust 1.93.0"; rustup toolchain install 1.93.0 --profile minimal; }
export RUSTUP_TOOLCHAIN=1.93.0

# ── 2. Apple team ──
if [ -z "${TEAM_ID:-}" ]; then
  # Xcode keeps the teams of the signed-in Apple IDs here. Take the first one.
  TEAM_ID=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | sed -n 's/.*teamID = \([A-Z0-9]\{10\}\);.*/\1/p' | head -1 || true)
fi
[ -n "${TEAM_ID:-}" ] || die "No Apple team found. Open Xcode → Settings → Accounts, add your Apple ID, then run this again (or set TEAM_ID=...)."
if [ -z "${BUNDLE_ID:-}" ]; then
  who=$(id -un | tr -cd 'a-zA-Z0-9' | tr 'A-Z' 'a-z')
  BUNDLE_ID="com.${who:-me}.openoura"
fi
printf 'TEAM_ID=%s\nBUNDLE_ID=%s\n' "$TEAM_ID" "$BUNDLE_ID" > "$SAVED"
say "team $TEAM_ID, bundle id $BUNDLE_ID"

# ── 3. iPhone ──
JSON=$(mktemp)
trap 'rm -f "$JSON"' EXIT
xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || die "devicectl failed. Is Xcode 15 or newer selected?"
# One line per real iPhone/iPad that is reachable: coredevice-id|udid|name|pairing|developer mode
PHONES=$(/usr/bin/python3 - "$JSON" "${DEVICE:-}" <<'PY'
import json, sys
want = sys.argv[2].lower()
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    h, c, p = d["hardwareProperties"], d["connectionProperties"], d["deviceProperties"]
    if h.get("platform") != "iOS" or h.get("reality") != "physical" or c.get("tunnelState") == "unavailable":
        continue
    if want and want not in (d["identifier"].lower(), h.get("udid", "").lower(), p.get("name", "").lower()):
        continue
    print(f'{d["identifier"]}|{h.get("udid", "")}|{p.get("name", "")}|{c.get("pairingState", "")}|{p.get("developerModeStatus", "")}')
PY
)
if [ -z "$PHONES" ]; then
  die "No iPhone found. Connect it with its cable and unlock it, then run this again."
fi
if [ "$(printf '%s\n' "$PHONES" | wc -l)" -gt 1 ]; then
  warn "More than one iPhone is connected:"
  printf '%s\n' "$PHONES" | cut -d'|' -f3 | sed 's/^/     /' >&2
  die "Pick one with DEVICE=\"<name>\" $0"
fi
IFS='|' read -r CORE_ID UDID PHONE_NAME PAIRING DEVMODE <<< "$PHONES"

if [ "$PAIRING" != "paired" ]; then
  say "\"$PHONE_NAME\" does not trust this Mac yet"
  say "on the iPhone: unlock it, tap Trust when it asks \"Trust This Computer?\", and enter the passcode"
  xcrun devicectl manage pair --device "$CORE_ID" >/dev/null 2>&1 \
    || die "The iPhone did not confirm. Unlock it, unplug the cable and plug it in again, then run this again. Tap Trust when the iPhone asks."
  say "\"$PHONE_NAME\" trusts this Mac"
  DEVMODE=$(xcrun devicectl list devices --json-output - 2>/dev/null | /usr/bin/python3 -c '
import json, sys
for d in json.load(sys.stdin)["result"]["devices"]:
    if d["identifier"] == sys.argv[1]: print(d["deviceProperties"].get("developerModeStatus", ""))
' "$CORE_ID" || true)
fi

if [ "$DEVMODE" != "enabled" ]; then
  die "Turn on Developer Mode on \"$PHONE_NAME\", then run this again:
     1. Keep the iPhone unlocked on the cable. If the switch in step 3 is not there,
        open Xcode → Window → Devices and Simulators and wait until the iPhone shows.
     2. Close Settings fully on the iPhone (swipe it away in the app switcher).
     3. Settings → Privacy & Security → Developer Mode (at the bottom) → on → Restart.
     4. After the restart, unlock the iPhone, tap Turn On, and enter the passcode."
fi
say "iPhone: $PHONE_NAME"
if [ "$CHECK" = 1 ]; then say "ready to install (run without --check)"; exit 0; fi

# ── 4. Rust core ──
# Every local crate that cargo builds: the workspace, and the [patch] paths into
# ../open_oura during local work. Git dependencies change only through Cargo.lock.
CRATE_DIRS=$(cargo metadata --format-version 1 --manifest-path "$REPO/Cargo.toml" 2>/dev/null | /usr/bin/python3 -c '
import json, os, sys
for p in json.load(sys.stdin)["packages"]:
    if p["source"] is None: print(os.path.dirname(p["manifest_path"]))
' || true)
[ -n "$CRATE_DIRS" ] || CRATE_DIRS="$REPO/crates"
CHANGED=""
if [ -d "$IOS/OuraCore.xcframework" ]; then
  # shellcheck disable=SC2086
  CHANGED=$(find $CRATE_DIRS "$REPO/Cargo.toml" "$REPO/Cargo.lock" -path '*/target' -prune -o \
    -type f -newer "$IOS/OuraCore.xcframework" -print -quit 2>/dev/null || true)
fi
if [ ! -d "$IOS/OuraCore.xcframework" ] || [ -n "$CHANGED" ]; then
  say "building the Rust core (the first build takes a few minutes)"
  "$IOS/build-xcframework.sh"
else
  say "Rust core is up to date"
fi

# ── 5. Xcode project ──
say "generating the Xcode project"
(cd "$APPDIR" && xcodegen generate --spec project-ci.yml --quiet)

# ── 6. build, install, launch ──
say "building and signing (Xcode may ask for your Mac password to use the signing key)"
LOG="$APPDIR/build/install-build.log"
mkdir -p "$APPDIR/build"
if ! xcodebuild -project "$APPDIR/OuraApp.xcodeproj" -scheme OuraApp \
    -destination "platform=iOS,id=$UDID" -configuration Debug \
    -derivedDataPath "$APPDIR/build/DerivedData-device" \
    DEVELOPMENT_TEAM="$TEAM_ID" APP_BUNDLE_ID="$BUNDLE_ID" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > "$LOG" 2>&1; then
  grep -E "error:|No Accounts|No profiles|provisioning" "$LOG" | head -15 >&2 || true
  die "The build failed. Full log: $LOG"
fi
APP="$APPDIR/build/DerivedData-device/Build/Products/Debug-iphoneos/OuraApp.app"

locked() {
  xcrun devicectl device info lockState --device "$CORE_ID" -q --json-output - 2>/dev/null \
    | /usr/bin/python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin)["result"]["passcodeRequired"] else 1)'
}
if locked; then
  say "unlock \"$PHONE_NAME\" and keep the screen on until the app opens (waiting up to 3 minutes)"
  for _ in $(seq 60); do locked || break; sleep 3; done
  locked && die "The iPhone is still locked. Unlock it, keep the screen on, and run this again."
fi
xcrun devicectl device info ddiServices --device "$CORE_ID" --auto-mount-ddis -q >/dev/null 2>&1 \
  || die "The Mac could not load its developer files onto the iPhone. Unlock the iPhone, keep the screen on, and run this again. If Auto-Lock is grey, Low Power Mode is on: touch the screen from time to time."

say "installing on $PHONE_NAME"
xcrun devicectl device install app --device "$CORE_ID" "$APP" >/dev/null \
  || die "The install failed. Unlock the iPhone, keep the screen on, and run this again."
if xcrun devicectl device process launch --device "$CORE_ID" "$BUNDLE_ID" >/dev/null 2>&1; then
  say "Open Oura is running on $PHONE_NAME."
else
  warn "Installed, but iOS did not let it start. This is normal the first time:"
  warn "on the iPhone open Settings → General → VPN & Device Management,"
  warn "tap \"Apple Development: <your Apple ID>\", then tap Trust."
  warn "Then open Open Oura from the home screen."
fi

cat <<EOF

Next, on the iPhone:
  1. Sync the official Oura app one last time. Then delete it, and in
     Settings → Bluetooth forget the ring.
  2. Factory-reset the ring on its charger (see the setup guide). Do not set it
     up in the official app again.
  3. Open Open Oura, tap Scan for rings, tap your ring, tap Pair. A reset ring
     can show as "Oura <serial>".
  4. Settings → General → Background App Refresh → on for Open Oura.

A free Apple ID install stops after 7 days, on $(date -v+7d '+%A %-d %B'). Before
then, connect the iPhone and run this script again: DEVICE="$UDID" $0
EOF
