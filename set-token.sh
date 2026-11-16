#!/usr/bin/env bash
#
# Set the MCP token that the apex auth server issued for a deployed service.
#
#   MCP_AUTH_TOKEN=<token> bash set-token.sh <project-id> [service-name] [region]
#
# Step 3 of the flow. The service was deployed with no token (deploy.sh), so it
# answers 503 to everything; its URL was registered with the auth server, which
# issued the token. This writes that token into MCP_AUTH_TOKEN, releases a new
# revision, and then checks the result the same way the auth server will:
#
#   * GET /health WITH the token must return 200.
#   * GET /health WITHOUT it must return 401, which proves the gate is on.
#
# Nothing is sent to the auth server from here. Step 4 is the auth server's own
# GET: a 200 approves the deployment, and a 401 means it holds a different token
# than the one set here.
set -euo pipefail

PROJECT_ID="${1:-${PROJECT_ID:-}}"
SERVICE="${2:-${SERVICE:-hsconnector-template}}"
REGION="${3:-${REGION:-us-central1}}"
TOKEN="${MCP_AUTH_TOKEN:-}"

if [ -z "$PROJECT_ID" ] || [ -z "$TOKEN" ]; then
  echo "usage: MCP_AUTH_TOKEN=<token> bash set-token.sh <project-id> [service-name] [region]" >&2
  exit 1
fi

# The value deploy.sh writes when it has no token. It is public, so writing it
# here would deploy a revision that still refuses everything; that is a mistake
# worth naming rather than a value worth sending.
if [ "$TOKEN" = "replace-with-issued-token" ]; then
  echo "That is the deploy placeholder, not the issued token. Pass the token the auth server issued for this URL." >&2
  exit 1
fi

# --update-env-vars parses a comma-separated KEY=VALUE list. A token containing a
# comma or whitespace cannot survive that; better to refuse than to deploy a token
# that silently differs from the one the auth server holds.
case "$TOKEN" in
  *,*|*[[:space:]]*)
    echo "The token contains a comma or whitespace; gcloud cannot carry that in --update-env-vars." >&2
    exit 1
    ;;
esac

# --update-env-vars keeps every other variable on the service and replaces only
# MCP_AUTH_TOKEN, so rotating the token does not touch anything else.
gcloud run services update "$SERVICE" \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --update-env-vars "MCP_AUTH_TOKEN=$TOKEN" \
  --quiet

URL="$(gcloud run services describe "$SERVICE" \
  --project "$PROJECT_ID" --region "$REGION" --format 'value(status.url)')"

echo
echo "Service: $URL"

# Header-only status check; nothing is written to stdout but the code.
check() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "$@" || true
}

# A new revision takes a few seconds to serve, and until then Cloud Run keeps
# routing to the previous one — which has no token and answers 503. Retry briefly
# instead of reporting a failure that only means "not rolled out yet".
AUTHORIZED=""
for attempt in $(seq 1 12); do
  AUTHORIZED="$(check -H "Authorization: Bearer $TOKEN" "$URL/health")"
  [ "$AUTHORIZED" = "200" ] && break
  [ "$attempt" -lt 12 ] && sleep 5
done

ANONYMOUS="$(check "$URL/health")"

echo "GET /health with the token:    ${AUTHORIZED:-no response}"
echo "GET /health without the token: ${ANONYMOUS:-no response}"

if [ "$AUTHORIZED" != "200" ]; then
  echo "GET /health with the token did not return 200. The revision may not be serving yet;" >&2
  echo "check: gcloud run services logs read $SERVICE --region $REGION --limit 20" >&2
  exit 1
fi
echo "This deployment accepts the token."

if [ "$ANONYMOUS" != "401" ]; then
  echo "warning: a request with no token returned ${ANONYMOUS:-nothing} instead of 401." >&2
  echo "Expected 401 once a token is set; check which revision is serving." >&2
fi

echo
echo "Next:"
echo "  Have the auth server GET $URL/health with this token."
echo "  A 200 approves the server. A 401 means the auth server holds a"
echo "  different token — re-run this script with the token it issued."
