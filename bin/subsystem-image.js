#!/usr/bin/env bare
const fs = require('bare-fs')
const path = require('bare-path')
const env = require('bare-env')
const { spawnSync } = require('bare-subprocess')
const { command, flag, arg, summary, description, header, footer, bail } = require('paparam')

// subsystem-image — build and write cards for subsystems and for the MCP.
//
// This front end owns configuration and nothing else: flags, .env, package.json, discovery,
// precedence, validation. It resolves every setting to a concrete value and hands the shell scripts
// a fully-populated environment, so they carry no defaulting logic and cannot disagree with each
// other about where a value came from.
const HERE = path.join(__dirname, '..')

const VENUE = `Put a venue's settings in <dir>/.env rather than typing them per card. It is read, never
executed, and must never be committed — it is the one file here that holds real secrets.

  WIFI_SSID=Venue-Guest
  WIFI_KEY=…
  PASSWORD=…

Precedence, highest first: flag, environment, .env, package.json "subsystem", discovered, default.`

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

// One resolution path for all three subcommands, so a setting cannot mean different things
// depending on which one you ran.
function resolve(cmd, { needsMcp }) {
  const flags = cmd.flags
  const dir = path.resolve(cmd.args.dir || '.')
  if (!fs.existsSync(path.join(dir, 'index.js')))
    fail('no index.js in ' + dir + ' — pass the directory')

  const dotenv = readEnvFile(path.join(dir, '.env'))
  const pkg = readPackage(dir).subsystem || {}
  const pick = (name, envName, fallback) => {
    const v = flags[name] ?? env[envName] ?? dotenv[envName] ?? fallback
    return v === undefined || v === null ? '' : String(v)
  }

  const cfg = {
    APP_DIR: dir,
    APP: path.basename(dir),
    VOLUME: pick('volume', 'VOLUME') || cmd.args.volume || '',
    PASSWORD: pick('password', 'PASSWORD', 'dietpi'),
    WIFI_SSID: pick('wifi', 'WIFI_SSID'),
    WIFI_KEY: pick('wifiKey', 'WIFI_KEY'),
    WIFI_COUNTRY: pick('wifiCountry', 'WIFI_COUNTRY', 'GB'),
    SUBSYSTEM: pick('runtime', 'SUBSYSTEM', 'github:subsystemio/runtime'),
    BARE_VERSION: pick('bareVersion', 'BARE_VERSION'),
    // Hardware settings belong in the app's package.json — it is 1:1 with a Pi. Venue settings
    // never do; those are exactly the ones that must not be committed.
    PORT: pick('port', 'PORT', pkg.port ?? 9080),
    RESET_AFTER: pick('resetAfter', 'RESET_AFTER', pkg.resetAfter ?? 0),
    RES_X: pick('resX', 'RES_X', pkg.resX ?? 1280),
    RES_Y: pick('resY', 'RES_Y', pkg.resY ?? 720),
    PRIVATE_ROOM: flags.privateRoom ? '--private-room' : ''
  }

  if (needsMcp) {
    cfg.MCP = pick('mcp', 'MCP') || askMcp('key')
    cfg.ROOM = pick('room', 'ROOM') || askMcp('room')
    for (const k of ['MCP', 'ROOM']) {
      if (cfg[k] && !/^[0-9a-f]{64}$/.test(cfg[k])) {
        fail('--' + k.toLowerCase() + ' must be 64 hex characters, got "' + cfg[k] + '"')
      }
    }
  }
  if (cfg.WIFI_KEY && !cfg.WIFI_SSID) fail('--wifi-key needs --wifi')
  if (!/^\d+$/.test(cfg.PORT)) fail('--port must be a number, got "' + cfg.PORT + '"')

  return cfg
}

function run(script, cfg) {
  const r = spawnSync(path.join(HERE, script), [], { stdio: 'inherit', env: { ...env, ...cfg } })
  Bare.exit(r.status === null ? 1 : r.status)
}

const venueFlags = (c) =>
  c.add(
    flag('--wifi [ssid]', 'venue wifi. Applied on FIRST BOOT ONLY'),
    flag('--wifi-key [psk]', 'wifi password'),
    flag('--wifi-country [cc]', 'wifi regulatory domain (default GB)'),
    flag('--password [pw]', 'device login; default "dietpi", which you should not ship')
  )

const build = command(
  'build',
  summary('cross-build an arm64 payload'),
  description('Needs no card and no Pi — it cross-builds anywhere, including macOS.'),
  arg('[dir]', 'the subsystem to build; defaults to the current directory'),
  flag('--runtime [spec]', 'where the runner comes from (default github:subsystemio/runtime)'),
  flag('--bare-version [v]', 'pin the bare runtime version'),
  flag('--port [port]', 'override package.json "subsystem"'),
  flag('--reset-after [s]', 'override package.json "subsystem"'),
  flag('--res-x [px]', 'override package.json "subsystem"'),
  flag('--res-y [px]', 'override package.json "subsystem"'),
  (cmd) => run('build-payload.sh', resolve(cmd, { needsMcp: false }))
)

const flash = command(
  'flash',
  summary('write a built payload onto a flashed DietPi card'),
  description(VENUE),
  arg('[dir]', 'the subsystem to write; defaults to the current directory'),
  arg('[volume]', 'boot partition; defaults to the one mounted DietPi card'),
  flag('--volume [path]', 'boot partition, if not the one mounted card'),
  flag('--mcp [64-hex]', 'which MCP this card answers to; default `mcp key`'),
  flag('--room [64-hex]', 'room secret, if the fleet is private; default `mcp room`'),
  flag('--port [port]', 'override package.json "subsystem"'),
  flag('--reset-after [s]', 'override package.json "subsystem"'),
  flag('--res-x [px]', 'override package.json "subsystem"'),
  flag('--res-y [px]', 'override package.json "subsystem"'),
  (cmd) => {
    const cfg = resolve(cmd, { needsMcp: true })
    if (cfg.PASSWORD === 'dietpi') {
      console.error('subsystem-image: warning — shipping the default password "dietpi"')
    }
    run('prepare-sd.sh', cfg)
  }
)
venueFlags(flash)

const mcpCard = command(
  'mcp',
  summary('write the headless MCP box'),
  description(
    'THIS CARD CARRIES A PRIVATE KEY: the MCP identity is copied onto it so the fleet keeps its\n' +
      'key. Treat it like a key to the building. Subsystem cards carry nothing that grants anything.'
  ),
  arg('[dir]', 'a master-control checkout'),
  arg('[volume]', 'boot partition; defaults to the one mounted DietPi card'),
  flag('--volume [path]', 'boot partition, if not the one mounted card'),
  flag('--private-room', 'run the daemon with --private-room'),
  (cmd) => run('mcp-card.sh', resolve(cmd, { needsMcp: false }))
)
venueFlags(mcpCard)

// paparam throws a raw Bail otherwise, which reads like a crash for what is usually a typo.
function onBail(b) {
  if (b.err) console.error('subsystem-image: ' + b.err.message)
  else if (b.reason === 'UNKNOWN_FLAG')
    console.error('subsystem-image: unknown flag --' + b.flag.name)
  else if (b.reason === 'UNKNOWN_ARG') console.error('subsystem-image: unknown command or argument')
  else if (b.reason === 'MISSING_ARG') console.error('subsystem-image: missing argument')
  else console.error('subsystem-image: ' + b.reason)
  console.error("try 'subsystem-image --help'")
  Bare.exit(1)
}

const cli = command(
  'subsystem-image',
  bail(onBail),
  header('Build and write cards for subsystems and for the MCP.'),
  summary('flashable Raspberry Pi kiosk cards'),
  footer('a card carries no secret that grants anything — only the MCP card holds a private key'),
  build,
  flash,
  mcpCard,
  () => console.log(cli.help())
)

const parsed = cli.parse(Bare.argv.slice(2))
if (parsed && parsed.running) {
  parsed.running.catch((e) => {
    console.error('subsystem-image: ' + (e && e.message ? e.message : e))
    Bare.exit(1)
  })
}
