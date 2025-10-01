#!/usr/bin/env bash
# The deploy. Run from a laptop. You need the SSH key for the box.
#
#   ./scripts/deploy.sh
#
# There is no staging. This goes to the machine that serves real traffic.
set -e

BOX=deploy@34.90.__.__   # the prod VM (GCP, europe-west4)

echo "syncing code..."
rsync -az --exclude node_modules --exclude .git ./ "$BOX:/opt/wellis-status/"

echo "restarting..."
ssh "$BOX" 'cd /opt/wellis-status && docker compose up -d --build'

echo "done. check http://34.90.__.__:8080/api/summary"
