#!/usr/bin/env python3
"""Per-room satellite agent.

Connects to the MQTT broker on the sync Pi and publishes an online/offline
heartbeat for this room (home/<room>/status, retained, with a last-will
"offline") so Home Assistant can tell whether the satellite is reachable.

This is the minimal starting point restarted by deploy/deploy.sh after
every config pull - extend it with real per-room sensor/automation logic
(e.g. the CO2 measurement referenced in the top-level readme) as needed.
"""
import os
import sys

import paho.mqtt.client as mqtt

ROOM = os.environ.get("ROOM")
BROKER = os.environ.get("MQTT_BROKER")
PORT = int(os.environ.get("MQTT_PORT", "1883"))
USERNAME = os.environ.get("MQTT_USERNAME")
PASSWORD = os.environ.get("MQTT_PASSWORD")

if not ROOM:
    sys.exit("satellite-agent: ROOM is not set (expected from /etc/satellite/role)")
if not BROKER:
    sys.exit("satellite-agent: MQTT_BROKER is not set (expected from /etc/satellite/mqtt.env)")

STATUS_TOPIC = f"home/{ROOM}/status"


def on_connect(client, userdata, flags, reason_code):
    client.publish(STATUS_TOPIC, "online", retain=True)


client = mqtt.Client(client_id=f"satellite-{ROOM}")
if USERNAME:
    client.username_pw_set(USERNAME, PASSWORD)
client.will_set(STATUS_TOPIC, "offline", retain=True)
client.on_connect = on_connect

client.connect(BROKER, PORT)
client.loop_forever()
