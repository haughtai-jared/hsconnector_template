"""The ASGI application Cloud Run runs.

`uvicorn app.main:app` is the entire entrypoint. The MCP SDK builds the
streamable-HTTP application; this module puts the bearer-token gate in front of it
and supplies the transport settings that suit Cloud Run.

The gate is always closed. `MCP_AUTH_TOKEN` is empty on the first deploy, because
the token does not exist until the deployed URL has been registered with the apex
auth server. Empty is therefore a normal state, not a reason to stop checking:
while it is empty every request is answered `503`, and once it holds the issued
token every request must carry it as `Authorization: Bearer <token>`. There is no
configuration in which this service serves traffic without a token.

Cloud Run specifics worth knowing:

* **One port, from `$PORT`.** Cloud Run injects it and routes only to it.
* **TLS terminates in front of the container.** The container speaks plain HTTP
  and trusts the proxy's forwarded headers — that is the `--proxy-headers` flag
  in the Dockerfile's command.
* **Instances come and go.** The service is deployed stateless (below), so any
  request may be served by any instance and no session is held in memory.
* **The filesystem is ephemeral.** This template keeps no state, so that costs
  nothing. A tool that writes files should return them in its result.
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import os

from starlette.datastructures import Headers
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from app.server import MCP_PATH, server, status_payload

log = logging.getLogger(__name__)

# The value deployed while no token has been issued yet.
#
# The deploy scripts always write MCP_AUTH_TOKEN, so the variable is never simply
# missing from a revision: a revision that does not declare it is ambiguous, and
# `--update-env-vars` later has to guess. It starts as this placeholder instead,
# which is visible in the Cloud Run console and unmistakably "not the real token".
#
# It is never accepted as a token. It is public — it is in this file, the
# Dockerfile, and both deploy scripts — so the gate treats it exactly like an empty
# value: every request answers 503. Keep this string identical in Dockerfile,
# deploy.ps1, deploy.sh, set-token.ps1, and set-token.sh.
PLACEHOLDER_TOKEN = "replace-with-issued-token"

# The MCP token this deployment expects on every request.
#
# It is the token the apex auth server issued for this service's URL. Read once,
# at import, from the environment; a new revision re-imports, so `gcloud run
# services update --update-env-vars` (or set-token.ps1 / set-token.sh) is enough
# to rotate it without a rebuild.
#
# Empty or the placeholder means "not authorized yet", never "no auth required".
AUTH_TOKEN = (os.environ.get("MCP_AUTH_TOKEN") or "").strip()

# What the gate actually compares against. "" means "not authorized yet".
EXPECTED_TOKEN = "" if AUTH_TOKEN in ("", PLACEHOLDER_TOKEN) else AUTH_TOKEN

AUTH_HEADER = "authorization"
BEARER_SCHEME = "bearer"


def bearer_token(headers: Headers) -> str:
    """The bearer token this request carries, or "" when it carries none.

    The auth server forwards every authorized request with
    `Authorization: Bearer <token>`, so that is the one form accepted here. The
    scheme is matched case-insensitively (RFC 9110); everything after the single
    space is the token, compared verbatim — a token that begins with `mcp_` needs
    no special handling.

    A token sent with no scheme is refused rather than accepted leniently: a
    deployment that only ever receives traffic through the auth server should not
    accept a shape the auth server never sends.
    """
    value = (headers.get(AUTH_HEADER) or "").strip()
    if not value:
        return ""
    scheme, _, credential = value.partition(" ")
    if scheme.lower() != BEARER_SCHEME:
        return ""
    return credential.strip()


def token_fingerprint(token: str) -> str:
    """A short, one-way label for a token, so logs can say which one is loaded.

    Eight hex characters of SHA-256 identify a token well enough to compare the
    deployed value against the one the auth server holds, and reveal nothing that
    could be replayed.
    """
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:8]


class BearerTokenMiddleware:
    """Refuse any request that does not carry the MCP token.

    Every HTTP request is checked — the MCP endpoint, `/health`, and anything
    added later — because the auth server puts the token on all traffic it
    forwards. A request without the token did not come through the auth server,
    so it is not authorized.

    That uniformity is also what makes the approval probe meaningful: the auth
    server's `GET` succeeds only if the token it holds is the token this
    deployment expects. An exempt path would answer `200` for the wrong token.

    Three details matter:

    * **It runs first.** `app.add_middleware` makes this the outermost layer, so
      an unauthenticated request is refused before its body is read and before
      the MCP transport sees it.
    * **Comparison is `hmac.compare_digest`** over bytes, so the check does not
      leak the token one byte at a time through how long it takes to fail, and a
      non-ASCII byte in a header cannot raise.
    * **An unset token refuses rather than admits.** `503` says "deployed, not yet
      authorized", which is exactly the state between deploy and approval.

    Lifespan and websocket messages pass through untouched. That is not a bypass:
    the MCP session manager's lifespan has to reach the app or every request
    after startup fails, and it is not an HTTP request a client can send.
    """

    def __init__(self, app: ASGIApp, token: str) -> None:
        self.app = app
        self.expected = token.encode("utf-8")

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        if not self.expected:
            log.warning(
                "refused a request to %s: MCP_AUTH_TOKEN is empty, so this "
                "deployment is deployed but not yet authorized",
                scope.get("path"),
            )
            response = JSONResponse(
                {
                    "error": "not_configured",
                    "detail": (
                        "This deployment has no MCP token yet. Register its URL "
                        "with the auth server, set MCP_AUTH_TOKEN to the issued "
                        "token, then retry."
                    ),
                },
                status_code=503,
            )
            await response(scope, receive, send)
            return

        supplied = bearer_token(Headers(scope=scope))
        if supplied and hmac.compare_digest(
            supplied.encode("utf-8"), self.expected
        ):
            # A `GET` on the MCP path is the streamable transport's request to open
            # an SSE stream. This server runs stateless and answers in JSON, so
            # there is no stream to open and the request would simply be held — a
            # probe against the registered URL would hang instead of returning.
            # Answering it makes the MCP URL itself work as the approval probe.
            if scope.get("method") == "GET" and scope.get("path") == MCP_PATH:
                response = JSONResponse(status_payload())
                await response(scope, receive, send)
                return
            await self.app(scope, receive, send)
            return

        # Says nothing about whether a token was supplied, or how close it was.
        # The log line is the place for that, not the response.
        log.warning(
            "rejected a request to %s with %s",
            scope.get("path"),
            "no bearer token" if not supplied else "the wrong bearer token",
        )
        response = JSONResponse(
            {
                "error": "unauthorized",
                "detail": "Send the MCP token as `Authorization: Bearer <token>`.",
            },
            status_code=401,
            headers={"WWW-Authenticate": 'Bearer realm="mcp"'},
        )
        await response(scope, receive, send)


def build_app():
    """Wrap the MCP server in the ASGI application uvicorn serves.

    `stateless_http=True` is the right mode for Cloud Run: an instance may be
    created or destroyed between any two requests, so there is no session for the
    transport to keep open and every request is complete on its own.

    `json_response=True` makes a single request return a plain JSON response
    instead of an SSE stream. It is simpler to debug with curl, and the
    specification allows either. A client that insists on SSE would need this
    switched off.

    `host="0.0.0.0"` is the address the container binds. It also stops the SDK
    from auto-enabling its localhost-only DNS-rebinding allow-list, which would
    reject requests arriving with `Host: <service>.run.app`. Cloud Run's service
    URL is assigned at deploy time, so there is no fixed host to allow-list here.
    """
    app = server.streamable_http_app(
        streamable_http_path=MCP_PATH,
        json_response=True,
        stateless_http=True,
        host="0.0.0.0",
    )

    app.add_middleware(BearerTokenMiddleware, token=EXPECTED_TOKEN)

    if EXPECTED_TOKEN:
        log.info(
            "MCP token ON (sha256 %s): every request must send "
            "`Authorization: ******",
            token_fingerprint(EXPECTED_TOKEN),
        )
    elif AUTH_TOKEN == PLACEHOLDER_TOKEN:
        log.warning(
            "MCP_AUTH_TOKEN is still the deploy placeholder (%r), so every "
            "request answers 503 until the token issued by the auth server is "
            "set. That is the normal state right after a deploy; run "
            "set-token.ps1 / set-token.sh to finish.",
            PLACEHOLDER_TOKEN,
        )
    else:
        log.warning(
            "MCP_AUTH_TOKEN is empty, so every request answers 503 until the "
            "token issued by the auth server is set. Deploying in this state "
            "is expected (the token does not exist yet); serving in it is not.",
        )

    return app


# uvicorn's target, built at import — which is what `uvicorn app.main:app` expects.
app = build_app()
