#!/usr/bin/env bash
# Deploy everything from the App Store / HIG audit (APP_STORE_AUDIT_REPORT.md):
#
#   1. backend (applies migration 0036_user_suspension on container start)
#   2. website
#   3. one-time Firebase Authentication Admin grant (skip with SKIP_FIREBASE_GRANT=1)
#
# The iOS build is separate: scripts/ios_release.sh <build_number> (bump,
# archive, upload). It is not run here because each upload needs a new
# build number and a decision about attaching it to the review.
#
# Backend first: the app and website changes do not depend on it, but the
# Help-link fix for already-installed builds is served by the backend.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

"$DIR/deploy_backend.sh" 0036_user_suspension
"$DIR/deploy_landing.sh"
if [[ "${SKIP_FIREBASE_GRANT:-0}" != "1" ]]; then
  "$DIR/grant_firebase_auth_admin.sh"
fi

echo
echo "Still manual:"
echo "  - App Store Connect privacy answers: add Emails or Text Messages, Device ID,"
echo "    Product Interaction, Other Data Types (linked, app functionality, no tracking)."
echo "  - CloudWatch alarm on the log line 'report_filed' in /ecs/doqto-backend."
echo "  - iOS build: scripts/ios_release.sh <next build number>."
