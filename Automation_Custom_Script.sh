#!/bin/bash
# Runs once, as root, at the end of DietPi's first-boot setup (post-networking, post-software).
# Turns a stock DietPi install into a sealed subsystem terminal: the Bare app as a system service, and
# Chromium locked to it with no way out.
set -euo pipefail

BOOT=/boot
[ -f /boot/firmware/dietpi.txt ] && BOOT=/boot/firmware

APP=tile-puzzle
PORT=9080
RESET_AFTER=0
KIOSK=1
SERVICES=
[ -f "$BOOT/subsystem.conf" ] && . "$BOOT/subsystem.conf"

# Room membership and the admin allowlist live in subsystem-media/config.txt, read at runtime.

URL="http://127.0.0.1:$PORT"

echo "[subsystem] installing payload"
tar xzf "$BOOT/subsystem-payload.tar.gz" -C /opt
chmod +x /opt/subsystem/bin/bare

# The published runtime carries debug info: ~93M -> ~23M, which matters on a small card.
if command -v strip >/dev/null; then
  echo "[subsystem] stripping runtime"
  strip /opt/subsystem/bin/bare || true
fi

# ── supervised services ────────────────────────────────────────────────────
#
# A card declares what it wants supervised in services.conf, one per line:
#
#   name | Description | ExecStart | After(optional)
#
# Everything gets Restart=always, because a prop that dies must come back on its
# own — nobody is going to ssh into a sealed box mid-game. A subsystem card
# registers its app; an MCP card registers `mcp serve`; a box that does both
# registers two. The mechanism does not care which.
emit_unit() {
  name="$1"; desc="$2"; exec_start="$3"; after="$4"
  echo "[subsystem] supervising $name"
  {
    echo "[Unit]"
    echo "Description=$desc"
    if [ -n "$after" ]; then
      echo "After=$after"
      echo "Wants=$after"
    else
      # No network dependency by default: a prop binds loopback and must come up
      # even with no Wi-Fi, so a dead venue network can never blank it.
      echo "# deliberately no network dependency"
    fi
    echo ""
    echo "[Service]"
    echo "Type=simple"
    echo "WorkingDirectory=/opt/subsystem"
    echo "ExecStart=$exec_start"
    echo "Restart=always"
    echo "RestartSec=1"
    echo ""
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } > "/etc/systemd/system/$name.service"
}

if [ -f "$BOOT/services.conf" ]; then
  while IFS='|' read -r NAME DESC EXECSTART AFTER; do
    NAME="$(echo "$NAME" | xargs)"
    case "$NAME" in ''|'#'*) continue ;; esac
    emit_unit "$NAME" "$(echo "$DESC" | xargs)" "$(echo "$EXECSTART" | sed 's/^ *//;s/ *$//')" "$(echo "$AFTER" | xargs)"
    SERVICES="$SERVICES $NAME"
  done < "$BOOT/services.conf"
else
  # No registry: assume the single-subsystem card this image was originally for.
  emit_unit subsystem "Subsystem app (Bare)" \
    "/opt/subsystem/bin/bare /opt/subsystem/node_modules/@subsystemio/runtime/bin/subsystem.js /opt/subsystem/apps/$APP --port=$PORT --reset-after=$RESET_AFTER --assets=$BOOT/subsystem-media" ""
  SERVICES=" subsystem"
fi

systemctl daemon-reload
for svc in $SERVICES; do
  systemctl enable "$svc.service"
  systemctl start "$svc.service"
done

if [ "$KIOSK" = "1" ]; then
echo "[subsystem] disabling the password manager and autofill"
# A "Save password?" bubble popping up mid-game would be visible to guests, so this is enforced by
# managed policy rather than page hints — Chromium ignores autocomplete="off" on password fields.
# Debian ships the policy dir under either name depending on the package; write both.
for d in /etc/chromium/policies/managed /etc/chromium-browser/policies/managed; do
  mkdir -p "$d"
  cat > "$d/subsystem-kiosk.json" <<'EOF'
{
  "PasswordManagerEnabled": false,
  "PasswordLeakDetectionEnabled": false,
  "AutofillAddressEnabled": false,
  "AutofillCreditCardEnabled": false,
  "TranslateEnabled": false,
  "SyncDisabled": true,
  "BrowserSignin": 0,
  "MetricsReportingEnabled": false,
  "PromptForDownloadLocation": false,
  "DefaultNotificationsSetting": 2
}
EOF
done

echo "[subsystem] locking Chromium to the subsystem"
CHROMIUM_AUTOSTART=/var/lib/dietpi/dietpi-software/installed/chromium-autostart.sh
mkdir -p "$(dirname "$CHROMIUM_AUTOSTART")"
cat > "$CHROMIUM_AUTOSTART" <<EOF
#!/bin/dash
# Replaces DietPi's default Chromium autostart.
CHROMIUM=\$(command -v chromium || command -v chromium-browser)

# Profile lives in tmpfs: a power-cut can never leave a dirty profile behind (no "restore pages?"
# nag on the next boot), and it keeps the rootfs clean enough to mount read-only.
PROFILE=/tmp/chromium-subsystem
rm -rf "\$PROFILE"
mkdir -p "\$PROFILE"

xset -dpms
xset s off
xset s noblank
# The cursor is left visible on purpose: these subsystems are mouse-driven. On a pure touchscreen the
# page hides it via CSS instead, so a hybrid rig still gets a pointer.

# Don't paint anything until the subsystem is actually answering, so the screen never shows an error page.
while ! curl -sf -o /dev/null $URL; do sleep 0.5; done

exec "\$CHROMIUM" \\
  --user-data-dir="\$PROFILE" \\
  --kiosk $URL \\
  --noerrdialogs \\
  --disable-infobars \\
  --disable-session-crashed-bubble \\
  --disable-pinch \\
  --overscroll-history-navigation=0 \\
  --no-first-run \\
  --no-default-browser-check \\
  --disable-features=Translate,TranslateUI,AutofillServerCommunication,PasswordManagerOnboarding \\
  --password-store=basic \\
  --disable-component-update \\
  --disable-background-networking \\
  --check-for-update-interval=31536000 \\
  --autoplay-policy=no-user-gesture-required \\
  --use-gl=egl \\
  --ignore-gpu-blocklist \\
  --enable-gpu-rasterization
EOF
chmod +x "$CHROMIUM_AUTOSTART"

echo "[subsystem] disabling VT switching and screen blanking"
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-subsystem-lockdown.conf <<'EOF'
Section "ServerFlags"
    Option "DontVTSwitch" "true"
    Option "DontZap"      "true"
    Option "BlankTime"    "0"
    Option "StandbyTime"  "0"
    Option "SuspendTime"  "0"
    Option "OffTime"      "0"
EndSection
EOF

fi  # end kiosk-only browser setup

echo "[subsystem] quieting boot"
for f in "$BOOT/cmdline.txt"; do
  [ -f "$f" ] || continue
  grep -q logo.nologo "$f" || sed -i '1s/$/ logo.nologo consoleblank=0 vt.global_cursor_default=0 loglevel=3 quiet/' "$f"
done
for f in "$BOOT/config.txt"; do
  [ -f "$f" ] || continue
  grep -q '^disable_splash=1' "$f" || echo 'disable_splash=1' >> "$f"
done

echo "[subsystem] done — $APP on $URL"
