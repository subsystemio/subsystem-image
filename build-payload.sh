#!/usr/bin/env bash
# Build the SD-card payload for ONE app. Each Pi runs exactly one app, so each app owns its image.
#
#   cd apps/tile-puzzle && npm run image
#   ./image/build-payload.sh apps/tile-puzzle
#
# Runs on any machine (macOS included): every bare native module ships prebuilds for all 13
# platforms inside its npm package, so a node_modules tree installed here works verbatim on
# linux-arm64. The bare runtime itself comes out of bare-runtime-linux-arm64, so the Pi never needs
# Node, npm or a network connection to run the subsystem.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/app-config.sh"
resolve_app "${1:-.}"

# Where the runner comes from. A git ref by default; point it at a version or a local path while
# developing the library itself.
SUBSYSTEM="${SUBSYSTEM:-github:subsystemio/runtime}"

# Resolve to a concrete version so the build log records exactly what shipped on this card.
BARE_VERSION="${BARE_VERSION:-$(npm view bare-runtime version 2>/dev/null)}"
[ -n "$BARE_VERSION" ] || { echo "cannot resolve a bare runtime version (offline?)"; exit 1; }
OUT="$APP_DIR/subsystem-payload.tar.gz"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PROP="$STAGE/subsystem"

echo "==> app=$APP  bare=$BARE_VERSION  subsystem=$SUBSYSTEM"

mkdir -p "$PROP/apps" "$PROP/bin"
cp -R "$APP_DIR" "$PROP/apps/$APP"
# Art ships on the FAT boot partition instead, where a laptop can edit it. One copy, no drift.
# .identity MUST NOT ship: every device mints its own on first boot. Baking one in would give every
# card flashed from this payload the SAME identity — the MCP could not tell them apart, adopting one
# would adopt all, and a private key would ride on a card advertised as carrying nothing.
rm -rf "$PROP/apps/$APP/media" "$PROP/apps/$APP/subsystem-payload.tar.gz" \
  "$PROP/apps/$APP/node_modules" "$PROP/apps/$APP/.identity"

# The runner and its entire dependency tree come from the published package. Nothing is hand-listed
# here, so there is no second dependency list that can drift out of step with the library.
cat > "$PROP/package.json" <<JSON
{
  "name": "subsystem-payload",
  "private": true,
  "dependencies": { "@subsystemio/runtime": "$SUBSYSTEM" }
}
JSON

echo "==> installing runtime dependencies"
(cd "$PROP" && npm install --omit=dev --no-audit --no-fund --silent)

# Only linux-arm64 will ever load on the target; the other twelve are dead weight on the card.
echo "==> pruning non-target prebuilds"
find "$PROP/node_modules" -mindepth 2 -maxdepth 2 -type d -name prebuilds -print0 | while IFS= read -r -d '' d; do
  find "$d" -mindepth 1 -maxdepth 1 -type d ! -name linux-arm64 -exec rm -rf {} +
done

echo "==> fetching bare runtime for linux-arm64"
RT="$STAGE/rt"; mkdir -p "$RT"
(cd "$RT" && npm pack "bare-runtime-linux-arm64@$BARE_VERSION" --silent >/dev/null && tar xzf ./*.tgz)
cp "$RT/package/bin/bare" "$PROP/bin/bare"
chmod +x "$PROP/bin/bare"
rm -rf "$RT"

# Every bare specifier the payload requires must actually be installed. This is the check that
# would have caught the payload's dependency list drifting away from the root's.
echo "==> verifying the app's requires resolve"
node -e "
  const fs = require('fs'), path = require('path')
  const root = '$PROP'
  const missing = new Set()
  const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).forEach((e) => {
    const f = path.join(d, e.name)
    if (e.isDirectory()) { if (e.name !== 'node_modules' && e.name !== 'media') walk(f); return }
    if (!e.name.endsWith('.js')) return
    for (const m of fs.readFileSync(f, 'utf8').matchAll(/require\\('([^']+)'\\)/g)) {
      const spec = m[1]
      if (spec.startsWith('.')) {
        if (!fs.existsSync(path.resolve(path.dirname(f), spec))) missing.add(spec + ' (from ' + path.relative(root, f) + ')')
        continue
      }
      const name = spec.startsWith('@') ? spec.split('/').slice(0, 2).join('/') : spec.split('/')[0]
      if (!fs.existsSync(path.join(root, 'node_modules', name))) missing.add(name)
    }
  })
  walk(path.join(root, 'apps'))
  if (missing.size) { console.error('  MISSING from the payload: ' + [...missing].join(', ')); process.exit(1) }
  console.log('  all requires resolve')
"

# The service runs the package's own bin, so make sure it actually arrived.
[ -f "$PROP/node_modules/@subsystemio/runtime/bin/subsystem.js" ] || { echo "  subsystem package has no runner"; exit 1; }

# Belt and braces: nothing key-shaped may ever reach a subsystem card.
LEAKED="$(find "$PROP" -path "$PROP/node_modules" -prune -o \
  \( -name 'seed' -o -name '.room' -o -name '*-key' -o -name '.identity' \) -print 2>/dev/null || true)"
if [ -n "$LEAKED" ]; then
  echo "  refusing to pack — key material in the payload:"
  printf '%s\n' "$LEAKED" | sed "s|$PROP|  /opt/subsystem|"
  exit 1
fi

echo "==> packing"
tar czf "$OUT" -C "$STAGE" subsystem

echo
echo "payload: $OUT ($(du -h "$OUT" | cut -f1))"
echo "next:    $HERE/prepare-sd.sh $APP_DIR <boot volume>"
