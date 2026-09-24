#!/usr/bin/env bash
# Builds both images, guards against undeployed schema changes, pushes to
# ECR, updates both Lambdas, smoke tests, and rolls back on a failed
# smoke test. Runs the same way in CI (.github/workflows/ci.yml's deploy
# job, after OIDC sets up AWS credentials) or by hand from a laptop:
#
#   AWS_PROFILE=backendlab-production PORTAL_URL=https://... ./scripts/deploy.sh [git-sha]
#
# Replaces the old rsync-to-a-VM version — there is no VM anymore.
#
# Rule this script enforces: schema goes first, code second. It refuses
# to deploy if any migrations/*.sql file isn't yet recorded in prod's
# schema_migrations — that means .github/workflows/migrate.yml (the
# human-gated migration runner) needs to run first. Corollary for
# whoever writes the next migration: code deployed under the OLD schema
# must keep working, because there's a window where the new schema is
# live but the old code still is too.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

AWS_REGION="eu-central-1"
PORTAL_REPO="wellis-status/portal"
NOTIFIER_REPO="wellis-status/notifier"
PORTAL_FUNCTION="wellis-status-portal"
NOTIFIER_FUNCTION="wellis-status-notifier"

IMAGE_TAG="${1:-$(git rev-parse HEAD)}"
: "${PORTAL_URL:?PORTAL_URL is required -- the deployed Function URL, used for the smoke test}"

# ::add-mask:: only means anything to GitHub Actions; it's harmless,
# inert text otherwise, so this stays safe to run by hand too.
mask() {
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "::add-mask::$1"
  fi
}

account_id="$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")"
registry="${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"
portal_image="${registry}/${PORTAL_REPO}:${IMAGE_TAG}"
notifier_image="${registry}/${NOTIFIER_REPO}:${IMAGE_TAG}"

echo "==> building images (linux/amd64, tag $IMAGE_TAG)"
docker build --platform linux/amd64 -t "$portal_image" ./portal
docker build --platform linux/amd64 -t "$notifier_image" ./notifier

echo "==> guard: checking for migrations pending against prod"
migrator_url="$(aws ssm get-parameter --name /wellis/prod/migrator/DATABASE_URL --with-decryption --query Parameter.Value --output text --region "$AWS_REGION")"
mask "$migrator_url"

applied="$(docker run --rm postgres:18-alpine psql "$migrator_url" -v ON_ERROR_STOP=1 -Atqc "SELECT version FROM schema_migrations ORDER BY version;")"

pending=""
for path in migrations/*.sql; do
  stem="$(basename "$path" .sql)"
  if ! printf '%s\n' "$applied" | grep -qx "$stem"; then
    pending="$pending $stem"
  fi
done

if [ -n "$pending" ]; then
  echo "pending migrations not yet applied to prod:$pending" >&2
  echo "run the migrate workflow first" >&2
  exit 1
fi
echo "    schema is caught up"

echo "==> pushing images to ECR"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$registry" >/dev/null

# Tags are immutable (see infra/terraform/prod/ecr.tf), so re-running a
# deploy for a commit that was already pushed once -- e.g. retrying
# after a failed smoke test -- must not try to push the same tag again.
push_if_new() {
  repo="$1"
  image="$2"
  if aws ecr describe-images --repository-name "$repo" --image-ids imageTag="$IMAGE_TAG" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "    $image already in ECR, skipping push"
  else
    docker push "$image"
  fi
}

push_if_new "$PORTAL_REPO" "$portal_image"
push_if_new "$NOTIFIER_REPO" "$notifier_image"

echo "==> recording current images, in case this deploy needs to roll back"
portal_prev_image="$(aws lambda get-function --function-name "$PORTAL_FUNCTION" --query 'Code.ImageUri' --output text --region "$AWS_REGION")"
notifier_prev_image="$(aws lambda get-function --function-name "$NOTIFIER_FUNCTION" --query 'Code.ImageUri' --output text --region "$AWS_REGION")"
echo "    portal:   $portal_prev_image"
echo "    notifier: $notifier_prev_image"

update_function() {
  function_name="$1"
  image_uri="$2"
  aws lambda update-function-code --function-name "$function_name" --image-uri "$image_uri" --region "$AWS_REGION" >/dev/null
  aws lambda wait function-updated --function-name "$function_name" --region "$AWS_REGION"
}

echo "==> updating $PORTAL_FUNCTION"
update_function "$PORTAL_FUNCTION" "$portal_image"

echo "==> updating $NOTIFIER_FUNCTION"
update_function "$NOTIFIER_FUNCTION" "$notifier_image"

echo "==> smoke test"
ci_smoke_token="$(aws ssm get-parameter --name /wellis/prod/tokens/ci-smoke --with-decryption --query Parameter.Value --output text --region "$AWS_REGION")"
mask "$ci_smoke_token"

http_status() {
  # curl's own args (e.g. -H "Authorization: ...") come after the url.
  url="$1"
  shift
  # Retries cover a cold Lambda + Neon waking up from scale-to-zero.
  curl -s -o /dev/null -w '%{http_code}' --max-time 20 --retry 3 --retry-all-errors "$url" "$@"
}

smoke_failed=0

healthz_status="$(http_status "$PORTAL_URL/healthz")"
if [ "$healthz_status" != "200" ]; then
  echo "smoke test failed: GET /healthz returned $healthz_status, wanted 200" >&2
  smoke_failed=1
fi

summary_status="$(http_status "$PORTAL_URL/api/summary" -H "Authorization: Bearer $ci_smoke_token")"
if [ "$summary_status" != "200" ]; then
  echo "smoke test failed: GET /api/summary returned $summary_status, wanted 200" >&2
  smoke_failed=1
fi

if [ "$smoke_failed" = "1" ]; then
  echo "==> smoke test failed — rolling both functions back" >&2
  update_function "$PORTAL_FUNCTION" "$portal_prev_image"
  update_function "$NOTIFIER_FUNCTION" "$notifier_prev_image"
  echo "==> rolled back to the images that were live before this deploy" >&2
  exit 1
fi

echo "==> deploy OK: $IMAGE_TAG live on both functions"
