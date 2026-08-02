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

echo "[subsystem] installing service"
cat > /etc/systemd/system/subsystem.service <<EOF
[Unit]
Description=Subsystem kiosk app (Bare)
# Deliberately no network dependency: the app binds loopback only and must come up
# even with no Wi-Fi, so a dead venue network can never blank the subsystem.

[Service]
Type=simple
WorkingDirectory=/opt/subsystem
ExecStart=/opt/subsystem/bin/bare /opt/subsystem/node_modules/subsystem/bin/subsystem.js /opt/subsystem/apps/$APP --port=$PORT --reset-after=$RESET_AFTER --assets=$BOOT/subsystem-media
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subsystem.service
systemctl start subsystem.service

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
