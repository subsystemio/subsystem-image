#!/usr/bin/env bare
const fs = require('bare-fs')
const path = require('bare-path')
const env = require('bare-env')
const { spawnSync } = require('bare-subprocess')

// subsystem-image — build and write cards for subsystems and for the MCP.
//
// This front end owns configuration and nothing else: flags, .env, package.json, discovery,
// precedence, validation. It resolves every setting to a concrete value and hands the shell scripts
// a fully-populated environment, so they carry no defaulting logic and cannot disagree with each
// other about where a value came from.
const HERE = path.join(__dirname, '..')

const USAGE = `subsystem-image — build and write cards for subsystems and for the MCP

  subsystem-image build <dir>            cross-build an arm64 payload
  subsystem-image flash <dir> [volume]   write that payload onto a flashed DietPi card
  subsystem-image mcp <dir> [volume]     write the headless MCP box
  subsystem-image help

Settings, highest precedence first: flag, environment, <dir>/.env, package.json "subsystem",
discovered, default.

  --volume=<path>       boot partition; default the one mounted DietPi card
  --mcp=<64-hex>        which MCP this card answers to; default \`mcp key\`
  --room=<64-hex>       room secret, if the fleet is private; default \`mcp room\`
  --wifi=<ssid>         venue wifi. Applied on FIRST BOOT ONLY
  --wifi-key=<psk>
  --wifi-country=<cc>   default GB
  --password=<pw>       device login; default "dietpi", which you should not ship
  --port --reset-after --res-x --res-y      override package.json "subsystem"
  --runtime=<spec>      where the runner comes from; default github:subsystemio/runtime
  --private-room        (mcp only) mint a room secret if there is not one already

Put a venue's settings in <dir>/.env rather than typing them per card. It is read, never executed,
and must never be committed — it is the one file here that holds real secrets.

  WIFI_SSID=Dunham-Guest
  WIFI_KEY=…
  PASSWORD=…
`

// Parsed, never sourced. This file holds a venue's wifi password and possibly its room secret, so
// it must not be able to execute anything.
function readEnvFile(file) {
  const out = {}
  if (!fs.existsSync(file)) return out
  for (const raw of fs.readFileSync(file, 'utf8').split('\n')) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue
    const eq = line.indexOf('=')
    if (eq < 1) continue
    const key = line
      .slice(0, eq)
      .replace(/^export\s+/, '')
      .trim()
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) continue
    out[key] = line
      .slice(eq + 1)
      .trim()
      .replace(/^(['"])(.*)\1$/, '$2')
  }
  return out
}

function readPackage(dir) {
  const file = path.join(dir, 'package.json')
  if (!fs.existsSync(file)) return {}
  return JSON.parse(fs.readFileSync(file, 'utf8'))
}

// The MCP is the authority on its own key, so ask it rather than knowing where anyone keeps a
// checkout. Silence is the correct answer when no daemon has ever run.
function askMcp(sub) {
  const r = spawnSync('/bin/sh', ['-c', 'command -v mcp >/dev/null 2>&1 && mcp ' + sub], {
    encoding: 'utf8'
  })
  const hit = String(r.stdout || '').match(/[0-9a-f]{64}/)
  return hit ? hit[0] : ''
}

function fail(msg) {
  console.error('subsystem-image: ' + msg)
  Bare.exit(1)
}

function main(argv) {
  const cmd = argv.find((a) => !a.startsWith('-')) || 'help'
  const rest = argv.filter((a) => a !== cmd)
  const positional = rest.filter((a) => !a.startsWith('-'))

  const flags = {}
  for (const a of rest) {
    if (!a.startsWith('--')) continue
    const eq = a.indexOf('=')
    if (eq === -1) flags[a.slice(2)] = 'true'
    else flags[a.slice(2, eq)] = a.slice(eq + 1)
  }

  if (cmd === 'help' || flags.help) return console.log(USAGE)
  if (cmd !== 'build' && cmd !== 'flash' && cmd !== 'mcp') {
    console.error('unknown command: ' + cmd + '\n')
    console.error(USAGE)
    return Bare.exit(1)
  }

  const dir = path.resolve(positional[0] || '.')
  if (!fs.existsSync(path.join(dir, 'index.js')))
    fail('no index.js in ' + dir + ' — pass the directory')

  const dotenv = readEnvFile(path.join(dir, '.env'))
  const pkg = readPackage(dir).subsystem || {}
  const pick = (flag, name, fallback) => {
    const v = flags[flag] ?? env[name] ?? dotenv[name] ?? fallback
    return v === undefined || v === null ? '' : String(v)
  }

  const cfg = {
    APP_DIR: dir,
    APP: path.basename(dir),
    VOLUME: pick('volume', 'VOLUME') || positional[1] || '',
    PASSWORD: pick('password', 'PASSWORD', 'dietpi'),
    WIFI_SSID: pick('wifi', 'WIFI_SSID'),
    WIFI_KEY: pick('wifi-key', 'WIFI_KEY'),
    WIFI_COUNTRY: pick('wifi-country', 'WIFI_COUNTRY', 'GB'),
    SUBSYSTEM: pick('runtime', 'SUBSYSTEM', 'github:subsystemio/runtime'),
    BARE_VERSION: pick('bare-version', 'BARE_VERSION'),
    // Hardware settings belong in the app's package.json — it is 1:1 with a Pi. Venue settings
    // never do; those are exactly the ones that must not be committed.
    PORT: pick('port', 'PORT', pkg.port ?? 9080),
    RESET_AFTER: pick('reset-after', 'RESET_AFTER', pkg.resetAfter ?? 0),
    RES_X: pick('res-x', 'RES_X', pkg.resX ?? 1280),
    RES_Y: pick('res-y', 'RES_Y', pkg.resY ?? 720),
    PRIVATE_ROOM: flags['private-room'] ? '--private-room' : ''
  }

  if (cmd !== 'build') {
    cfg.MCP = pick('mcp', 'MCP') || askMcp('key')
    cfg.ROOM = pick('room', 'ROOM') || askMcp('room')
  }

  for (const k of ['MCP', 'ROOM']) {
    if (cfg[k] && !/^[0-9a-f]{64}$/.test(cfg[k]))
      fail('--' + k.toLowerCase() + ' must be 64 hex characters, got "' + cfg[k] + '"')
  }
  if (cfg.WIFI_KEY && !cfg.WIFI_SSID) fail('--wifi-key needs --wifi')
  if (!/^\d+$/.test(cfg.PORT)) fail('--port must be a number, got "' + cfg.PORT + '"')
  if (cmd === 'flash' && cfg.PASSWORD === 'dietpi') {
    console.error('subsystem-image: warning — shipping the default password "dietpi"')
  }

  const script = {
    build: 'build-payload.sh',
    flash: 'prepare-sd.sh',
    mcp: 'mcp-card.sh'
  }[cmd]
  const r = spawnSync(path.join(HERE, script), [], {
    stdio: 'inherit',
    env: { ...env, ...cfg }
  })
  Bare.exit(r.status === null ? 1 : r.status)
}

main(Bare.argv.slice(2))
