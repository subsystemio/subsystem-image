#!/usr/bin/env bash
# Write ONE app onto a freshly-flashed DietPi card, from macOS/Linux.
#
#   cd apps/tile-puzzle && npm run flash
#   ./image/prepare-sd.sh apps/tile-puzzle /Volumes/bootfs
#
# Everything lands on the FAT boot partition, the only part of the card writable from a Mac.
# DietPi picks it up on first boot.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/app-config.sh"
resolve_app "${1:-.}"

PAYLOAD="$APP_DIR/subsystem-payload.tar.gz"
PASSWORD="${PASSWORD:-dietpi}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_KEY="${WIFI_KEY:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-GB}"

VOL="${2:-}"
if [ -z "$VOL" ]; then
  VOL="$(dirname "$(ls -1 /Volumes/*/dietpi.txt 2>/dev/null | head -1)")"
fi
[ -f "$VOL/dietpi.txt" ] || { echo "no dietpi.txt found — pass the boot volume path as the 2nd arg"; exit 1; }
[ -f "$PAYLOAD" ] || { echo "no payload — run 'npm run image' in $APP_DIR first"; exit 1; }

# Replace KEY=... in place (commented or not), or append it. Matched literally so keys containing
# regex metacharacters — aWIFI_SSID[0] — behave.
inject () { # key value file
  local k="$1" v="$2" f="$3"
  touch "$f"
  awk -v k="$k" -v v="$v" '
    !done {
      line = $0
      sub(/^[[:blank:]]*#?[[:blank:]]*/, "", line)
      eq = index(line, "=")
      if (eq > 0) {
        lhs = substr(line, 1, eq - 1)
        key = lhs
        gsub(/[[:blank:]]+$/, "", key)
        if (key == k) {
          pad = (lhs == key) ? "" : " "   # keep the file'"'"'s own spacing style
          print k pad "=" pad v
          done = 1
          next
        }
      }
    }
    { print }
    END { if (!done) print k "=" v }
  ' "$f" > "$f.new" && mv "$f.new" "$f"
}

echo "==> $APP -> $VOL  (port=$PORT reset-after=${RESET_AFTER}s ${RES_X}x${RES_Y})"
inject AUTO_SETUP_AUTOMATED              1                        "$VOL/dietpi.txt"
inject AUTO_SETUP_GLOBAL_PASSWORD        "$PASSWORD"              "$VOL/dietpi.txt"
inject AUTO_SETUP_INSTALL_SOFTWARE_ID    "6 113"                  "$VOL/dietpi.txt"
inject AUTO_SETUP_AUTOSTART_TARGET_INDEX 11                       "$VOL/dietpi.txt"
inject SOFTWARE_CHROMIUM_AUTOSTART_URL   "http://127.0.0.1:$PORT" "$VOL/dietpi.txt"
inject SOFTWARE_CHROMIUM_RES_X           "$RES_X"                 "$VOL/dietpi.txt"
inject SOFTWARE_CHROMIUM_RES_Y           "$RES_Y"                 "$VOL/dietpi.txt"
inject AUTO_SETUP_BOOT_WAIT_FOR_NETWORK  0                        "$VOL/dietpi.txt"

if [ -n "$WIFI_SSID" ]; then
  echo "==> wifi: $WIFI_SSID"
  inject AUTO_SETUP_NET_WIFI_ENABLED      1               "$VOL/dietpi.txt"
  inject AUTO_SETUP_NET_WIFI_COUNTRY_CODE "$WIFI_COUNTRY" "$VOL/dietpi.txt"
  inject 'aWIFI_SSID[0]' "'$WIFI_SSID'" "$VOL/dietpi-wifi.txt"
  inject 'aWIFI_KEY[0]'  "'$WIFI_KEY'"  "$VOL/dietpi-wifi.txt"
fi

# Two separate things, doing two separate jobs.
#   ROOM   — the shared secret. Finds the room and proves membership. Watching needs only this.
#   ADMINS — PUBLIC keys allowed to COMMAND this subsystem. Public, so the card carries no admin power.
ROOM="${ROOM:-}"
if [ -z "$ROOM" ] && [ -f "${SUBSYSTEM_KEYS:-.}/.room-key" ]; then
  ROOM="$(tr -d '[:space:]' < "${SUBSYSTEM_KEYS:-.}/.room-key")"
fi
ADMINS="${ADMINS:-}"
if [ -z "$ADMINS" ] && [ -f "${SUBSYSTEM_KEYS:-.}/.controller-key" ]; then
  ADMINS="$(tr -d '[:space:]' < "${SUBSYSTEM_KEYS:-.}/.controller-key")"
fi
[ -n "$ROOM" ] && echo "==> room:   ${ROOM:0:16}…"
[ -n "$ADMINS" ] && echo "==> admins: ${ADMINS:0:16}…"

cat > "$VOL/subsystem.conf" <<EOF
APP=$APP
PORT=$PORT
RESET_AFTER=$RESET_AFTER
EOF

echo "==> copying payload and first-boot script"
cp "$PAYLOAD" "$VOL/subsystem-payload.tar.gz"
cp "$HERE/Automation_Custom_Script.sh" "$VOL/Automation_Custom_Script.sh"

# Art lives here, not in the payload: this partition is FAT, so you can pop the card into a laptop
# and swap the puzzle image or reward video without rebuilding or reflashing.
echo "==> copying media"
rm -rf "$VOL/subsystem-media"
mkdir -p "$VOL/subsystem-media"
if [ -d "$APP_DIR/media" ]; then
  cp -R "$APP_DIR/media/." "$VOL/subsystem-media/"
  ls -1sh "$VOL/subsystem-media" | tail -n +2 | sed 's/^/    /'
fi

touch "$VOL/subsystem-media/config.txt"
[ -n "$ROOM" ] && inject room "$ROOM" "$VOL/subsystem-media/config.txt"
[ -n "$ADMINS" ] && inject admins "$ADMINS" "$VOL/subsystem-media/config.txt"
if [ -z "$ROOM" ]; then
  echo "    (no room secret — this subsystem will run unwatched)"
fi

sync
echo
df -h "$VOL" | tail -1
echo "ready — eject the card and boot it. First boot takes a few minutes (DietPi installs Chromium)."
