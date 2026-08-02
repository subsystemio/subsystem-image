# Resolve an app directory and read its per-app image config. Sourced by build-payload.sh and
# prepare-sd.sh so both agree on where an app lives and how it wants to be flashed.
#
# Config comes from the app's own package.json under "subsystem", because the app is 1:1 with a Pi and
# should carry its own hardware settings. Environment variables win, so a one-off flash can
# override without editing the app.

resolve_app () { # <dir-or-name>
  local target="${1:-.}"

  if [ -f "$target/index.js" ]; then
    APP_DIR="$(cd "$target" && pwd)"
  else
    echo "no app at '$target' — pass a directory, or one of:" >&2
    echo "  (pass a path to a subsystem directory)" >&2
    exit 1
  fi

  APP="$(basename "$APP_DIR")"

  local cfg="$APP_DIR/package.json"
  read_cfg () { # <key> <default>
    node -p "((require('$cfg').subsystem)||{})['$1'] ?? '$2'" 2>/dev/null || echo "$2"
  }

  PORT="${PORT:-$(read_cfg port 9080)}"
  RESET_AFTER="${RESET_AFTER:-$(read_cfg resetAfter 0)}"
  RES_X="${RES_X:-$(read_cfg resX 1280)}"
  RES_Y="${RES_Y:-$(read_cfg resY 720)}"
}
