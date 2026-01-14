"""Configuration settings for Tempest MCP Server."""

import os


class Settings:
    """Application settings from environment variables."""

    # Server settings
    host: str = os.getenv("HOST", "0.0.0.0")
    port: int = int(os.getenv("PORT", "8000"))
    debug: bool = os.getenv("DEBUG", "false").lower() == "true"

    # WeatherFlow API settings
    api_token: str = os.getenv("WEATHERFLOW_API_TOKEN", "")

    # Cache settings
    cache_ttl: int = int(os.getenv("WEATHERFLOW_CACHE_TTL", "300"))  # 5 minutes
    cache_size: int = int(os.getenv("WEATHERFLOW_CACHE_SIZE", "100"))


settings = Settings()
