# CLAUDE.md

Guidance for Claude Code when working in this repo. See `readme.md` for the
full architecture and the reasoning behind these decisions.

## What this repo is

Home automation config-as-code: Home Assistant (central hub, bare metal)
+ Shelly devices + Raspberry Pi satellites (one per room), deployed via
GitOps. Local development pushes over SSH into a bare repo on the sync
Pi (the source of truth, not GitHub); satellites and the HA host then
each pull from there on their own polling systemd timer; the sync Pi
separately mirrors to GitHub one-way. See `readme.md` for the repo layout
and the project-context doc for the full decision record.

## Hard constraints - never put these in the repo

Not in file contents, not in commit messages, not in comments or examples.
If a value is needed for something to make sense, use an obvious
placeholder (`mqtt.example.local`, `changeme`, `<broker-ip>`) instead of a
real-looking one.

- **Passwords, tokens, API keys, MQTT credentials, WiFi passwords, HA
  long-lived access tokens.** These go in `secrets.yaml` (git-ignored) or
  `.env` (git-ignored). The repo only ever holds `secrets.yaml.example`
  with placeholder values.
- **Network details**: real IP addresses, hostnames, port-forwarding
  rules, VLAN/firewall specifics. Examples must use placeholder or
  RFC-5737/example.com-style values, never anything that could be the
  user's actual network.
- **Floor plans or camera/sensor layouts** that reveal the physical house
  layout combined with camera or sensor placement.
- Generic room-type labels (`kitchen`, `bathroom`, ...) are fine - the
  repo's own room-based structure depends on them. The line is physical/
  network specifics, not room names themselves.

If you're about to write a value and aren't sure whether it's a real
credential/IP or a placeholder, ask before committing it.

## Autonomy: repo edits vs. live actions

- **Repo-only changes** (editing files, running tests/linters locally,
  local `git commit`) - fine to do directly when asked, no need to check in
  first.
- **Anything with a real-world effect** - `git push` to either remote
  (`sync`, the bare repo on the sync Pi, is the actual deploy trigger;
  `github` is just the downstream mirror), running `deploy/deploy.sh` or
  any deploy/sync script, SSH into any Pi or the Home Assistant host,
  `docker exec` where a device uses Docker, calling the live Home
  Assistant instance (including read-only calls like a config check),
  restarting/reloading any live service - always ask for explicit
  confirmation before running it, every time. No standing approval, even
  for actions that seem read-only - the live system is a real house, not
  a throwaway environment.

## Validating Home Assistant config

There's no local HA instance to test against. The live instance runs bare
metal (Home Assistant Core, no Docker) on its own host on the local
network, reachable over HTTP on port 8123 at its hostname (ask the user
for it rather than assuming - don't put it in this file) when this
machine is on that network - but the exact way to reach it for validation
(SSH + `hass --script check_config` run directly on that host, calling a
`check_config`-style service over the REST API, etc.) isn't nailed down
yet. `hass --script check_config` itself only parses/validates YAML - it
doesn't restart or apply anything - but per the rule above, running it
against the live instance still needs confirmation first since it does
touch the real host over the network.

Until this is resolved: say explicitly when a config change hasn't been
validated, rather than claiming it's correct. Don't guess at the
validation command - ask.

## Language

CLAUDE.md and new documentation should be in English. (The original
project-context doc was in German; it's being translated - see
`readme.md`.)

Code, identifiers and comments are English; user-facing text is German.

- **English, ASCII only**: MQTT topics, event names, entity IDs, file and
  directory names, `ROOM=` values, and any code/config key. These are
  matched by exact string, so umlauts or translated wording would silently
  break automations.
- **German (UTF-8 is fine)**: notification `title`/`message` text, dashboard
  and entity friendly names, automation `alias`/`description` shown in the
  HA UI.
- Never build logic on translated strings. Satellites publish stable
  English keys/codes (e.g. `filter_clogged`); the central HA automation maps
  them to German text.
- Keep the German wording in one place (the central `notify` automations,
  or `common/` if it grows), not scattered across rooms.
