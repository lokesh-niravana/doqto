#!/usr/bin/env bash
# One-time: let the backend delete Firebase sign-in identities when an
# account is deleted (doqto_backend/app/services/firebase_identity.py).
#
#   scripts/grant_firebase_auth_admin.sh [service-account.json]
#
# Grants "Firebase Authentication Admin" (roles/firebaseauth.admin) on the
# Firebase project to the service account the backend already uses for push
# (FCM_SERVICE_ACCOUNT_JSON). Needs gcloud signed in as a project owner.
# Without this role the delete call is refused and logged; account deletion
# itself still completes.
set -euo pipefail

KEY="${1:-$HOME/.doqto/fcm-service-account.json}"
PROJECT="${FIREBASE_PROJECT:-doqto-90684}"
[[ -f "$KEY" ]] || { echo "No service-account file at $KEY" >&2; exit 1; }

EMAIL="$(jq -r .client_email "$KEY")"
echo "Granting roles/firebaseauth.admin on $PROJECT to $EMAIL"
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:$EMAIL" \
  --role roles/firebaseauth.admin \
  --condition None >/dev/null
echo "Done."
