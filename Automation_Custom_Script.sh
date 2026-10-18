#!/bin/bash
# Runs once, as root, at the end of DietPi's first-boot setup (post-networking, post-software).
# Turns a stock DietPi install into a sealed subsystem terminal: the Bare app as a system service, and
# Chromium locked to it with no way out.
set -euo pipefail

# Find the card's FAT partition by what we put on it, not by dietpi.txt. Newer DietPi images mount
# the FAT at /boot/firmware and, on first boot, MOVE dietpi.txt and this script into /boot on the
# rootfs — leaving everything else behind. Keying on dietpi.txt picked /boot, found no payload, and
# installed nothing.
BOOT=/boot
[ -f /boot/firmware/subsystem-payload.tar.gz ] && BOOT=/boot/firmware

PORT=9080
KIOSK=1
SERVICES=
TS_HOSTNAME=subsystem
TS_AUTHKEY=
[ -f "$BOOT/subsystem.conf" ] && . "$BOOT/subsystem.conf"

# ── remote access ──────────────────────────────────────────────────────────
#
# First, before anything below can fail: a card that breaks in a venue is only fixable if it can be
# reached. Never fatal — a venue with no internet still gets a working prop. With no key, Tailscale
# is installed but logged out; `tailscale up` on the device prints a link to join it by hand.
if [ -n "$TS_AUTHKEY" ] && command -v tailscale >/dev/null; then
  echo "[subsystem] joining the tailnet as $TS_HOSTNAME"
  for _ in 1 2 3 4 5 6; do
    tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME" --timeout=30s && break
    sleep 10
  done
  # Used or not, a key does not stay on a FAT partition any laptop can read.
  sed -i '/^TS_AUTHKEY=/d' "$BOOT/subsystem.conf"
fi

# Room membership and the admin allowlist live in subsystem-media/config.txt, read at runtime.

URL="http://127.0.0.1:$PORT"

[ -f "$BOOT/subsystem-payload.tar.gz" ] || {
  echo "[subsystem] no subsystem-payload.tar.gz on the boot partition — card was not written by subsystem-image" >&2
  exit 1
}

# ── payload ────────────────────────────────────────────────────────────────
#
# Unpacking the payload is NOT a first-boot job. A card is reflashed to carry a new build, and if
# only first boot ever installed it, the boot partition would hold the new app while /opt kept
# running the old one — with no symptom except behaviour that quietly fails to change. So the
# installer below is written to disk, runs now, and runs again on every boot, reinstalling whenever
# the card is carrying something other than what is already on disk.
#
# It is also where a remote update lands when there is one: write the file, reboot.
INSTALLER=/opt/subsystem-install.sh
cat > "$INSTALLER" <<'INSTALL'
#!/bin/bash
set -euo pipefail

BOOT=/boot
[ -f /boot/firmware/subsystem-payload.tar.gz ] && BOOT=/boot/firmware
PAYLOAD="$BOOT/subsystem-payload.tar.gz"
STAMP=/opt/.subsystem-payload

# A card with no payload is not this script's problem to report — first boot already refused.
[ -f "$PAYLOAD" ] || exit 0

# Size and mtime rather than a hash: writing a card always moves both, and hashing 35M on a Zero 2 W
# spends a second of every boot to learn what stat already knows.
want="$(stat -c '%s %Y' "$PAYLOAD")"
[ "$(cat "$STAMP" 2>/dev/null || true)" = "$want" ] && exit 0

echo "[subsystem] installing payload"
tar xzf "$PAYLOAD" -C /opt
chmod +x /opt/subsystem/bin/bare

# The published runtime carries debug info: ~93M -> ~23M, which matters on a small card.
if command -v strip >/dev/null; then
  echo "[subsystem] stripping runtime"
  strip /opt/subsystem/bin/bare || true
fi

echo "$want" > "$STAMP"
INSTALL
chmod +x "$INSTALLER"

cat > /etc/systemd/system/subsystem-install.service <<EOF
[Unit]
Description=Install the subsystem payload when the card carries a new one

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALLER

[Install]
WantedBy=multi-user.target
EOF

"$INSTALLER"

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
    # Restart=always alone is a trap: systemd's default rate limit gives up after 5 starts in 10s
    # and leaves the unit failed, permanently. An app that crashes on startup — bad media, a bad
    # message from the console — would take six seconds to die for good, with nobody in the room to
    # notice. Zero disables the limit, so a prop retries forever, which is the whole contract.
    echo "StartLimitIntervalSec=0"
    # Ordered after the installer whatever this service is called, so nothing ever starts against a
    # half-written /opt on the boot where the card brought a new payload.
    #
    # No network dependency beyond what the card asked for: a prop binds loopback and must come up
    # even with no Wi-Fi, so a dead venue network can never blank it.
    deps="subsystem-install.service"
    [ -n "$after" ] && deps="$deps $after"
    echo "After=$deps"
    echo "Wants=$deps"
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
    # @BOOT@ is the card's stand-in for the boot mount, which is only known here. systemd does no
    # shell expansion in ExecStart, so it has to be substituted rather than left as a variable.
    EXECSTART="$(echo "$EXECSTART" | sed "s|@BOOT@|$BOOT|g; s/^ *//; s/ *$//")"
    emit_unit "$NAME" "$(echo "$DESC" | xargs)" "$EXECSTART" "$(echo "$AFTER" | xargs)"
    SERVICES="$SERVICES $NAME"
  done < "$BOOT/services.conf"
else
  echo "[subsystem] no services.conf on the boot partition — nothing to supervise" >&2
  exit 1
fi

systemctl daemon-reload
systemctl enable subsystem-install.service
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
# DietPi's autologin execs the autostart from a bare console — no X server is running yet. Starting
# one is the autostart's own job, so it only launches X; everything that needs a display lives in
# the session it hands X. Running xset and Chromium straight from the console finds no display, and
# the card falls back to a login prompt.
CHROMIUM_AUTOSTART=/var/lib/dietpi/dietpi-software/installed/chromium-autostart.sh
CHROMIUM_SESSION=/var/lib/dietpi/dietpi-software/installed/chromium-session.sh
mkdir -p "$(dirname "$CHROMIUM_AUTOSTART")"
cat > "$CHROMIUM_AUTOSTART" <<EOF
#!/bin/dash
# Replaces DietPi's default Chromium autostart. Root gets xinit; anyone else needs startx so
# systemd-logind grants them the display.
STARTX=xinit
[ "\$USER" = root ] || STARTX=startx
exec "\$STARTX" $CHROMIUM_SESSION
EOF
chmod +x "$CHROMIUM_AUTOSTART"

cat > "$CHROMIUM_SESSION" <<EOF
#!/bin/dash
# Runs inside X, started by chromium-autostart.sh.
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
chmod +x "$CHROMIUM_SESSION"

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

echo "[subsystem] done —$SERVICES"
