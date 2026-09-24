#!/usr/bin/env bash
# Rehearses migrations/*.sql against a throwaway Neon branch before they
# ever touch prod: creates a branch off the project's default branch
# (child branches keep the parent's roles and passwords, so the only
# thing that changes in the connection URL is the host), runs
# scripts/migrate.sh against it, then deletes the branch -- always, even
# if the rehearsal itself failed. Exit code reflects whether the
# rehearsal passed; .github/workflows/migrate.yml only proceeds to prod
# if this exits 0.
#
#   NEON_API_KEY=... NEON_PROJECT_ID=... MIGRATOR_DATABASE_URL=... \
#     ./scripts/migrate-rehearse.sh
#
# ASSUMPTIONS ABOUT THE NEON API — check these before relying on this in
# anger, they're written from documentation/memory, not a live call
# (this script was written under a "don't run anything against Neon"
# constraint):
#   - POST /projects/{id}/branches with a JSON body of
#     {"branch": {"name": ...}, "endpoints": [{"type": "read_write"}]}
#     creates a branch off the project's default branch (no parent_id
#     given) and a compute endpoint for it in one call.
#   - The response has the new branch's id at .branch.id and the new
#     endpoint's hostname at .endpoints[0].host.
#   - DELETE /projects/{id}/branches/{branch_id} removes it.
# If any of those are wrong, this script's error will point at the exact
# curl/jq line to fix -- the rest of the script (host-swap, migrate.sh
# invocation, cleanup-on-any-exit) doesn't depend on the details.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

: "${NEON_API_KEY:?NEON_API_KEY is required}"
: "${NEON_PROJECT_ID:?NEON_PROJECT_ID is required}"
: "${MIGRATOR_DATABASE_URL:?MIGRATOR_DATABASE_URL is required}"

NEON_API="https://console.neon.tech/api/v2"
BRANCH_NAME="ci-rehearsal-$(date +%s)-$$"

echo "==> creating Neon branch $BRANCH_NAME off the default branch"
create_response="$(curl -sf -X POST "$NEON_API/projects/$NEON_PROJECT_ID/branches" \
  -H "Authorization: Bearer $NEON_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"branch\":{\"name\":\"$BRANCH_NAME\"},\"endpoints\":[{\"type\":\"read_write\"}]}")"

branch_id="$(printf '%s' "$create_response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["branch"]["id"])')"
branch_host="$(printf '%s' "$create_response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["endpoints"][0]["host"])')"

if [ -z "$branch_id" ] || [ -z "$branch_host" ]; then
  echo "could not read branch id / endpoint host from Neon's response -- see the ASSUMPTIONS note at the top of this script" >&2
  echo "response was: $create_response" >&2
  exit 1
fi

echo "    branch: $branch_id"
echo "    host:   $branch_host"

# Runs on every exit path -- success, a failed migration, or this script
# erroring out earlier -- so the branch never outlives the rehearsal.
cleanup() {
  echo "==> deleting Neon branch $branch_id (cleanup, runs regardless of outcome)"
  if ! curl -sf -X DELETE "$NEON_API/projects/$NEON_PROJECT_ID/branches/$branch_id" \
    -H "Authorization: Bearer $NEON_API_KEY" >/dev/null; then
    echo "    warning: branch delete failed, remove $branch_id by hand" >&2
  fi
}
trap cleanup EXIT

# Child branches keep the parent's role/password -- only the host
# changes. postgresql://user:pass@HOST/db?query -- everything up to and
# including the "@" and from the next "/" onward stays the same.
branch_url="$(printf '%s' "$MIGRATOR_DATABASE_URL" | sed -E "s#(://[^@]+@)[^/]+(/.*)#\\1${branch_host}\\2#")"

echo "==> waiting for the branch endpoint to accept connections"
ready=0
attempt=1
while [ "$attempt" -le 20 ]; do
  if docker run --rm postgres:18-alpine psql "$branch_url" -Atqc "SELECT 1;" >/dev/null 2>&1; then
    ready=1
    break
  fi
  attempt=$((attempt + 1))
  sleep 3
done
if [ "$ready" != "1" ]; then
  echo "branch endpoint never became reachable" >&2
  exit 1
fi

echo "==> running scripts/migrate.sh against the rehearsal branch"
docker run --rm -e DATABASE_URL="$branch_url" \
  -v "$(pwd)/migrations:/migrations:ro" -v "$(pwd)/scripts:/scripts:ro" \
  postgres:18-alpine sh /scripts/migrate.sh

echo "==> rehearsal passed"
