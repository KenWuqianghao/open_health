#!/usr/bin/env bash
# Pull every APK split of the Oura app from a connected Android phone and
# collect the encrypted model files (assets/*.enc) into one folder.
#
# Usage: tools/pull_oura_apk.sh [out_dir]     # default: notes/oura_apk
# Needs: adb (USB debugging on, phone authorised), unzip.
set -euo pipefail

PKG="com.ouraring.oura"
OUT="${1:-$(cd "$(dirname "$0")/.." && pwd)/notes/oura_apk}"
mkdir -p "$OUT/apks" "$OUT/enc"

echo "== devices"
adb devices -l
if ! adb get-state >/dev/null 2>&1; then
  echo "no device. Turn on USB debugging and accept the prompt on the phone." >&2
  exit 1
fi

echo "== apk paths for $PKG"
PATHS=()
while IFS= read -r line; do PATHS+=("$line"); done < <(adb shell pm path "$PKG" | tr -d '\r' | sed 's/^package://')
if [ "${#PATHS[@]}" -eq 0 ]; then
  echo "package $PKG not found on the phone" >&2
  exit 1
fi
printf '  %s\n' "${PATHS[@]}"

echo "== pull"
for p in "${PATHS[@]}"; do
  adb pull "$p" "$OUT/apks/" >/dev/null
done
ls -la "$OUT/apks"

echo "== extract *.enc from assets/"
for apk in "$OUT/apks"/*.apk; do
  unzip -qo -j "$apk" 'assets/*.enc' -d "$OUT/enc" 2>/dev/null || true
done

COUNT=$(ls -1 "$OUT/enc" 2>/dev/null | wc -l | tr -d ' ')
echo "== $COUNT encrypted files in $OUT/enc"
ls -la "$OUT/enc" || true

if [ "$COUNT" -eq 0 ]; then
  cat >&2 <<MSG
No .enc files in the installed splits. The model module may be an on-demand
feature stored in app data. Try:
  adb shell run-as $PKG find . -name '*.enc'
  adb shell run-as $PKG cat <path> > $OUT/enc/<name>
MSG
  exit 2
fi

echo
echo "next: OURA_MODEL_KEY='<base64 or hex>' python3 tools/decrypt_oura_models.py $OUT/enc"
