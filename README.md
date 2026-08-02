# subsystem-image

Turn a [subsystem](https://github.com/subsystemio/subsystem-js) into a flashable Raspberry Pi card.
Boot it and you get a sealed terminal: your app on screen, no browser chrome, no way out.

```sh
./build-payload.sh path/to/my-subsystem     # cross-build an arm64 payload
# flash DietPi ARMv8 (64-bit) — https://dietpi.com/#download
./prepare-sd.sh path/to/my-subsystem /Volumes/bootfs
```

Eject and boot. First boot installs Chromium, then your app appears and stays there.

## Hardware

| Board | Verdict |
|---|---|
| Pi Zero 2 W (64-bit OS) | Works — the only Zero that does |
| Pi 3 / 4 / 5 (64-bit OS) | Works comfortably |
| **Pi Zero / W / WH** | **Impossible** |
| Any Pi on a 32-bit OS | Won't work |

Zero 1 is ARMv6, and two things independently rule it out: Bare publishes Linux prebuilds for
`linux-x64` and `linux-arm64` only — there is no `linux-arm` at all — and Chromium dropped ARMv6.

Zero 2 W is a Cortex-A53, so it runs `linux-arm64`, **but you must flash a 64-bit image**. On its
512MB keep video modest: 720p30 H.264, ~1.5 Mbps, `+faststart`.

## No Node, npm or network on the device

Every native `bare-*` package ships prebuilds for all 13 platforms inside its npm tarball, so a
`node_modules` built on a Mac already contains the arm64 binaries — the other twelve get pruned.
`bare-runtime-linux-arm64` supplies the actual aarch64 runtime. Result: a ~35 MB tarball that
unpacks to `/opt/subsystem` and runs with nothing else installed.

The runner comes from the published package, so there is no second dependency list to drift:

```sh
SUBSYSTEM=github:subsystemio/subsystem-js   # default
SUBSYSTEM=../subsystem-js ./build-payload.sh ./my-subsystem   # while developing the library
```

The build refuses to finish if any `require` in your app fails to resolve in the staged payload.

## Configuration

Each subsystem carries its settings in its own `package.json`, so what you test locally is what
boots on the Pi:

```json
"subsystem": { "port": 9080, "resetAfter": 0, "resX": 1280, "resY": 720 }
```

Environment variables override for one run: `PORT`, `RESET_AFTER`, `RES_X`/`RES_Y`, `PASSWORD`,
`ROOM`, `ADMINS`, `WIFI_SSID`/`WIFI_KEY`/`WIFI_COUNTRY`. `ROOM` and `ADMINS` are read from
`.room-key` and `.controller-key` if a console has minted them (`SUBSYSTEM_KEYS=path` to point
elsewhere).

## What "sealed" means

- **systemd `Restart=always`**, no network dependency — the app binds loopback and comes up with no
  Wi-Fi at all.
- **Chromium `--kiosk`**, profile in tmpfs so a yanked power cord can never leave a dirty profile or
  a "Restore pages?" nag.
- **Managed policy** disabling the password manager and autofill — Chromium ignores
  `autocomplete="off"` on password fields, so this has to be enforced browser-side. Plus
  `--password-store=basic`, or it can pop a keyring unlock dialog over your kiosk.
- **`DontVTSwitch` + `DontZap`**, blanking off, quiet boot.
- Chromium waits for the app's HTTP endpoint before painting, so a boot race never shows an error.

The honest caveat: **a keyboard is the hole.** A mouse has no escape hatch from `--kiosk`; a
keyboard has more surface than a flag list can cover. Don't attach one to a public terminal. For
more, DietPi's `dietpi-drive_manager` can mount the rootfs read-only.

## Editing a live card

Art and config live on the FAT boot partition, readable from any laptop:

```
<boot>/subsystem-media/     your app's assets
<boot>/subsystem-media/config.txt   room secret, admin keys, app settings
<boot>/subsystem.conf       which app, which port
```

Change them and reboot. No rebuild, no reflash.

## License

MIT
