# subsystem-image

Turn a [subsystem](https://github.com/subsystemio/runtime) into a flashable Raspberry Pi card.
Boot it and you get a sealed terminal: your app on screen, no browser chrome, no way out.

Install it beside your subsystem and drive it from that subsystem's own scripts:

```sh
npm install -g bare                                        # the runtime everything runs on
npm install --save-dev github:subsystemio/subsystem-image
```

```json
"scripts": {
  "dev":   "sub .",
  "image": "subsystem-image build .",
  "flash": "subsystem-image flash ."
}
```

```sh
npm run image        # cross-build an arm64 payload
# flash DietPi ARMv8 (64-bit) — https://dietpi.com/#download
npm run flash        # write it to the mounted card
```

Eject and boot. First boot installs Chromium, then your app appears and stays there.

## Two kinds of card

A **subsystem card** is a sealed kiosk running one app. An **MCP card** is the headless box that
watches them all — no Chromium, no display, just the daemon.

```sh
subsystem-image mcp ../master-control /Volumes/bootfs   # the one box per installation
```

It carries the MCP's existing `.identity` across, so the fleet keeps its key and every subsystem
card already in the field keeps working. **That card holds a private key** — treat it like a key to
the building. Subsystem cards hold nothing worth stealing.

## Registering what gets supervised

A card declares its services in `services.conf`, one per line, and the first-boot script installs a
systemd unit for each with `Restart=always`:

```
name | Description | ExecStart | After (optional)
```

A subsystem card registers its app. An MCP card registers `mcp serve`, with `network-online.target`
since it is the one box that genuinely needs the network before it is useful — a subsystem
deliberately does not, so a dead venue Wi-Fi can never blank a prop.

A box that should run both just gets two lines. Nothing in the mechanism cares which is which.

## Hardware

| Board                    | Verdict                         |
| ------------------------ | ------------------------------- |
| Pi Zero 2 W (64-bit OS)  | Works — the only Zero that does |
| Pi 3 / 4 / 5 (64-bit OS) | Works comfortably               |
| **Pi Zero / W / WH**     | **Impossible**                  |
| Any Pi on a 32-bit OS    | Won't work                      |

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
SUBSYSTEM=github:subsystemio/runtime   # default
SUBSYSTEM=../runtime subsystem-image build ./my-subsystem   # while developing the runtime
```

The build refuses to finish if any `require` in your app fails to resolve in the staged payload.

## Configuration

Each subsystem carries its settings in its own `package.json`, so what you test locally is what
boots on the Pi:

```json
"subsystem": { "port": 9080, "resetAfter": 0, "resX": 1280, "resY": 720 }
```

That file is for **hardware**, and it is committed — the app is 1:1 with a Pi. A **venue's**
settings are a different thing: secret, different per install, and never committed. Those go in a
`.env` next to the app, which is read but never executed:

```sh
WIFI_SSID=Venue-Guest
WIFI_KEY=…
PASSWORD=…              # leave it out and you ship DietPi's published default
```

Anything can also be a flag or an environment variable. Precedence, highest first:

| Source         | Example                                                             |
| -------------- | ------------------------------------------------------------------- |
| flag           | `--wifi=… --password=… --volume=… --mcp=…` (`subsystem-image help`) |
| environment    | `WIFI_KEY=… npm run flash`, for a one-off                           |
| `.env`         | the venue's standing settings                                       |
| `package.json` | `"subsystem"` — hardware only                                       |
| discovered     | `mcp key`, `mcp room`                                               |
| default        | `WIFI_COUNTRY=GB`, `PASSWORD=dietpi`                                |

Wi-Fi and the device password are applied on **first boot only**. Get them right before the card is
powered on; changing them later means `dietpi-config` on the device, or a reflash.

`MCP` is the **public key** of the [master-control](https://github.com/subsystemio/master-control)
daemon this device answers to — the one thing that makes a card manageable, and the only thing a
card needs. It is discovered by running `mcp key`, so master-control has to be on your `PATH`:

```sh
npm install -g github:subsystemio/master-control
mcp            # once, to mint the fleet's identity — before you flash anything
```

Flashing a card before its MCP exists breaks nothing, but no console will ever see that device.
Pass `--mcp=<64-hex>` for an MCP that lives on another machine. `ROOM` is optional and only hides
the fleet from someone who has learned that key.

**A subsystem card carries nothing that grants authority.** Lose one and an attacker has a public
key, a room secret that reveals only that devices exist, and the venue's Wi-Fi.

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
<boot>/subsystem-media/config.txt   the MCP key, optional room secret, app settings
<boot>/subsystem.conf       which app, which port
```

Change them and reboot. No rebuild, no reflash.

## License

MIT
