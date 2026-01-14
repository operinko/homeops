"""FastAPI application entry point for Tempest MCP Server."""

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI

from . import __version__
from .config import settings
from .mcp_server import mcp

# Configure logging
logging.basicConfig(
    level=logging.DEBUG if settings.debug else logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

# Configure MCP server path to be at root of mount point
mcp.settings.streamable_http_path = "/"


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
    redirect_slashes=False,  # Prevent /mcp -> /mcp/ redirect
)

# Mount MCP server at /mcp
app.mount("/mcp", mcp.streamable_http_app())


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
