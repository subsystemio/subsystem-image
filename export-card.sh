#!/usr/bin/env bash
# Write ONE app's card into a zip instead of onto a card — for when the card is somewhere else.
#
# Invoked by `subsystem-image export`, which resolves the configuration and exports it. Do not call
# this directly — every setting it needs comes from there.
#
# Unzipped onto the boot partition of a freshly-flashed DietPi card, it is exactly what `flash`
# writes. That partition is FAT, so the person holding the card needs no tools and any OS.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
need () { for v in "$@"; do [ -n "${!v:-}" ] || { echo "$v not set — run this through \`subsystem-image\`" >&2; exit 1; }; done; }
need APP_DIR APP OUT

[ -f "$APP_DIR/subsystem-payload.tar.gz" ] || { echo "no payload — run 'subsystem-image build $APP_DIR' first"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# flash edits the card's own dietpi.txt in place. There is no card here, so start from DietPi's
# stock one, which the zip then replaces on the card. That is only safe before first boot — which
# is the only time dietpi.txt is read anyway.
echo "==> fetching DietPi's stock dietpi.txt"
curl -fsSL -o "$STAGE/dietpi.txt" https://raw.githubusercontent.com/MichaIng/DietPi/master/dietpi.txt

VOLUME="$STAGE" EXPORT=1 "$HERE/prepare-sd.sh"

echo "==> zipping"
rm -f "$OUT"
(cd "$STAGE" && zip -r -X -q "$OUT" .)

echo
echo "card:  $OUT ($(du -h "$OUT" | cut -f1))"
echo "       IT CARRIES THE VENUE WI-FI AND DEVICE PASSWORD — send it privately."
echo
echo "for whoever holds the card:"
echo "  1. Flash DietPi ARMv8 (64-bit) to it. Do not boot it."
echo "  2. Open the zip and drag everything in it onto the card's boot drive, replacing what is"
echo "     there. Not 'Extract All' — that adds a folder. If Windows offers to format a drive, cancel."
echo "  3. Eject, plug the Pi into its screen, then power. First boot takes 5-15 minutes."
