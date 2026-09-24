#!/bin/sh
# Applies migrations/*.sql in order, each in its own transaction, using
# psql from the postgres image. This script assumes `psql` is already on
# PATH — it's meant to run inside a container built FROM the postgres
# image (see the `migrate` service in docker-compose.yml for the local
# path), or the same way by hand against a real database:
#
#   docker run --rm -e DATABASE_URL=postgresql://owner@host/db \
#     -v "$(pwd)/migrations:/migrations:ro" -v "$(pwd)/scripts:/scripts:ro" \
#     postgres:18-alpine sh /scripts/migrate.sh
#
# Run as the schema owner, never as portal_app/notifier_app — those are
# least-privilege runtime roles (see migrations/004_app_role_grants.sql),
# they don't own the schema and shouldn't be running DDL.
#
# --baseline <version>
#   Marks every migration up to and including <version> as applied in
#   schema_migrations WITHOUT running its SQL, then exits. For a database
#   that was already brought to that state by hand.
#
#   That is exactly the real prod DB: 001_init.sql and 002_add_index.sql
#   were applied by hand against it before this runner existed (see
#   RUNBOOK.md and infra/PROVISIONING.md). The first real run of this
#   script against prod should be:
#
#     ./scripts/migrate.sh --baseline 002_add_index
#
#   which records 001 and 002 as applied without touching prod's already-
#   correct schema. A normal run afterwards applies whatever comes next
#   (skipping 003 until it's fixed — see FINDINGS.md DATA-01/DATA-02).
set -eu

MIGRATIONS_DIR="${MIGRATIONS_DIR:-/migrations}"
: "${DATABASE_URL:?DATABASE_URL is required}"

# Fail fast instead of queueing behind a long-running notifier query.
export PGOPTIONS="-c lock_timeout=5000 -c statement_timeout=60000"

psql_c() {
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 "$@"
}

echo "==> ensuring schema_migrations exists"
psql_c -c "CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());"

applied="$(psql_c -Atqc "SELECT version FROM schema_migrations ORDER BY version;")"

is_applied() {
  printf '%s\n' "$applied" | grep -qx "$1"
}

BASELINE=""
if [ "${1:-}" = "--baseline" ]; then
  BASELINE="${2:?--baseline requires a version, e.g. --baseline 002_add_index}"
fi

resolve_version() {
  needle="$1"
  match=""
  for path in "$MIGRATIONS_DIR"/*.sql; do
    stem="$(basename "$path" .sql)"
    case "$stem" in
      "$needle" | "$needle"_*)
        if [ -n "$match" ] && [ "$match" != "$stem" ]; then
          echo "ambiguous --baseline value '$needle': matches both $match and $stem" >&2
          exit 1
        fi
        match="$stem"
        ;;
    esac
  done
  if [ -z "$match" ]; then
    echo "no migration matches --baseline value '$needle'" >&2
    exit 1
  fi
  echo "$match"
}

if [ -n "$BASELINE" ]; then
  target="$(resolve_version "$BASELINE")"
  echo "==> baselining up to and including $target (recording only, not executing)"
  for path in "$MIGRATIONS_DIR"/*.sql; do
    stem="$(basename "$path" .sql)"
    if is_applied "$stem"; then
      echo "    $stem already applied"
    else
      echo "    baseline: $stem"
      psql_c -c "INSERT INTO schema_migrations (version) VALUES ('$stem');"
      applied="$(printf '%s\n%s' "$applied" "$stem")"
    fi
    [ "$stem" = "$target" ] && break
  done
  echo "==> baseline complete"
  exit 0
fi

for path in "$MIGRATIONS_DIR"/*.sql; do
  stem="$(basename "$path" .sql)"
  if is_applied "$stem"; then
    echo "==> $stem already applied, skipping"
    continue
  fi
  echo "==> applying $stem"
  psql_c -c "BEGIN;" -f "$path" -c "INSERT INTO schema_migrations (version) VALUES ('$stem'); COMMIT;"
done

echo "==> done"
