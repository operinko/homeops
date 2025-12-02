"""Kubernetes client for querying events."""

import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any

import httpx

from ..config import settings

logger = logging.getLogger(__name__)


class KubernetesClient:
    """Client for querying Kubernetes API."""

    def __init__(self) -> None:
        self._client: httpx.AsyncClient | None = None
        self._token: str | None = None
        self._api_server: str | None = None

    async def _get_client(self) -> httpx.AsyncClient:
        if self._client is None:
            if settings.kubernetes_in_cluster:
                # In-cluster configuration
                self._token = self._read_token()
                self._api_server = "https://kubernetes.default.svc"
                ca_cert = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
                
                self._client = httpx.AsyncClient(
                    base_url=self._api_server,
                    headers={"Authorization": f"Bearer {self._token}"},
                    verify=ca_cert,
                    timeout=30.0,
                )
            else:
                # Out-of-cluster (for local dev)
                self._client = httpx.AsyncClient(timeout=30.0)
        return self._client

    def _read_token(self) -> str:
        """Read service account token from mounted secret."""
        token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
        if os.path.exists(token_path):
            with open(token_path) as f:
                return f.read().strip()
        return ""

    async def close(self) -> None:
        if self._client:
            await self._client.aclose()
            self._client = None

    async def health_check(self) -> bool:
        """Check if Kubernetes API is reachable."""
        try:
            client = await self._get_client()
            response = await client.get("/healthz")
            return response.status_code == 200
        except Exception as e:
            logger.error(f"Kubernetes health check failed: {e}")
            return False

    async def get_events(
        self,
        namespace: str,
        pod: str | None = None,
        since: datetime | None = None,
    ) -> list[dict[str, Any]]:
        """Get Kubernetes events for a namespace/pod."""
        if since is None:
            since = datetime.now(timezone.utc) - timedelta(hours=1)

        try:
            client = await self._get_client()
            
            # Query events in the namespace
            response = await client.get(
                f"/api/v1/namespaces/{namespace}/events"
            )
            response.raise_for_status()
            data = response.json()
            
            events = self._filter_events(data.get("items", []), pod, since)
            return events
        except Exception as e:
            logger.error(f"Failed to query Kubernetes events: {e}")
            return []

    def _filter_events(
        self,
        items: list[dict[str, Any]],
        pod: str | None,
        since: datetime,
    ) -> list[dict[str, Any]]:
        """Filter and format events."""
        filtered: list[dict[str, Any]] = []
        
        # Event types to capture
        warning_reasons = {
            "Failed", "FailedScheduling", "Unhealthy", "BackOff",
            "Evicted", "OOMKilling", "FailedMount", "FailedAttachVolume",
        }
        context_reasons = {
            "Killing", "Pulled", "Created", "Started", "Scheduled",
        }
        
        for item in items:
            reason = item.get("reason", "")
            event_type = item.get("type", "Normal")
            involved = item.get("involvedObject", {})
            
            # Filter by pod if specified
            if pod and not involved.get("name", "").startswith(pod):
                continue
            
            # Filter by event type/reason
            if event_type == "Warning" or reason in warning_reasons or reason in context_reasons:
                last_timestamp = item.get("lastTimestamp") or item.get("eventTime")
                if last_timestamp:
                    event_time = datetime.fromisoformat(last_timestamp.rstrip("Z"))
                    if event_time.tzinfo is None:
                        event_time = event_time.replace(tzinfo=timezone.utc)
                    if event_time < since:
                        continue
                
                filtered.append({
                    "type": event_type,
                    "reason": reason,
                    "message": item.get("message", ""),
                    "count": item.get("count", 1),
                    "first_timestamp": item.get("firstTimestamp"),
                    "last_timestamp": last_timestamp,
                    "involved_object": {
                        "kind": involved.get("kind"),
                        "name": involved.get("name"),
                    },
                })
        
        return filtered

