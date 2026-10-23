"""The ASGI application Cloud Run runs.

`uvicorn app.main:app` is the entire entrypoint. The MCP SDK builds the
streamable-HTTP application; this module adds the shared-key check in front of it
and supplies the transport settings that suit Cloud Run.

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

import hmac
import logging
import os

from starlette.datastructures import Headers
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from app.server import HEALTH_PATH, MCP_PATH, server

log = logging.getLogger(__name__)

# The shared key every request must carry.
#
# Read once, at import, from the environment. Unset or empty means the check is
# OFF, which is what lets a fresh clone run locally with no configuration. Set it
# on the deployed service (see deploy.ps1 / deploy.sh, or `gcloud run services
# update --update-env-vars`).
AUTH_TOKEN = (os.environ.get("MCP_AUTH_TOKEN") or "").strip()

# Paths that never require the key. A Cloud Run health probe comes from the
# platform rather than from the connector, so it carries no credentials.
AUTH_EXEMPT_PATHS = frozenset({HEALTH_PATH})

AUTH_HEADER = "authorization"


def supplied_token(headers: Headers) -> str:
    """The key this request carries, or "" when it carries none.

    `Authorization: Bearer mcp_abc123` is the form an MCP connector uses. The
    scheme is matched case-insensitively and stripped; everything after it is the
    key, exactly as issued — so a token that begins with `mcp_` needs no special
    handling and is compared verbatim.

    A bare token with no scheme is also accepted, because some clients send one,
    and rejecting it would look like a wrong key rather than a missing scheme.
    """
    value = (headers.get(AUTH_HEADER) or "").strip()
    if not value:
        return ""
    scheme, _, credential = value.partition(" ")
    if scheme.lower() == "bearer":
        return credential.strip()
    return value


class SharedKeyMiddleware:
    """Reject any request that does not carry the shared key.

    This is one shared secret, not a user directory: it answers "did this request
    come through the connector that holds the key", and nothing more. That is the
    right amount of machinery for a template, and it stops a leaked service URL
    from being usable on its own.

    Two details matter:

    * **It runs first.** `app.add_middleware` makes this the outermost layer, so
      an unauthenticated request is refused before its body is read and before
      the MCP transport sees it.
    * **Comparison is `hmac.compare_digest`**, so the check does not leak the key
      one byte at a time through how long it takes to fail.

    Lifespan and websocket messages pass through untouched. That is not a bypass:
    the MCP session manager's lifespan has to reach the app or every request
    after startup fails, and it is not an HTTP request a client can send.
    """

    def __init__(self, app: ASGIApp, token: str,
                 exempt_paths: frozenset[str] = frozenset()) -> None:
        self.app = app
        self.token = token
        self.exempt_paths = exempt_paths

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope.get("path") in self.exempt_paths:
            await self.app(scope, receive, send)
            return

        supplied = supplied_token(Headers(scope=scope))
        if supplied and hmac.compare_digest(supplied, self.token):
            await self.app(scope, receive, send)
            return

        # Says nothing about whether a key was supplied, or how close it was. The
        # log line is the place for that, not the response.
        log.warning("rejected a request to %s with %s", scope.get("path"),
                    "no key" if not supplied else "the wrong key")
        response = JSONResponse(
            {"error": "unauthorized",
             "detail": "Send the shared key as `Authorization: Bearer <key>`."},
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

    if AUTH_TOKEN:
        app.add_middleware(
            SharedKeyMiddleware,
            token=AUTH_TOKEN,
            exempt_paths=AUTH_EXEMPT_PATHS,
        )
        log.info(
            "shared-key check ON: every request except %s must send "
            "`Authorization: Bearer <key>`", ", ".join(sorted(AUTH_EXEMPT_PATHS)),
        )
    else:
        log.warning(
            "MCP_AUTH_TOKEN is unset, so the check is OFF and %s accepts anything "
            "that can reach it. That is fine for a local run; set MCP_AUTH_TOKEN "
            "before deploying anything that matters.", MCP_PATH,
        )

    return app


# uvicorn's target, built at import — which is what `uvicorn app.main:app` expects.
app = build_app()
