"""Loki client for querying logs."""

import logging
from datetime import datetime, timedelta
from typing import Any
from urllib.parse import urlencode

import httpx

from ..config import settings

logger = logging.getLogger(__name__)


class LokiClient:
    """Client for querying Loki logs."""

    def __init__(self, base_url: str | None = None) -> None:
        self.base_url = base_url or settings.loki_url
        self._client: httpx.AsyncClient | None = None

    async def _get_client(self) -> httpx.AsyncClient:
        if self._client is None:
            self._client = httpx.AsyncClient(base_url=self.base_url, timeout=30.0)
        return self._client

    async def close(self) -> None:
        if self._client:
            await self._client.aclose()
            self._client = None

    async def health_check(self) -> bool:
        """Check if Loki is reachable."""
        try:
            client = await self._get_client()
            response = await client.get("/ready")
            return response.status_code == 200
        except Exception as e:
            logger.error(f"Loki health check failed: {e}")
            return False

    async def query_logs(
        self,
        namespace: str,
        pod: str | None = None,
        container: str | None = None,
        start_time: datetime | None = None,
        end_time: datetime | None = None,
        limit: int = 1000,
    ) -> str:
        """Query logs from Loki for a specific pod."""
        # Build LogQL query
        labels = [f'namespace="{namespace}"']
        if pod:
            labels.append(f'pod=~"{pod}.*"')
        if container:
            labels.append(f'container="{container}"')

        query = "{" + ",".join(labels) + "}"
        
        # Time range defaults
        if end_time is None:
            end_time = datetime.now()
        if start_time is None:
            start_time = end_time - timedelta(minutes=settings.loki_log_window_minutes)

        params = {
            "query": query,
            "start": int(start_time.timestamp() * 1e9),  # nanoseconds
            "end": int(end_time.timestamp() * 1e9),
            "limit": limit,
            "direction": "backward",
        }

        try:
            client = await self._get_client()
            response = await client.get(
                f"/loki/api/v1/query_range?{urlencode(params)}"
            )
            response.raise_for_status()
            data = response.json()
            return self._format_logs(data)
        except Exception as e:
            logger.error(f"Failed to query Loki: {e}")
            return f"Error querying logs: {e}"

    async def query_previous_logs(
        self,
        namespace: str,
        pod: str,
        container: str | None = None,
        lines: int | None = None,
    ) -> str:
        """Query previous container logs (for crash loops)."""
        # For previous logs, we query a longer time window and limit lines
        lines = lines or settings.loki_previous_logs_lines
        end_time = datetime.now()
        start_time = end_time - timedelta(hours=6)  # Look back 6 hours for previous runs
        
        return await self.query_logs(
            namespace=namespace,
            pod=pod,
            container=container,
            start_time=start_time,
            end_time=end_time,
            limit=lines,
        )

    def _format_logs(self, data: dict[str, Any]) -> str:
        """Format Loki response into readable log lines."""
        result = data.get("data", {}).get("result", [])
        if not result:
            return "No logs found"

        lines: list[str] = []
        for stream in result:
            stream_labels = stream.get("stream", {})
            pod = stream_labels.get("pod", "unknown")
            container = stream_labels.get("container", "unknown")
            
            for ts, line in stream.get("values", []):
                # Convert nanosecond timestamp to datetime
                timestamp = datetime.fromtimestamp(int(ts) / 1e9)
                formatted_ts = timestamp.strftime("%Y-%m-%d %H:%M:%S")
                lines.append(f"[{formatted_ts}] [{pod}/{container}] {line}")

        # Sort by timestamp and return
        lines.sort()
        return "\n".join(lines)

