"""Prometheus client for querying metrics."""

import logging
from datetime import datetime, timedelta
from typing import Any
from urllib.parse import urlencode

import httpx

from ..config import settings

logger = logging.getLogger(__name__)


class PrometheusClient:
    """Client for querying Prometheus metrics."""

    def __init__(self, base_url: str | None = None) -> None:
        self.base_url = base_url or settings.prometheus_url
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
        """Check if Prometheus is reachable."""
        try:
            client = await self._get_client()
            response = await client.get("/-/ready")
            return response.status_code == 200
        except Exception as e:
            logger.error(f"Prometheus health check failed: {e}")
            return False

    async def query_pod_metrics(
        self,
        namespace: str,
        pod: str,
        start_time: datetime | None = None,
        end_time: datetime | None = None,
    ) -> dict[str, Any]:
        """Query CPU and memory metrics for a pod."""
        if end_time is None:
            end_time = datetime.now()
        if start_time is None:
            start_time = end_time - timedelta(minutes=settings.loki_log_window_minutes)

        metrics: dict[str, Any] = {
            "cpu": await self._query_cpu(namespace, pod, start_time, end_time),
            "memory": await self._query_memory(namespace, pod, start_time, end_time),
        }
        return metrics

    async def _query_cpu(
        self,
        namespace: str,
        pod: str,
        start_time: datetime,
        end_time: datetime,
    ) -> list[dict[str, Any]]:
        """Query CPU usage for a pod."""
        query = f'rate(container_cpu_usage_seconds_total{{namespace="{namespace}",pod=~"{pod}.*"}}[5m])'
        return await self._query_range(query, start_time, end_time)

    async def _query_memory(
        self,
        namespace: str,
        pod: str,
        start_time: datetime,
        end_time: datetime,
    ) -> list[dict[str, Any]]:
        """Query memory usage for a pod."""
        query = f'container_memory_working_set_bytes{{namespace="{namespace}",pod=~"{pod}.*"}}'
        return await self._query_range(query, start_time, end_time)

    async def _query_range(
        self,
        query: str,
        start_time: datetime,
        end_time: datetime,
        step: str = "1m",
    ) -> list[dict[str, Any]]:
        """Execute a range query against Prometheus."""
        # Use Unix timestamps for Prometheus API compatibility
        params = {
            "query": query,
            "start": start_time.timestamp(),
            "end": end_time.timestamp(),
            "step": step,
        }

        try:
            client = await self._get_client()
            response = await client.get(f"/api/v1/query_range?{urlencode(params)}")
            response.raise_for_status()
            data = response.json()
            return self._format_metrics(data)
        except Exception as e:
            logger.error(f"Failed to query Prometheus: {e}")
            return []

    def _format_metrics(self, data: dict[str, Any]) -> list[dict[str, Any]]:
        """Format Prometheus response into simplified metric data."""
        result = data.get("data", {}).get("result", [])
        formatted: list[dict[str, Any]] = []

        for metric in result:
            labels = metric.get("metric", {})
            values = metric.get("values", [])

            formatted.append({
                "container": labels.get("container", "unknown"),
                "values": [
                    {
                        "timestamp": datetime.fromtimestamp(ts).isoformat(),
                        "value": float(val),
                    }
                    for ts, val in values
                ],
            })

        return formatted

