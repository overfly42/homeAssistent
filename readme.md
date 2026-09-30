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
│   ├── kueche/{devices.yaml, automations.yaml, satellite.yaml}
│   ├── badezimmer/{devices.yaml, automations.yaml}
│   └── wohnzimmer/{devices.yaml, automations.yaml}
├── common/shared_templates.yaml
└── deploy/
    ├── deploy.sh           # runs on each satellite Pi via systemd timer
    └── systemd/            # satellite-deploy.service + .timer (polling pull, ~2 min)
```

Room names above are placeholders from the project doc below - rename/add
`rooms/<room>/` directories to match your actual house.

See `Hausautomatisierung Projektbeschreibung und Kontext.md` below for the
full architecture and the reasoning behind these decisions.

# Hausautomatisierung: Projektbeschreibung und Kontext
 
2026-09-17 · @Someone
 
## Überblick
 
Ziel des Projekts ist eine Hausautomatisierung auf Basis von Shelly-Geräten, gesteuert über Home Assistant als zentralen Hub, mit Raspberry Pis als dezentralen Satelliten (z. B. pro Raum). Konfiguration und Automatisierungslogik werden per GitOps verwaltet: Änderungen landen im Git-Repo und werden von dort automatisiert auf die betroffenen Geräte ausgerollt, ohne manuelles Kopieren oder SSH-Handarbeit.
 
## Architektur
 
- **Zentraler Hub**: Raspberry Pi 4/5 oder Mini-PC mit Home Assistant, verwaltet alle Shelly-Geräte lokal (native Integration, keine Cloud-Abhängigkeit)
- **Satelliten**: weitere Raspberry Pis, je einem Raum zugeordnet (Küche, Badezimmer, ...), betreiben z. B. ESPHome-Satelliten, MQTT-Bridges, Node-RED oder eigene Docker-Container
- **Git-Repo**: Single Source of Truth für alle Configs (Home-Assistant-YAMLs, ESPHome-Definitionen, Docker-Compose-Dateien, Ansible-Playbooks)
Jeder Satellit kennt nur seine eigene Rolle (den Raum, dem er zugeordnet ist) und bezieht die passende Konfiguration automatisiert aus dem zentralen Repo.
 
## Deployment-Mechanismus
 
Zwei mögliche Ansätze, empfohlen wird Pull für ein Heimnetz ohne öffentlich erreichbare Server:
 
**Pull via systemd (empfohlen)**
 
1. Deploy-Agent auf jedem Pi läuft per systemd-Timer (alle 1–5 Min)
2. Ablauf: `git pull` → Diff prüfen → bei Änderung: Config validieren, Dienst neu laden/`docker compose up -d --build`
3. Für ESPHome-Satelliten: CI baut die Firmware (`esphome compile` via GitHub Actions), Gerät zieht sich das Image per OTA
**Push via CI (GitHub Actions + Ansible)**
 
- Bei Push auf `main`: (self-hosted) Actions Runner im lokalen Netz führt Syntax-Checks aus
- `ansible-playbook` verteilt Configs per SSH an alle Zielgeräte, restartet Dienste
- Vorteil: sofortiges Deployment, klarer Trigger, Rollback über Git-Revert + erneuten Playbook-Lauf
Vor jedem Deploy: Config-Validierung (z. B. `hass --script check_config`), damit ein fehlerhafter Commit den Hub nicht lahmlegt.
 
### Zweistufiges Push/Pull-Modell (Entscheidung)
 
Ein zentraler lokaler Pi ist der einzige Netzwerkteilnehmer mit Internetzugriff. Er holt Änderungen per **Pull von GitHub** und verteilt sie anschließend intern per **Push bzw. Pull-Trigger** an die Satelliten-Pis – weder Shelly-Geräte noch Satelliten-Pis erhalten Internetzugriff.
 
**Alternativen für den GitHub-Pull auf dem zentralen Pi**
 
| Methode | Funktionsweise | Abwägung |
| --- | --- | --- |
| Periodischer `git pull` (Polling) | systemd-Timer/Cron ruft alle 1–5 Min `git pull` | Einfachste Lösung, nur ausgehende HTTPS-Verbindung nötig; Verzögerung bis zu Intervall-Länge |
| Self-hosted GitHub Actions Runner | Runner läuft auf dem Pi, baut nur ausgehende Verbindung zu GitHub auf, wird bei Push sofort aktiviert | Praktisch verzögerungsfrei, kein offener Port nötig; zusätzlicher Dienst zu pflegen |
| Webhook-Relay (z. B. smee.io) | GitHub-Webhook wird über einen ausgehend aufgebauten Tunnel an einen lokalen Empfänger weitergeleitet | Sofortige Reaktion ohne Portfreigabe; Abhängigkeit von externem Relay-Dienst |
| git-sync (Sidecar-Tool) | Fertiges Tool, hält einen Git-Ordner kontinuierlich synchron | Alternative zu eigenem Polling-Skript, weniger Wartungsaufwand |
 
**Entscheidung: Polling-Timer.** Für ein privates Heimnetz ohne Team und ohne Eile bei Deployments ist der einfache `git pull` per systemd-Timer sowohl am einfachsten als auch am robustesten:
 
- Trivial zu debuggen ("läuft der Timer? was sagt `git pull`?"), keine zusätzlichen Abhängigkeiten
- Kein zusätzlicher Dienst, der selbst überwacht werden müsste – ein Actions Runner kann selbst abstürzen, ohne dass es sofort auffällt
- Kein Henne-Ei-Problem bei fehlender Internetverbindung: verpasste Zyklen holen sich beim nächsten erfolgreichen `git pull` einfach den aktuellen Stand
- Die Verzögerung von wenigen Minuten gegenüber "sofort" spielt bei Hausautomatisierung praktisch keine Rolle
**Verworfen**: Self-hosted Actions Runner (lohnt sich erst bei mehreren gleichzeitig committenden Personen mit Bedarf an sofortigem Feedback – unnötige Komplexität für ein Ein-Personen-Setup) sowie Webhook-Relay (zusätzliche externe Abhängigkeit ohne echten Vorteil hier). git-sync bleibt als spätere Option denkbar, ist aber gegenüber dem simplen Timer kein Gewinn.
 
**Verteilung an die Satelliten (nur internes Netzwerk)**
 
1. Zentraler Pi zieht das Repo von GitHub und hält lokal eine aktuelle Kopie (z. B. lokaler Git-Mirror oder Dateiserver)
2. Verteilung per **Push**: zentraler Pi kopiert per SSH/Ansible/rsync die passenden `rooms/$ROOM/`-Configs direkt auf die Satelliten
3. Alternativ **Pull-Trigger via MQTT**: zentraler Pi publiziert nach erfolgreichem Sync eine Nachricht wie `home/$ROOM/deploy` mit Versionskennung; der Satellit holt sich daraufhin seine Config per rsync/HTTP vom zentralen Pi (nicht von GitHub)
MQTT dient hier als entkoppelnder Kommunikationsstandard: Satelliten müssen den zentralen Pi nicht aktiv abfragen, und der zentrale Pi muss die Erreichbarkeit einzelner Satelliten nicht kennen – beide Seiten kommunizieren nur über den Broker.
 
## Raumbasierte Konfigurationsstruktur
 
Prinzip: vollständiger Raum-Katalog liegt zentral im Repo, jeder Pi kennt lokal nur seine eigene Rollen-Kennung (welcher Raum er ist) und zieht sich beim Deployment nur die passende Teilkonfiguration.
 
**Repo-Layout**
 
```
repo/
├── rooms/
│   ├── kueche/{devices.yaml, automations.yaml, satellite.yaml}
│   ├── badezimmer/{devices.yaml, automations.yaml}
│   └── wohnzimmer/...
├── common/shared_templates.yaml
└── deploy/deploy.sh
```
 
**Auf dem Pi (nicht im Repo, lokal angelegt)**: `/etc/satellite/role` mit z. B. `ROOM=kueche`
 
**Deploy-Skript**
 
```bash
source /etc/satellite/role
git pull
rsync -a --delete repo/rooms/$ROOM/ /opt/satellite/config/
rsync -a repo/common/ /opt/satellite/config/common/
systemctl restart satellite-agent
```
 
Der Pi bleibt so austauschbar: neu flashen, `ROOM` lokal setzen, Agent starten – Rest kommt automatisch aus dem Repo. Das Repo selbst kennt keine physische Zuordnung Pi↔Raum. Der zentrale Home-Assistant-Hub durchläuft die gesamte `rooms/`-Struktur ohne Filterung.
 
## Sicherheit und Secrets-Management
 
**Öffentliches Repo**: Automatisierungslogik (Skripte, Playbooks, Compose-Struktur, ESPHome-Basis-YAMLs) kann öffentlich sein – reiner Code, keine Geheimnisse. Kritisch werden erst: IP-Adressen/Hostnamen/Portfreigaben, Gerätenamen mit Rückschlüssen auf Anwesenheit, API-Tokens/WLAN-Passwörter/MQTT-Zugangsdaten, Grundrisse/Raumnamen in Kombination mit Kamera-/Sensor-Setups. Faustregel: Struktur öffentlich, Werte privat.
 
**Netzwerksegmentierung**: Nur der zentrale Pi hat Internetzugriff (für den GitHub-Pull); Shelly-Geräte und Satelliten-Pis erhalten keinerlei Internetzugriff und kommunizieren ausschließlich innerhalb des lokalen Netzes (MQTT-Broker, SSH, rsync). Empfehlenswert: eigenes VLAN bzw. Firewall-Regeln, die ausgehenden Internetverkehr für das Shelly-/Satelliten-Subnetz komplett blockieren.
 
**Wo Passwörter liegen**
 
| Bereich | Mechanismus |
| --- | --- |
| Home Assistant | `secrets.yaml` (per `.gitignore` ausgeschlossen), im Repo nur `secrets.yaml.example` |
| Ansible | `ansible-vault` (AES-256-verschlüsselt, kann im Repo bleiben), Vault-Passwort separat |
| Docker/Compose | lokale `.env`-Datei pro Gerät, referenziert per `${VAR}`, in `.gitignore` |
| Mehrere Geräte zentral | Secrets-Manager wie HashiCorp Vault oder self-hosted Vaultwarden |
| SSH zwischen Pis | Key-based Auth statt Passwörtern |
 
Zusätzlich empfohlen: GitHub Secret-Scanning aktivieren, `git-crypt` oder `sops` als Alternative/Ergänzung zu ansible-vault für weitere verschlüsselte Dateien.
 
## Kommunikation Skript ↔ Home Assistant
 
| Methode | Einsatz |
| --- | --- |
| REST API | Einfachster Weg: Long-Lived Access Token, Zustände lesen/Services aufrufen per `curl`/`requests`; gut für seltene/einmalige Aufrufe |
| WebSocket API | Echtzeit-Reaktion auf Zustandsänderungen statt Polling; komplexer (Auth-Handshake, Subscriptions) |
| MQTT | Passt zur raumbasierten Satelliten-Struktur: Pi publiziert auf Topics, HA erkennt Entitäten automatisch per MQTT-Discovery, keine API-Calls nötig |
| Home Assistant CLI (`hass-cli`) | Für einfache Kommandozeilen-Interaktion direkt auf dem HA-Host |
| AppDaemon / pyscript | Für komplexere Logik (State-Machines), läuft als eigener Prozess mit direktem Zugriff auf den State-Machine-Kontext |
 
Für die Satelliten-Pis empfiehlt sich MQTT als primärer Kanal, da Topic-Namen einfach pro Raum-Ordner im Repo mitverwaltet werden können; REST API eignet sich ergänzend für Status-Checks beim Deploy-Start.
 
**Entscheidung**: MQTT wird als primärer Kommunikationsstandard zwischen den Systemen festgelegt, da es diese entkoppelt (kein gegenseitiges Kennen von Adressen/Erreichbarkeit nötig) und sich sauber mit der Netzwerksegmentierung verträgt, bei der Shelly-Geräte und Satelliten keinen Internetzugriff haben.
 
## Benachrichtigungen an die Companion App
 
Home Assistant stellt für jedes verknüpfte Handy automatisch einen `notify.mobile_app_<gerätename>`-Service bereit. Ein Pi-Skript ruft nicht direkt die App an, sondern löst über HA (REST, MQTT-Automation) diesen Service aus – HA übernimmt die Zustellung.
 
**Beispiel per REST**
 
```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"message": "Blumen in der Küche gießen", "title": "Manuelle Aufgabe"}' \
  http://homeassistant.local:8123/api/services/notify/mobile_app_dein_handy
```
 
**Interaktive Benachrichtigungen (actionable notifications)**: Buttons wie "Erledigt"/"Später erinnern" lassen sich einbauen; HA fängt den Klick als Event ab und kann darauf reagieren (z. B. `input_boolean` zurücksetzen).
 
**Empfohlener Ablauf für die raumbasierte Architektur**
 
1. Pi meldet Ereignis per MQTT, z. B. `home/kueche/wartung_erforderlich`
2. Zentrale HA-Automatisierung lauscht raumunabhängig auf `home/+/wartung_erforderlich` und übersetzt es in eine `notify`-Aktion an die passende Person
3. Notify-Logik (wer bekommt was) bleibt zentral in HA gepflegt; der Pi kennt nur ein einfaches MQTT-Event, keine Personen- oder App-Endpunkte – die gemeinsame Automatisierungsregel liegt als YAML im `common/`-Ordner des Repos
## Offene Punkte und nächste Schritte
 
- [ ] Deploy-Skript um Validierung erweitern: prüfen, ob der in `ROOM` angegebene Ordner im Repo existiert, bevor rsync läuft
- [ ] \~\~Konkrete Pull-Methode wählen\~\~ – entschieden: Polling-Timer (siehe Deployment-Mechanismus)
- [ ] Secrets-Management-Werkzeug festlegen (ansible-vault vs. zentraler Vault/Vaultwarden)
- [ ] MQTT-Discovery-Payload-Vorlage für die Raum-Struktur ausarbeiten
- [ ] Konkrete Automatisierungsregel für Wartungsmeldung → Push-Benachrichtigung im `common/`-Ordner definieren
- [ ] Secret-Scanning bei öffentlichem Repo aktivieren
 
