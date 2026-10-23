#!/usr/bin/env bash
#
# Deploy this MCP server to Google Cloud Run.
#
#   MCP_AUTH_TOKEN=mcp_your_key bash deploy.sh <project-id> [service-name] [region]
#
# The shared key is read from the environment rather than from an argument so it
# does not end up in your shell history. Leave it unset and the service is
# deployed with the check OFF: anyone with the URL can call it.
#
# The image is built in the cloud by `gcloud run deploy --source .`, so Docker
# does not need to be installed locally.
set -euo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-}}"
SERVICE="${2:-${SERVICE:-hsconnector-template}}"
REGION="${3:-${REGION:-us-central1}}"
AUTH_TOKEN="${MCP_AUTH_TOKEN:-}"

if [ -z "$PROJECT_ID" ]; then
  echo "usage: [MCP_AUTH_TOKEN=<key>] bash deploy.sh <project-id> [service-name] [region]" >&2
  exit 1
fi

# --allow-unauthenticated is required for an MCP server: an MCP client cannot
# present a Google identity token, so Cloud Run IAM would leave the service
# unreachable. This does NOT make the endpoint private — the service checks its
# own shared key instead (MCP_AUTH_TOKEN), which is the only thing standing in
# front of /mcp. See the security note in README.md.
#
# The key is written as a plain environment variable so it is visible in the
# Cloud Run console. A value that must stay unreadable belongs in Secret Manager
# and is mounted with --set-secrets instead.
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

if [ -n "$AUTH_TOKEN" ]; then
  ARGS+=(--set-env-vars "MCP_AUTH_TOKEN=$AUTH_TOKEN")
fi

gcloud run deploy "$SERVICE" "${ARGS[@]}"

URL="$(gcloud run services describe "$SERVICE" \
  --project "$PROJECT_ID" --region "$REGION" --format 'value(status.url)')"

echo
echo "Deployed: $URL/mcp"
echo "Health:   $URL/health"
if [ -n "$AUTH_TOKEN" ]; then
  echo "Auth:     ON — clients must send 'Authorization: Bearer <key>'"
else
  echo "Auth:     OFF — anyone with the URL can call this service"
fi
