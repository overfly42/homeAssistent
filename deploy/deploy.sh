#!/usr/bin/env bash
# Runs on a satellite Pi via the polling systemd timer (see deploy/systemd/).
# Pulls the repo, validates that this Pi's room actually exists in it, then
# syncs only that room's config plus the shared common/ config locally.
set -euo pipefail

ROLE_FILE=/etc/satellite/role
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR=/opt/satellite/config

if [[ ! -f "$ROLE_FILE" ]]; then
  echo "deploy.sh: $ROLE_FILE not found - this Pi has no assigned room" >&2
  exit 1
fi
source "$ROLE_FILE"

if [[ -z "${ROOM:-}" ]]; then
  echo "deploy.sh: ROOM is not set in $ROLE_FILE" >&2
  exit 1
fi

BEFORE_REV="$(git -C "$REPO_DIR" rev-parse HEAD)"
git -C "$REPO_DIR" pull --ff-only
AFTER_REV="$(git -C "$REPO_DIR" rev-parse HEAD)"

if [[ "$BEFORE_REV" == "$AFTER_REV" ]]; then
  exit 0
fi

if [[ ! -d "$REPO_DIR/rooms/$ROOM" ]]; then
  echo "deploy.sh: rooms/$ROOM does not exist in repo - refusing to deploy" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
rsync -a --delete "$REPO_DIR/rooms/$ROOM/" "$TARGET_DIR/"
rsync -a "$REPO_DIR/common/" "$TARGET_DIR/common/"

systemctl restart satellite-agent
