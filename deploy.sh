#!/usr/bin/env bash
#
# Deploy this MCP server to Google Cloud Run with a placeholder MCP token.
#
#   bash deploy.sh <project-id> [service-name] [region]
#
# MCP_AUTH_TOKEN is always populated on the result. There is no token to deploy
# yet, so a first deploy writes the placeholder value "replace-with-issued-token"
# rather than nothing at all: a revision that omits the variable makes its state
# ambiguous, and the later --update-env-vars step would have to guess whether a
# missing value means "never deployed" or "cleared". The placeholder is neither a
# credential nor an opening: app/main.py treats it exactly like empty and answers
# 503 to every request. A service that already carries a real token keeps it.
#
# That is step 1 of the flow:
#
#   1. deploy    this script, with the placeholder token.
#   2. register  the deployed /mcp URL with the apex auth server, which issues the
#                MCP token for it.
#   3. set it    MCP_AUTH_TOKEN=<token> bash set-token.sh <project-id>
#   4. approve   have the auth server GET <url>/health carrying that token.
#                A 200 approves the server.
#
# The image is built in the cloud by `gcloud run deploy --source .`, so Docker
# does not need to be installed locally.
set -euo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-}}"
SERVICE="${2:-${SERVICE:-hsconnector-template}}"
REGION="${3:-${REGION:-us-central1}}"

# Must match PLACEHOLDER_TOKEN in app/main.py and the ENV default in the
# Dockerfile. The app refuses to authorize it, so it is safe in plain sight.
PLACEHOLDER_TOKEN="replace-with-issued-token"

if [ -z "$PROJECT_ID" ]; then
  echo "usage: bash deploy.sh <project-id> [service-name] [region]" >&2
  exit 1
fi

# --allow-unauthenticated is required for an MCP server: an MCP client cannot
# present a Google identity token, so Cloud Run IAM would leave the service
# unreachable. This does NOT make the endpoint usable — every request still has to
# carry the MCP token set in step 3, which is the only thing standing in front of
# /mcp. See the security note in README.md.
ARGS=(
  --project "$PROJECT_ID"
  --region "$REGION"
  --source .
  --allow-unauthenticated
  --port 8080
  --memory 512Mi
  --cpu 1
  --timeout 300
  --min-instances 0
  --max-instances 10
  --quiet
)

# Read the service that is already there, if any. A failed describe means "no such
# service yet", which is the normal first run and not an error here.
existing_env="$(gcloud run services describe "$SERVICE" \
  --project "$PROJECT_ID" --region "$REGION" \
  --format 'value(spec.template.spec.containers[0].env)' 2>/dev/null || true)"

if printf '%s' "$existing_env" | grep -q "MCP_AUTH_TOKEN"; then
  echo "MCP_AUTH_TOKEN: already on the service; leaving it untouched."
else
  # Nothing to preserve, so declare it now. --update-env-vars merges rather than
  # replaces, so any other variable on the service is left alone.
  ARGS+=(--update-env-vars "MCP_AUTH_TOKEN=$PLACEHOLDER_TOKEN")
  echo "MCP_AUTH_TOKEN: deploying with the placeholder value."
fi

gcloud run deploy "$SERVICE" "${ARGS[@]}"

URL="$(gcloud run services describe "$SERVICE" \
  --project "$PROJECT_ID" --region "$REGION" --format 'value(status.url)')"

# Read what actually landed on the new revision instead of assuming the flags
# took effect.
ENV_VARS="$(gcloud run services describe "$SERVICE" \
  --project "$PROJECT_ID" --region "$REGION" \
  --format 'value(spec.template.spec.containers[0].env)' 2>/dev/null || true)"

if ! printf '%s' "$ENV_VARS" | grep -q "MCP_AUTH_TOKEN"; then
  echo "The revision that was just deployed does not declare MCP_AUTH_TOKEN." >&2
  echo "Set it with: MCP_AUTH_TOKEN=<token> bash set-token.sh $PROJECT_ID $SERVICE $REGION" >&2
  exit 1
fi

echo
echo "Deployed: $URL/mcp"
echo "Health:   $URL/health"

if printf '%s' "$ENV_VARS" | grep -qF "$PLACEHOLDER_TOKEN"; then
  echo "Token:    placeholder - every request answers 503 until step 2 below."
  echo
  echo "Next:"
  echo "  1. Register $URL/mcp with the auth server; it issues the MCP token."
  echo "  2. MCP_AUTH_TOKEN=<token> bash set-token.sh $PROJECT_ID $SERVICE $REGION"
  echo "  3. Have the auth server GET $URL/health with that token."
  echo "     A 200 approves this server; a 401 means it holds a different token."
else
  echo "Token:    already set on this revision - authorized traffic works."
  echo
  echo "Next:"
  echo "  1. Register $URL/mcp with the auth server; it issues the MCP token."
  echo "  2. Have the auth server GET $URL/health with that token."
  echo "     A 200 approves this server; a 401 means it holds a different token."
fi