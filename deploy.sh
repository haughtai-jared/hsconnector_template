#!/usr/bin/env bash
#
# Deploy this MCP server to Google Cloud Run.
#
#   bash deploy.sh <project-id> [service-name] [region]
#
# The image is built in the cloud by `gcloud run deploy --source .`, so Docker
# does not need to be installed locally.
set -euo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-}}"
SERVICE="${2:-${SERVICE:-hsconnector-template}}"
REGION="${3:-${REGION:-us-central1}}"

if [ -z "$PROJECT_ID" ]; then
  echo "usage: bash deploy.sh <project-id> [service-name] [region]" >&2
  exit 1
fi

# --allow-unauthenticated is required for an MCP server: an MCP client cannot
# present a Google identity token, so Cloud Run IAM would leave the service
# unreachable. This does NOT mean the URL is private — see the security note in
# README.md, and add your own auth (for example a shared header) before putting
# anything sensitive behind it.
gcloud run deploy "$SERVICE" \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --source . \
  --allow-unauthenticated \
  --port 8080 \
  --memory 512Mi \
  --cpu 1 \
  --timeout 300 \
  --min-instances 0 \
  --max-instances 10 \
  --quiet
