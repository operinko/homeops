"""FastAPI application entry point for Tempest MCP Server."""

import logging
import json
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request

from . import __version__
from .config import settings
from .mcp_server import mcp

# Configure logging
logging.basicConfig(
    level=logging.DEBUG if settings.debug else logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

# Configure MCP server path
mcp.settings.streamable_http_path = "/mcp"


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager."""
    logger.info(f"Starting Tempest MCP Server v{__version__}...")
    # Start MCP session manager
    async with mcp.session_manager.run():
        logger.info("MCP server initialized")
        yield
    logger.info("Shutting down Tempest MCP Server...")


app = FastAPI(
    title="Tempest MCP Server",
    description="MCP Server for WeatherFlow Tempest weather data",
    version=__version__,
    lifespan=lifespan,
)


@app.middleware("http")
async def validation_fix_middleware(request: Request, call_next):
    """
    Middleware to fix n8n MCP client requests that fail Pydantic validation.

    n8n sends `clientInfo` without the required `version` field.
    This middleware intercepts `initialize` requests and injects a default version.
    """
    if request.method == "POST" and request.url.path.rstrip("/") == "/mcp":
        try:
            # Read body
            body_bytes = await request.body()
            if body_bytes:
                data = json.loads(body_bytes)

                # Check for initialize request missing clientInfo.version
                if (
                    isinstance(data, dict)
                    and data.get("method") == "initialize"
                    and "params" in data
                    and "clientInfo" in data["params"]
                    and "version" not in data["params"]["clientInfo"]
                ):
                    logger.warning("Patching missing clientInfo.version for n8n compatibility")
                    data["params"]["clientInfo"]["version"] = "1.0.0"

                    # Re-serialize body
                    new_body = json.dumps(data).encode("utf-8")

                    # Replace request body by overriding receive
                    async def new_receive():
                        return {"type": "http.request", "body": new_body, "more_body": False}
                    request._receive = new_receive

        except Exception as e:
            logger.warning(f"Failed to process request in validation fix middleware: {e}")
            # Continue with original request if parsing fails
            pass

    response = await call_next(request)
    return response


@app.get("/healthz")
async def health_check() -> dict:
    """Health check endpoint."""
    return {
        "status": "ok",
        "version": __version__,
    }


@app.get("/")
async def root() -> dict:
    """Root endpoint with server info."""
    return {
        "name": "Tempest MCP Server",
        "version": __version__,
        "mcp_endpoint": "/mcp",
        "health_endpoint": "/healthz",
    }


# Mount MCP server at root (it handles /mcp path internally)
# MUST be mounted after other routes to avoid capturing them (since root matching catches everything)
app.mount("/", mcp.streamable_http_app())


def main() -> None:
    """Run the application."""
    import uvicorn

    uvicorn.run(
        "tempest_mcp.main:app",
        host=settings.host,
        port=settings.port,
        reload=settings.debug,
    )


if __name__ == "__main__":
    main()
