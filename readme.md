# Overview
This is the main repository for a custom Home Assistant automation using:
- Home Assistant (Raspberry PI)
- Fritbox
- Shelly
- Rasperry PIs as Satalites

This is a repository you could take as insperation for own projects.
## CO2 Mesurement
Examples from: https://github.com/adafruit/Adafruit_CircuitPython_SCD4X.git
Local Structure
Python Home ~/CO2
Project Home ~/homeAssistant
SCD40x Example Home ~/Adafruit_CircuitPython_SCD4X

## Repo layout

```
repo/
├── configuration.yaml     # central Home Assistant hub, includes rooms/ + common/
├── secrets.yaml.example   # copy to secrets.yaml (git-ignored), fill in real values
├── rooms/
│   ├── kitchen/{devices.yaml, automations.yaml, satellite.yaml}
│   ├── bathroom/{devices.yaml, automations.yaml}
│   └── living_room/{devices.yaml, automations.yaml}
├── common/shared_templates.yaml
├── satellite-agent/
│   ├── agent.py            # per-room MQTT heartbeat, restarted by deploy.sh
│   └── requirements.txt
└── deploy/
    ├── deploy.sh           # runs on each satellite Pi via systemd timer
    ├── git-hooks/
    │   └── post-receive    # installed on the sync Pi's bare repo
    └── systemd/            # satellite-deploy.{service,timer} (polling pull, ~2 min)
                             # + satellite-agent.service (runs agent.py)
                             # + repo-pull.{service,timer} (plain `git pull`,
                             #   for the Home Assistant host)
                             # + repo-push-github.{service,timer} (sync Pi
                             #   pushes its bare repo to GitHub, one-way)
```

Room names above are placeholders from the project doc below - rename/add
`rooms/<room>/` directories to match your actual house.

See "Home Automation: Project Description and Context" below for the full
architecture and the reasoning behind these decisions.

# Home Automation: Project Description and Context

2026-09-17 · @Someone

## Overview

The goal of this project is home automation based on Shelly devices,
controlled via Home Assistant as a central hub, with Raspberry Pis as
decentralized satellites (e.g. one per room). Configuration and automation
logic are managed via GitOps: changes land in the Git repo and are rolled
out from there automatically to the affected devices, with no manual
copying or SSH work.

## Architecture

- **Sync/broker Pi**: the source of truth for day-to-day work. Hosts a
  bare git repo that local development pushes into directly over SSH (not
  GitHub), runs the MQTT broker, and keeps a working copy that satellite
  Pis and the Home Assistant host each pull their config from (via their
  own systemd timers). Separately pushes that repo to GitHub on its own
  timer, one-way, so GitHub stays an up-to-date downstream mirror rather
  than the source of truth
- **Home Assistant host**: a separate bare-metal machine (no Docker)
  running Home Assistant, manages all Shelly devices (native integration,
  no cloud dependency). It does have its own internet access, but
  deliberately doesn't use it for config sync - it pulls from the sync
  Pi's working copy over the local network instead, via its own systemd
  timer, and connects to the MQTT broker on the sync Pi for device
  discovery/control
- **Satellites**: additional Raspberry Pis, each assigned to a room
  (kitchen, bathroom, ...), running `satellite-agent` (`satellite-agent/agent.py`,
  restarted after every deploy) plus e.g. ESPHome satellites, MQTT bridges,
  Node-RED, or their own Docker containers. They don't talk to the Shelly
  devices directly (at least for now) - Shelly devices go straight to the
  MQTT broker on the sync Pi, independent of the satellites
- **Git repo**: single source of truth for all configs (Home Assistant
  YAMLs, ESPHome definitions, Docker Compose files, Ansible playbooks)

```
 Dev workstation                                         GitHub
        │                                          (downstream mirror,
        │ git push (SSH, bare repo)                 not pulled from)
        ▼                                                  ▲
┌────────────────────────────┐                             │
│       Sync/broker Pi        │   git push (systemd timer,  │
│  bare repo (source of       │───one-way, ~2 min)──────────┘
│  truth) + working copy      │
│  (post-receive hook keeps   │
│  it current) + MQTT broker  │
│  (has internet access)      │
└──────────────┬──────────────┘
               │ git pull (own systemd timer per consumer,
               │ local network only)
     ┌─────────┼─────────────────────────┐
     ▼         ▼                         ▼
 Satellite  Satellite            Home Assistant host
 Pi(kitchen) Pi(bathroom)       (bare metal, has its own
                                 internet access but doesn't
                                 use it for config sync)
                                          │
                                          │ MQTT discovery +
                                          │ device control
                                          ▼
                                 Shelly devices
                                 (MQTT, local network)

  (local network only below the sync Pi - no internet access for
   satellite Pis or Shelly devices)
```

Each satellite only knows its own role (the room it's assigned to) and
pulls the matching config itself from the sync Pi's working copy. The Home
Assistant host, in contrast, pulls the full repo and is not filtered by
room - but both pull from the same place: the sync Pi, never GitHub
directly.

## Deployment mechanism

**Decision: push in once, pull out twice, mirror out one-way.**
Development changes are pushed directly (over SSH) into a bare repo on
the sync Pi - see "Git flow" below for why GitHub isn't the primary
remote anymore. From there, two independent consumers - satellite Pis and
the Home Assistant host - each pull via their own systemd timer (every
1-5 min), check the diff, and on change validate config and reload the
service / `docker compose up -d --build` (for satellites that use Docker;
the Home Assistant host is bare metal, so it's a direct `hass`
restart/reload there instead). For ESPHome satellites: CI builds the
firmware (`esphome compile` via GitHub Actions, off the GitHub mirror),
the device pulls the image via OTA.

A push-based distribution alternative (the sync Pi actively pushing
configs out via `ansible-playbook`/SSH instead of consumers pulling) was
considered and rejected: it needs the sync Pi to know which devices exist
and are currently reachable, instead of each device just catching up on
its own next tick. Pulling out is simpler to reason about and debug -
consistent with why pushing in is only used for the one step that
actually needs a human in the loop (local development).

Before every deploy: config validation (e.g. `hass --script
check_config`), so a broken commit doesn't take down the hub.

### Git flow: local push, GitHub as mirror (decision)

Local development pushes straight into a bare repo on the sync Pi over
SSH - that bare repo, not GitHub, is the source of truth. A
`post-receive` hook (`deploy/git-hooks/post-receive`) checks out the new
commit into a working copy on the sync Pi immediately, so pushes show up
for satellites/the HA host without waiting on a poll timer that was never
watching GitHub to begin with. Separately, the sync Pi pushes that bare
repo to GitHub on its own systemd timer (`deploy/systemd/repo-push-github.{service,timer}`),
one-way - GitHub becomes a downstream mirror (useful as an off-site
backup, and for the "take this as inspiration" framing at the top of this
file), not part of the deployment path.

This is also why the Home Assistant host pulls from the sync Pi instead
of GitHub even though it has its own internet access: one source of truth
for the whole deployment path, with GitHub only entering via the one-way
mirror push.

**Alternatives for getting local commits to GitHub**

| Method | How it works | Trade-off |
| --- | --- | --- |
| Periodic `git push` (polling) | systemd timer calls `git push github main` every ~2 min | Simplest, matches the polling pattern used everywhere else in this repo; delay up to the interval length |
| Push immediately via `post-receive` hook | The same hook that updates the working copy also pushes to GitHub right away | No delay; ties GitHub's availability to every local push succeeding, another thing the hook can fail on |
| Manual push | You run `git push github main` yourself when ready | No automation to maintain, but easy to forget and let the mirror go stale |

**Decision: periodic push via systemd timer.** Same reasoning as the
polling-pull decisions elsewhere in this doc: trivial to debug, no extra
dependency on hook reliability, and a mirror that's a couple of minutes
behind is fine since nothing in the deployment path depends on GitHub
being current.

**Distribution to the satellites and the Home Assistant host (internal
network only)**

1. Local development pushes into the sync Pi's bare repo (see above); the
   `post-receive` hook updates its working copy
2. Each satellite Pi and the Home Assistant host pull directly from that
   working copy on their own systemd timer - satellites via
   `deploy/deploy.sh` + `deploy/systemd/satellite-deploy.{service,timer}`,
   the HA host via the generic `deploy/systemd/repo-pull.{service,timer}` -
   satellites additionally rsync their own `rooms/$ROOM/` + `common/` into
   local config and restart their service

**Decision: pull, not push, for this hop too.** Satellites and the HA
host pull rather than the sync Pi pushing to them - no SSH/Ansible/rsync
push step, no MQTT pull-trigger needed either. Same reasoning throughout:
fewer moving parts, the sync Pi never needs to know which consumers exist
or are currently reachable, and an offline consumer just catches up on
its next tick.

## Room-based configuration structure

Principle: the full room catalog lives centrally in the repo; each Pi only
knows its own role locally (which room it is) and pulls only the matching
partial config at deploy time.

**Repo layout**

```
repo/
├── rooms/
│   ├── kitchen/{devices.yaml, automations.yaml, satellite.yaml}
│   ├── bathroom/{devices.yaml, automations.yaml}
│   └── living_room/...
├── common/shared_templates.yaml
└── deploy/deploy.sh
```

**On the Pi (not in the repo, created locally)**: `/etc/satellite/role`
with e.g. `ROOM=kitchen`

**Deploy script**

```bash
source /etc/satellite/role
git pull
rsync -a --delete repo/rooms/$ROOM/ /opt/satellite/config/
rsync -a repo/common/ /opt/satellite/config/common/
systemctl restart satellite-agent
```

This keeps the Pi interchangeable: reflash it, set `ROOM` locally, start
the agent - everything else comes automatically from the repo. The repo
itself has no concept of the physical Pi-to-room mapping. The Home
Assistant host walks the entire `rooms/` structure unfiltered.

**The agent being restarted**: `satellite-agent` (`satellite-agent/agent.py`
in this repo, installed via `deploy/systemd/satellite-agent.service`) is
what actually runs continuously on the Pi. Today it's a minimal heartbeat
- it connects to the MQTT broker on the sync Pi and publishes
`home/$ROOM/status` (`online`, with `offline` as its MQTT last-will), so
Home Assistant can tell whether a satellite is reachable. It's the
concrete place to add real per-room logic later (sensors, the CO2
measurement mentioned at the top of this file, etc.) - `deploy.sh`
restarting it after every pull means config changes take effect without a
manual step. Broker connection details for the agent live in
`/etc/satellite/mqtt.env` (local to each Pi, not in the repo - same
pattern as `/etc/satellite/role`).

## Security and secrets management

**Public repo**: automation logic (scripts, playbooks, compose structure,
base ESPHome YAMLs) can be public - it's just code, no secrets. What
becomes critical: IP addresses/hostnames/port forwards, device names that
reveal presence, API tokens/WiFi passwords/MQTT credentials, floor plans/
room names combined with camera/sensor setups. Rule of thumb: structure
public, values private.

**Network segmentation**: the sync/broker Pi has internet access (it's the
only device that talks to GitHub, as a one-way push mirror). The Home
Assistant host, being bare metal, has its own internet access too, but
doesn't rely on it for config sync - it pulls from the sync Pi over the
local network like everything else downstream. Shelly devices and
satellite Pis get no internet access at all and communicate exclusively
within the local network (MQTT broker, SSH, rsync). Recommended: a
dedicated VLAN or firewall rules that fully block outgoing internet
traffic for the Shelly/satellite subnet. Pushing into the sync Pi's bare
repo (local development) requires SSH access from the workstation doing
the pushing - local network or VPN, not exposed to the public internet.

**Where passwords live**

| Area | Mechanism |
| --- | --- |
| Home Assistant | `secrets.yaml` (excluded via `.gitignore`), repo only has `secrets.yaml.example` |
| `satellite-agent` (MQTT broker creds) | `/etc/satellite/mqtt.env`, local to each Pi, never in the repo - same pattern as `/etc/satellite/role` |
| Ansible | `ansible-vault` (AES-256 encrypted, can stay in the repo), vault password kept separately |
| Docker/Compose | local `.env` file per device, referenced via `${VAR}`, in `.gitignore` |
| Multiple devices, centrally | a secrets manager like HashiCorp Vault or self-hosted Vaultwarden |
| SSH between Pis, and from dev workstation into the sync Pi's bare repo | key-based auth instead of passwords |

Also recommended: enable GitHub secret scanning, and `git-crypt` or `sops`
as an alternative/addition to ansible-vault for further encrypted files.

## Communication: script ↔ Home Assistant

| Method | Use case |
| --- | --- |
| REST API | Simplest route: long-lived access token, read states/call services via `curl`/`requests`; good for rare/one-off calls |
| WebSocket API | Real-time reaction to state changes instead of polling; more complex (auth handshake, subscriptions) |
| MQTT | Fits the room-based satellite structure: Pi publishes to topics, HA discovers entities automatically via MQTT discovery, no API calls needed |
| Home Assistant CLI (`hass-cli`) | For simple command-line interaction directly on the HA host |
| AppDaemon / pyscript | For more complex logic (state machines), runs as its own process with direct access to the state machine context |

For the satellite Pis, MQTT is recommended as the primary channel, since
topic names can simply be managed alongside each room folder in the repo;
the REST API is a good fit as a supplement for status checks at deploy
start.

**Decision**: MQTT is set as the primary communication standard between
the systems, since it decouples them (no need for either side to know the
other's addresses/reachability) and fits cleanly with the network
segmentation where Shelly devices and satellites have no internet access.

## Notifications to the companion app

Home Assistant automatically provides a
`notify.mobile_app_<device_name>` service for every linked phone. A Pi
script doesn't call the app directly, but triggers this service via HA
(REST, MQTT automation) - HA handles delivery.

**Example via REST**

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"message": "Water the kitchen plants", "title": "Manual task"}' \
  http://homeassistant.local:8123/api/services/notify/mobile_app_your_phone
```

**Interactive notifications (actionable notifications)**: buttons like
"Done"/"Remind me later" can be built in; HA captures the click as an
event and can react to it (e.g. reset an `input_boolean`).

**Recommended flow for the room-based architecture**

1. Pi reports an event via MQTT, e.g. `home/kitchen/maintenance_required`
2. A central HA automation listens room-independently on
   `home/+/maintenance_required` and translates it into a `notify` action
   for the right person
3. Notify logic (who gets what) stays centrally maintained in HA; the Pi
   only knows a simple MQTT event, no person or app endpoints - the shared
   automation rule lives as YAML in the repo's `common/` folder

**Language convention**

Code and identifiers are English; user-facing text is German.

- English, ASCII only: MQTT topics, event names, entity IDs, file and
  directory names, `ROOM=` values. They are matched by exact string.
- German (UTF-8 is fine): notification `title`/`message`, entity friendly
  names, dashboard labels, automation `alias`/`description` shown in the UI.
- No logic on translated strings: the Pi publishes a stable key such as
  `filter_clogged`, and the central automation maps it to German text
  (e.g. "Küche: Filter wechseln"). The German wording lives centrally, not
  in each room.

## Initial installation

Bootstrap steps per host role, run once per device. After this, the
push/pull timers keep everything up to date automatically - no further
manual steps.

**Sync/broker Pi**

1. Create the bare repo that local development will push into, seeded
   from GitHub the first time only: `sudo git clone --bare
   <your-repo-url> /opt/homeAssistent.git`
2. Check out the working copy that satellites/the HA host will pull from:
   `sudo git clone /opt/homeAssistent.git /opt/homeAssistent`
3. Install the hook that keeps that working copy current on every push:
   `sudo cp deploy/git-hooks/post-receive
   /opt/homeAssistent.git/hooks/post-receive && sudo chmod +x
   /opt/homeAssistent.git/hooks/post-receive`
4. Add GitHub as a push-only remote on the bare repo: `sudo git
   --git-dir=/opt/homeAssistent.git remote add github <your-repo-url>`
5. Install an MQTT broker, e.g. Mosquitto: `sudo apt install mosquitto
   mosquitto-clients`, then configure a username/password - these also go
   into `secrets.yaml` (Home Assistant side) and `/etc/satellite/mqtt.env`
   (satellite side), see Security and secrets management below
6. Serve the working copy so satellites and the HA host can pull from it,
   e.g. `git daemon --base-path=/opt --export-all --reuseaddr` as its own
   systemd service, or any simple local git/HTTP server - the exact
   mechanism isn't fixed in this repo yet (see Open points), pick
   whichever fits your network
7. Install the push-to-GitHub timer: `sudo cp
   deploy/systemd/repo-push-github.{service,timer} /etc/systemd/system/`,
   then `sudo systemctl daemon-reload && sudo systemctl enable --now
   repo-push-github.timer`

**Developer workstation (one-time, per machine you'll push from)**

1. Add the sync Pi as a remote: `git remote add sync
   ssh://<user>@<sync-pi-host>/opt/homeAssistent.git`
2. From then on, `git push sync main` sends local commits straight to the
   sync Pi - that's the actual deploy trigger, not `git push origin`/GitHub

**Home Assistant host**

1. Install Home Assistant Core directly on the host (bare metal, no
   Docker - outside this repo's scope beyond that)
2. Clone from the sync Pi's working copy, not GitHub, to wherever HA's
   config directory points at: `sudo git clone
   <sync-pi>:/opt/homeAssistent /opt/homeAssistent` (or point HA's
   `config_dir` at that path directly)
3. Copy `secrets.yaml.example` to `secrets.yaml` inside that config
   directory and fill in real values - never commit `secrets.yaml` itself
4. Install the generic pull timer: `sudo cp
   deploy/systemd/repo-pull.{service,timer} /etc/systemd/system/`, then
   `sudo systemctl daemon-reload && sudo systemctl enable --now
   repo-pull.timer` - this pulls from the sync Pi, not GitHub, even though
   this host has its own internet access
5. Validate before relying on it: `hass --script check_config -c
   /opt/homeAssistent` run directly on the host (per `CLAUDE.md`, ask
   before running this against a live instance)

**Satellite Pi (per room)**

1. Flash Raspberry Pi OS and get it on the local network
2. Create `/etc/satellite/role` with e.g. `ROOM=kitchen` (must match an
   existing `rooms/<room>/` directory in the repo)
3. Create `/etc/satellite/mqtt.env` with `MQTT_BROKER=`, `MQTT_USERNAME=`,
   `MQTT_PASSWORD=` pointing at the sync Pi's broker - neither file is
   part of the repo, same as `/etc/satellite/role`
4. Clone the repo from the sync Pi's working copy, not GitHub - satellites
   have no internet access: `sudo git clone <sync-pi-mirror-url>
   /opt/homeAssistent`
5. Install the agent's Python dependencies: `pip install -r
   /opt/homeAssistent/satellite-agent/requirements.txt`
6. Install the units: `sudo cp
   /opt/homeAssistent/deploy/systemd/satellite-deploy.{service,timer}
   /opt/homeAssistent/deploy/systemd/satellite-agent.service
   /etc/systemd/system/`, then `sudo systemctl daemon-reload && sudo
   systemctl enable --now satellite-deploy.timer satellite-agent.service`
7. The first deploy runs on the next timer tick, or trigger it manually:
   `sudo /opt/homeAssistent/deploy/deploy.sh`

## Open points and next steps

- [x] Extend the deploy script with validation: check that the folder
  named by `ROOM` exists in the repo before rsync runs (done in
  `deploy/deploy.sh`)
- [x] ~~Pick a concrete pull method~~ - decided: polling timer (see
  Deployment mechanism)
- [ ] Decide on a secrets management tool (ansible-vault vs. a central
  Vault/Vaultwarden)
- [ ] Work out an MQTT discovery payload template for the room structure
- [ ] Define the concrete automation rule for maintenance notice → push
  notification in the `common/` folder
- [ ] Enable secret scanning on the public repo
- [ ] Pick and script the local git mirror mechanism the sync Pi serves to
  satellites (`git daemon` vs. a simple local HTTP/git server) - currently
  just a manual step in Initial installation, not templated in `deploy/`
