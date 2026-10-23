"""The MCP server: one tool, its description, and a health route.

This module is the whole MCP surface. It has no HTTP code of its own — `app.main`
turns the `server` object into an ASGI application — so the tool can be imported
and reasoned about on its own.

To add another tool, write another function below with `@server.tool(...)`.
"""

from __future__ import annotations

from datetime import datetime, timezone

from mcp.server.mcpserver import MCPServer
from mcp.types import ToolAnnotations
from starlette.requests import Request
from starlette.responses import JSONResponse

SERVER_NAME = "hsconnector-template"
SERVER_VERSION = "0.1.0"

# The paths a client uses. `/mcp` is this server's endpoint; `/health` is for a
# probe or a human with curl. `/healthz` is deliberately not used: Google's front
# end answers that path on a *.run.app host before a request reaches the container.
MCP_PATH = "/mcp"
HEALTH_PATH = "/health"

# Instructions are what a connecting model is told about this server at
# `initialize`. Keep them short, and say what the tools are for.
INSTRUCTIONS = (
    "This server exposes one tool: get_current_time(). "
    "Call it whenever the user asks for the current date or time. "
    "It takes no arguments and returns the server's current time in UTC "
    "as an ISO 8601 string."
)

server = MCPServer(
    name=SERVER_NAME,
    title="HS Connector Template",
    version=SERVER_VERSION,
    instructions=INSTRUCTIONS,
)


@server.tool(
    name="get_current_time",
    title="Get the current time",
    description=(
        "Return the current date and time in UTC as an ISO 8601 string, "
        "for example '2026-01-31T14:05:00+00:00'. Takes no arguments."
    ),
    annotations=ToolAnnotations(
        read_only_hint=True,     # it reads the clock; it changes nothing
        destructive_hint=False,  # it cannot overwrite or delete anything
        idempotent_hint=False,   # a second call returns a different time
        open_world_hint=False,   # it uses only this process's clock
    ),
)
def get_current_time() -> str:
    """Return the current UTC time as an ISO 8601 string."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


@server.custom_route(HEALTH_PATH, methods=["GET"], include_in_schema=False)
async def health(_request: Request) -> JSONResponse:
    """Liveness check for Cloud Run, a load balancer, or a quick curl."""
    return JSONResponse(
        {
            "status": "ok",
            "service": SERVER_NAME,
            "version": SERVER_VERSION,
            "mcp_endpoint": MCP_PATH,
        }
    )
