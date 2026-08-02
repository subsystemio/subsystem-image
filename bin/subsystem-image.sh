#!/usr/bin/env bash
# subsystem-image — build and write cards for subsystems and for the MCP.
#
#   subsystem-image build <dir>                 cross-build an arm64 payload for a subsystem
#   subsystem-image flash <dir> [volume]        write that subsystem onto a flashed DietPi card
#   subsystem-image mcp   <master-control> [volume]   write the headless MCP box
#   subsystem-image help
#
# Installed as a devDependency, this is what a subsystem's own package.json calls:
#
#   "scripts": {
#     "dev":   "subsystem .",
#     "image": "subsystem-image build .",
#     "flash": "subsystem-image flash ."
#   }
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

CMD="${1:-help}"
[ $# -gt 0 ] && shift || true

case "$CMD" in
  build) exec "$HERE/build-payload.sh" "$@" ;;
  flash) exec "$HERE/prepare-sd.sh" "$@" ;;
  mcp) exec "$HERE/mcp-card.sh" "$@" ;;
  help | --help | -h) usage ;;
  *)
    echo "unknown command: $CMD"
    echo
    usage
    exit 1
    ;;
esac
