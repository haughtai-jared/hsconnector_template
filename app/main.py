"""The ASGI application Cloud Run runs.

`uvicorn app.main:app` is the entire entrypoint. The MCP SDK builds the
streamable-HTTP application; this module only supplies the transport settings
that suit Cloud Run.

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

from app.server import MCP_PATH, server


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
    return server.streamable_http_app(
        streamable_http_path=MCP_PATH,
        json_response=True,
        stateless_http=True,
        host="0.0.0.0",
    )


# uvicorn's target, built at import — which is what `uvicorn app.main:app` expects.
app = build_app()
