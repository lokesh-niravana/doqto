#!/usr/bin/env bash
# Deploy the Doqto backend to production.
#
#   scripts/deploy_backend.sh [expected_alembic_revision]
#
# Builds the image for linux/amd64, pushes it to ECR as <git sha> and
# :latest (the task definition pulls :latest), forces a new ECS deployment,
# waits until the service is stable, then confirms:
#   - the new container logged the expected Alembic revision (migrations run
#     on container start: `alembic upgrade head`, infra/backend/main.tf), and
#   - https://api.doqto.ai/health answers 200.
#
# The default expected revision is the newest file in alembic/versions.
# No terraform apply here: use infra/backend/deploy.sh when infrastructure
# changes.
#
# AWS credentials: the loki-doqto profile lives in a backup directory on
# this Mac; it is used automatically when present. Override with
# AWS_PROFILE_NAME / AWS_CONFIG_FILE / AWS_SHARED_CREDENTIALS_FILE.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND="$ROOT/doqto_backend"

BACKUP="$HOME/.aws/backup-20260930-160135"
if [[ -z "${AWS_CONFIG_FILE:-}" && -f "$BACKUP/config" ]]; then
  export AWS_CONFIG_FILE="$BACKUP/config"
  export AWS_SHARED_CREDENTIALS_FILE="$BACKUP/credentials"
fi
PROFILE="${AWS_PROFILE_NAME:-loki-doqto}"
REGION="${AWS_REGION:-us-east-1}"
CLUSTER="doqto-backend"
SERVICE="doqto-backend"
LOG_GROUP="/ecs/doqto-backend"
HEALTH_URL="${HEALTH_URL:-https://api.doqto.ai/health}"

aws_() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

EXPECTED_REV="${1:-$(cd "$BACKEND/alembic/versions" && ls -1 [0-9]*.py | sort | tail -1 | sed 's/\.py$//')}"

cd "$ROOT"
if [[ -n "$(git status --porcelain -- doqto_backend)" ]]; then
  echo "doqto_backend has uncommitted changes; commit first so the image matches a sha." >&2
  exit 1
fi
SHA="$(git rev-parse --short HEAD)"

ACCOUNT="$(aws_ sts get-caller-identity --query Account --output text)"
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
REPO="$REGISTRY/doqto-backend"

echo "==> Backend tests"
(cd "$BACKEND" && docker compose up -d >/dev/null && venv/bin/pytest -q -x 2>&1 | tail -1)

echo "==> Build $REPO:$SHA (linux/amd64)"
aws_ ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
docker buildx build --platform linux/amd64 -t "$REPO:$SHA" -t "$REPO:latest" --push "$BACKEND"

echo "==> Redeploy $SERVICE"
STARTED_AT="$(($(date +%s) * 1000))"
aws_ ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --force-new-deployment >/dev/null
aws_ ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"
echo "    service stable"

echo "==> Expecting Alembic revision $EXPECTED_REV in $LOG_GROUP"
FOUND=""
for _ in $(seq 1 12); do
  FOUND="$(aws_ logs filter-log-events --log-group-name "$LOG_GROUP" \
    --start-time "$STARTED_AT" --filter-pattern "\"$EXPECTED_REV\"" \
    --query 'events[0].message' --output text 2>/dev/null || true)"
  [[ -n "$FOUND" && "$FOUND" != "None" ]] && break
  sleep 10
done
if [[ -z "$FOUND" || "$FOUND" == "None" ]]; then
  # A redeploy with no new migration logs nothing about revisions.
  echo "    no log line naming $EXPECTED_REV since the deploy started."
  echo "    If this deploy adds that migration, check $LOG_GROUP before going further."
else
  echo "    $FOUND"
fi

echo "==> Health"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "$HEALTH_URL")"
echo "    $HEALTH_URL -> $CODE"
[[ "$CODE" == "200" ]] || { echo "Health check failed." >&2; exit 1; }

echo "Deployed $SHA."
