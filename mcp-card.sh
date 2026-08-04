#!/usr/bin/env bash
# Build a card for the MCP box — the one machine per installation that watches the fleet.
#
#   subsystem-image mcp /path/to/master-control /Volumes/bootfs
#
# Headless: no Chromium, no kiosk, no display. It boots, runs `mcp serve` under systemd with
# Restart=always, and waits for subsystems to find it.
#
# THIS CARD CARRIES A PRIVATE KEY. The MCP's `.identity` is copied onto it so the fleet keeps the
# same key — every subsystem card already holds the matching public key, and minting a new one would
# orphan all of them. Treat this card like a key to the building, unlike subsystem cards which carry
# nothing worth stealing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Every setting is resolved by bin/subsystem-image.js and handed down. Nothing is defaulted here —
# two places deciding what a default is, is how a card ends up configured differently to its log.
need () { for v in "$@"; do [ -n "${!v:-}" ] || { echo "$v not set — run this through \`subsystem-image\`" >&2; exit 1; }; done; }
need APP_DIR PASSWORD WIFI_COUNTRY
PRIVATE_ROOM="${PRIVATE_ROOM:-}"; WIFI_SSID="${WIFI_SSID:-}"; WIFI_KEY="${WIFI_KEY:-}"

MC="$APP_DIR"

VOL="${VOLUME:-}"
if [ -z "$VOL" ]; then
  CANDIDATES="$(ls -1 /Volumes/*/dietpi.txt 2>/dev/null || true)"
  COUNT="$(printf '%s' "$CANDIDATES" | grep -c . || true)"
  if [ "$COUNT" -gt 1 ]; then
    echo "more than one DietPi card is mounted — name the one you mean:"
    printf '%s\n' "$CANDIDATES" | while read -r c; do echo "    --volume=$(dirname "$c")"; done
    exit 1
  fi
  VOL="$(dirname "$CANDIDATES")"
fi
[ -f "$VOL/dietpi.txt" ] || {
  echo "no dietpi.txt found — pass --volume=<boot partition>"
  exit 1
}

BARE_VERSION="${BARE_VERSION:-$(npm view bare-runtime version 2>/dev/null)}"
[ -n "$BARE_VERSION" ] || {
  echo "cannot resolve a bare runtime version (offline?)"
  exit 1
}

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
OPT="$STAGE/subsystem"

echo "==> staging master-control  bare=$BARE_VERSION"
mkdir -p "$OPT/mcp" "$OPT/bin"
cp "$MC/index.js" "$OPT/mcp/"
cp -R "$MC/lib" "$OPT/mcp/lib"
cp "$MC/package.json" "$OPT/package.json"

echo "==> installing dependencies"
(cd "$OPT" && npm install --omit=dev --no-audit --no-fund --silent)

echo "==> pruning non-target prebuilds"
find "$OPT/node_modules" -mindepth 2 -maxdepth 2 -type d -name prebuilds -print0 | while IFS= read -r -d '' d; do
  find "$d" -mindepth 1 -maxdepth 1 -type d ! -name linux-arm64 -exec rm -rf {} +
done

echo "==> fetching bare runtime for linux-arm64"
RT="$STAGE/rt"
mkdir -p "$RT"
(cd "$RT" && npm pack "bare-runtime-linux-arm64@$BARE_VERSION" --silent >/dev/null && tar xzf ./*.tgz)
cp "$RT/package/bin/bare" "$OPT/bin/bare"
chmod +x "$OPT/bin/bare"
rm -rf "$RT"

# The fleet's identity must survive the move, or every subsystem card needs reflashing.
if [ -d "$MC/.identity" ]; then
  echo "==> carrying the existing MCP identity ($(tr -d '[:space:]' <"$MC/.mcp-key" | cut -c1-16)…)"
  cp -R "$MC/.identity" "$OPT/mcp/.identity"
  [ -f "$MC/.room" ] && cp "$MC/.room" "$OPT/mcp/.room"
  [ -f "$MC/.room-key" ] && cp "$MC/.room-key" "$OPT/mcp/.room-key"
  [ -f "$MC/.mcp-key" ] && cp "$MC/.mcp-key" "$OPT/mcp/.mcp-key"
  [ -f "$MC/roster.txt" ] && cp "$MC/roster.txt" "$OPT/mcp/roster.txt"
  # Without the attestation the box boots but no prop will accept it. Carrying the device key and
  # its proof together clones this MCP; the alternative is to let the new box mint its own key and
  # attest that offline, which keeps one secret in one place.
  if [ -f "$MC/.proof" ]; then
    cp "$MC/.proof" "$OPT/mcp/.proof"
  else
    echo "    WARNING: no .proof — this box will run but no prop will obey it"
  fi
else
  echo "==> no identity yet — this card will mint one on first boot"
  echo "    (read it back with: ssh root@<box> cat /opt/subsystem/mcp/.mcp-key)"
fi

echo "==> packing"
tar czf "$STAGE/mcp-payload.tar.gz" -C "$STAGE" subsystem

echo "==> writing $VOL"

inject() { # key value file
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
        if (key == k) { pad = (lhs == key) ? "" : " "; print k pad "=" pad v; done = 1; next }
      }
    }
    { print }
    END { if (!done) print k "=" v }
  ' "$f" > "$f.new" && mv "$f.new" "$f"
}

# Headless: console autologin, no desktop, no browser.
inject AUTO_SETUP_AUTOMATED 1 "$VOL/dietpi.txt"
inject AUTO_SETUP_GLOBAL_PASSWORD "$PASSWORD" "$VOL/dietpi.txt"
inject AUTO_SETUP_AUTOSTART_TARGET_INDEX 7 "$VOL/dietpi.txt"
inject AUTO_SETUP_INSTALL_SOFTWARE_ID "" "$VOL/dietpi.txt"
# The MCP is the one box that genuinely needs the network before it is useful.
inject AUTO_SETUP_BOOT_WAIT_FOR_NETWORK 1 "$VOL/dietpi.txt"

if [ -n "$WIFI_SSID" ]; then
  echo "==> wifi: $WIFI_SSID"
  inject AUTO_SETUP_NET_WIFI_ENABLED 1 "$VOL/dietpi.txt"
  inject AUTO_SETUP_NET_WIFI_COUNTRY_CODE "$WIFI_COUNTRY" "$VOL/dietpi.txt"
  inject 'aWIFI_SSID[0]' "'$WIFI_SSID'" "$VOL/dietpi-wifi.txt"
  inject 'aWIFI_KEY[0]' "'$WIFI_KEY'" "$VOL/dietpi-wifi.txt"
fi

cat > "$VOL/subsystem.conf" <<EOF
KIOSK=0
EOF

# What this box supervises. Unlike a subsystem, the MCP wants the network up first.
#
# --dir is explicit: a systemd unit has no useful HOME, and this is the one directory whose loss
# orphans every card in the field.
cat > "$VOL/services.conf" <<EOF
mcp | Master Control Program | /opt/subsystem/bin/bare /opt/subsystem/mcp/index.js serve --dir=/opt/subsystem/mcp $PRIVATE_ROOM | network-online.target
EOF

cp "$STAGE/mcp-payload.tar.gz" "$VOL/subsystem-payload.tar.gz"
cp "$HERE/Automation_Custom_Script.sh" "$VOL/Automation_Custom_Script.sh"
rm -rf "$VOL/subsystem-media"

sync
echo
df -h "$VOL" | tail -1
echo "ready — eject and boot. It will run \`mcp serve\` under systemd, restarting on failure."
echo "Then: mcp --host=\$(cat "$MC/.mcp-key") from any operator machine."
