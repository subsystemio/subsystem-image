#!/usr/bin/env bash
# Write ONE app onto a freshly-flashed DietPi card, from macOS/Linux.
#
# Invoked by `subsystem-image flash`, which resolves the configuration and exports it. Do not call
# this directly — every setting it needs comes from there.
#
# Everything lands on the FAT boot partition, the only part of the card writable from a Mac.
# DietPi picks it up on first boot.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Every setting is resolved by bin/subsystem-image.js and handed down. Nothing is defaulted here —
# two places deciding what a default is, is how a card ends up configured differently to its log.
need () { for v in "$@"; do [ -n "${!v:-}" ] || { echo "$v not set — run this through \`subsystem-image\`" >&2; exit 1; }; done; }
need APP_DIR APP PORT RESET_AFTER RES_X RES_Y PASSWORD WIFI_COUNTRY
MCP="${MCP:-}"; ROOM="${ROOM:-}"; WIFI_SSID="${WIFI_SSID:-}"; WIFI_KEY="${WIFI_KEY:-}"

PAYLOAD="$APP_DIR/subsystem-payload.tar.gz"

VOL="${VOLUME:-}"
if [ -z "$VOL" ]; then
  # Two readers plugged in at once is exactly what you do when flashing a dozen cards. Picking the
  # first silently writes one device's identity onto the wrong card, discovered only in the venue.
  CANDIDATES="$(ls -1 /Volumes/*/dietpi.txt 2>/dev/null || true)"
  COUNT="$(printf '%s' "$CANDIDATES" | grep -c . || true)"
  if [ "$COUNT" -gt 1 ]; then
    echo "more than one DietPi card is mounted — name the one you mean:"
    printf '%s\n' "$CANDIDATES" | while read -r c; do echo "    --volume=$(dirname "$c")"; done
    exit 1
  fi
  VOL="$(dirname "$CANDIDATES")"
fi
[ -f "$VOL/dietpi.txt" ] || { echo "no dietpi.txt found — pass --volume=<boot partition>"; exit 1; }
[ -f "$PAYLOAD" ] || { echo "no payload — run 'subsystem-image build $APP_DIR' first"; exit 1; }

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
# 113 Chromium (6 X.Org comes with it), 58 Tailscale — so a card that goes wrong in a venue can be
# reached and fixed from anywhere, not just by whoever is standing next to it.
inject AUTO_SETUP_INSTALL_SOFTWARE_ID    "6 113 58"               "$VOL/dietpi.txt"
inject AUTO_SETUP_AUTOSTART_TARGET_INDEX 11                       "$VOL/dietpi.txt"
inject SOFTWARE_CHROMIUM_AUTOSTART_URL   "http://127.0.0.1:$PORT" "$VOL/dietpi.txt"
inject SOFTWARE_CHROMIUM_RES_X           "$RES_X"                 "$VOL/dietpi.txt"
inject SOFTWARE_CHROMIUM_RES_Y           "$RES_Y"                 "$VOL/dietpi.txt"
inject AUTO_SETUP_BOOT_WAIT_FOR_NETWORK  0                        "$VOL/dietpi.txt"

# With a key on the card, SSH refuses passwords: a venue network is full of strangers, and the
# device password is set once and rarely changed. The console login at the Pi still takes it.
if [ -n "${SSH_PUBKEY:-}" ]; then
  inject AUTO_SETUP_SSH_PUBKEY                "$SSH_PUBKEY" "$VOL/dietpi.txt"
  inject SOFTWARE_DISABLE_SSH_PASSWORD_LOGINS 1             "$VOL/dietpi.txt"
  echo "==> ssh:  key only ($(echo "$SSH_PUBKEY" | cut -d' ' -f1,3-)) — passwords refused"
else
  echo "==> ssh:  passwords allowed — no key; pass --ssh-key or set SSH_PUBKEY to refuse them"
fi

if [ -n "${WIFI_SSID:-}" ]; then
  echo "==> wifi: $WIFI_SSID"
  inject AUTO_SETUP_NET_WIFI_ENABLED      1               "$VOL/dietpi.txt"
  inject AUTO_SETUP_NET_WIFI_COUNTRY_CODE "$WIFI_COUNTRY" "$VOL/dietpi.txt"
  inject 'aWIFI_SSID[0]' "'$WIFI_SSID'" "$VOL/dietpi-wifi.txt"
  inject 'aWIFI_KEY[0]'  "'$WIFI_KEY'"  "$VOL/dietpi-wifi.txt"
  # WIFI_SSID_N fills slot N-1. DietPi has five and joins whichever network is in range.
  for n in 2 3 4 5; do
    ssid="WIFI_SSID_$n"; key="WIFI_KEY_$n"
    [ -n "${!ssid:-}" ] || continue
    echo "==> wifi: ${!ssid}"
    inject "aWIFI_SSID[$((n - 1))]" "'${!ssid}'"    "$VOL/dietpi-wifi.txt"
    inject "aWIFI_KEY[$((n - 1))]"  "'${!key:-}'"   "$VOL/dietpi-wifi.txt"
  done
fi

# The only thing a card needs in order to be managed: which MCP it answers to. It is a PUBLIC key,
# so the card carries no secret and no authority. ROOM is optional and only hides the fleet.
if [ -n "${MCP:-}" ]; then
  echo "==> mcp:  ${MCP:0:16}…"
else
  echo "==> mcp:  none — this subsystem will run, but no console will ever see it"
  echo "          run \`mcp serve\` once to mint a key, or pass --mcp=<64-hex>"
fi
[ -n "${ROOM:-}" ] && echo "==> room: ${ROOM:0:16}… (private)"

# Only what the first-boot script reads: the URL to point Chromium at, whether there is a browser
# at all, and how to join the tailnet. Everything else about the app is in services.conf. The
# first-boot script deletes the key once it has been used.
cat > "$VOL/subsystem.conf" <<EOF
PORT=$PORT
KIOSK=1
TS_HOSTNAME=$APP
EOF
if [ -n "${TS_AUTHKEY:-}" ]; then
  echo "TS_AUTHKEY=$TS_AUTHKEY" >> "$VOL/subsystem.conf"
  echo "==> tailscale: joins as $APP on first boot"
else
  echo "==> tailscale: installed, no key — run \`tailscale up\` on the device to join"
fi

# What this card wants supervised. One line per service; the first-boot script installs each with
# Restart=always. A subsystem card supervises its app and nothing else.
cat > "$VOL/services.conf" <<EOF
subsystem | Subsystem app ($APP) | /opt/subsystem/bin/bare /opt/subsystem/node_modules/@subsystemio/runtime/bin/subsystem.js /opt/subsystem/apps/$APP --port=$PORT --reset-after=$RESET_AFTER --assets=@BOOT@/subsystem-media |
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
[ -n "${MCP:-}" ] && inject mcp "$MCP" "$VOL/subsystem-media/config.txt"
[ -n "${ROOM:-}" ] && inject room "$ROOM" "$VOL/subsystem-media/config.txt"

# An export wrote into a staging directory, not a card; export-card.sh has the closing word.
[ -n "${EXPORT:-}" ] && exit 0

sync
echo
df -h "$VOL" | tail -1
echo "ready — eject the card and boot it. First boot takes a few minutes (DietPi installs Chromium)."
