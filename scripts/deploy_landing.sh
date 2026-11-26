#!/usr/bin/env bash
# Deploy the doqto.ai website (privacy, terms, BAA, support, invite pages).
#
#   scripts/deploy_landing.sh
#
# Type-checks, builds the static export, syncs it to the site bucket and
# invalidates CloudFront, then checks the pages the app links to. Bucket and
# distribution come from the landing terraform state (no terraform apply:
# use infra/landing/deploy.sh when the infrastructure changes).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LANDING="$ROOT/landing"
TF="$ROOT/infra/landing"

BACKUP="$HOME/.aws/backup-20260930-160135"
if [[ -z "${AWS_CONFIG_FILE:-}" && -f "$BACKUP/config" ]]; then
  export AWS_CONFIG_FILE="$BACKUP/config"
  export AWS_SHARED_CREDENTIALS_FILE="$BACKUP/credentials"
fi
PROFILE="${AWS_PROFILE_NAME:-loki-doqto}"
SITE="${SITE_URL:-https://doqto.ai}"

BUCKET="$(cd "$TF" && terraform output -raw bucket)"
DIST="$(cd "$TF" && terraform output -raw distribution_id)"

echo "==> Type-check and build"
(cd "$LANDING" && npm ci >/dev/null && npx tsc --noEmit && npm run build)

echo "==> Upload to s3://$BUCKET"
aws s3 sync "$LANDING/out" "s3://$BUCKET" --delete --profile "$PROFILE"

echo "==> Invalidate $DIST"
INV="$(aws cloudfront create-invalidation --distribution-id "$DIST" --paths "/*" \
  --profile "$PROFILE" --query 'Invalidation.Id' --output text)"
aws cloudfront wait invalidation-completed --distribution-id "$DIST" --id "$INV" --profile "$PROFILE"

echo "==> Pages the app links to"
FAIL=0
for path in /privacy /terms /hipaa /baa /support /delete-account /get; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$SITE$path")"
  echo "    $path -> $code"
  [[ "$code" == "200" ]] || FAIL=1
done
if curl -s "$SITE/privacy" | grep -qi "end-to-end encryption — we cannot access"; then
  echo "    /privacy still shows the old end-to-end claim (cache?)" >&2
  FAIL=1
fi
[[ "$FAIL" == "0" ]] || { echo "Some checks failed." >&2; exit 1; }

echo "Deployed $SITE."
