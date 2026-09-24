#!/usr/bin/env bash
# Runs both test suites in containers against the compose db. Fixtures
# use the owner (admin) role; the code under test connects as its real
# least-privilege app role, so migrations/004_app_role_grants.sql is
# actually exercised, not just assumed correct.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ADMIN_URL="postgresql://postgres:postgres@db:5432/wellis"
PORTAL_URL="postgresql://portal_app:portal_app_dev_password@db:5432/wellis"
NOTIFIER_URL="postgresql://notifier_app:notifier_app_dev_password@db:5432/wellis"
# Fixed test-only token, not a secret — raw value "test-token".
TEST_TOKEN="test-token"
TEST_TOKEN_HASH="4c5dc9b7708905f77f5e5d16316b5dfb425e68cb326dcd55a860e90a7707031e" # gitleaks:allow — sha256 of "test-token" above, not a secret

echo "==> building images"
docker compose build db migrate portal notifier >/dev/null

echo "==> db"
docker compose up -d --wait db

echo "==> migrate"
# `up --wait` doesn't handle a one-shot service well (it flags any exit,
# even 0, as failure) — `run` blocks and gives us the real exit code.
docker compose run --rm migrate

echo "==> check: no patient row with NULL first_name"
# Cheap guard on 003's trigger/backfill. CI runs this after `make up`,
# so it checks the seeded rows; on an empty db it checks nothing.
null_count=$(docker compose run --rm --no-deps --entrypoint psql migrate "$ADMIN_URL" -Atqc "SELECT count(*) FROM patients WHERE first_name IS NULL;")
if [ "$null_count" != "0" ]; then
  echo "found $null_count patient row(s) with NULL first_name — 003's trigger/backfill isn't doing its job"
  exit 1
fi

echo "==> portal tests (as portal_app)"
docker compose run --rm --no-deps \
  -e DATABASE_URL="$PORTAL_URL" \
  -e ADMIN_DATABASE_URL="$ADMIN_URL" \
  -e API_TOKENS="tester:${TEST_TOKEN_HASH}" \
  -e TEST_TOKEN="$TEST_TOKEN" \
  --entrypoint node \
  portal --test src/app.test.js

echo "==> notifier tests (as notifier_app)"
# The image only COPYs notifier.py (see notifier/Dockerfile — it's the
# real Lambda build, kept minimal on purpose); mount the test file and
# dev requirements in on top rather than adding them to the image.
docker compose run --rm --no-deps \
  -e DATABASE_URL="$NOTIFIER_URL" \
  -e ADMIN_DATABASE_URL="$ADMIN_URL" \
  -v "$(pwd)/notifier/test_notifier.py:/var/task/test_notifier.py:ro" \
  -v "$(pwd)/notifier/requirements.txt:/var/task/requirements.txt:ro" \
  -v "$(pwd)/notifier/requirements-dev.txt:/var/task/requirements-dev.txt:ro" \
  --entrypoint sh \
  notifier -c "pip install --quiet -r requirements-dev.txt && pytest -v"

echo "==> all tests passed"
