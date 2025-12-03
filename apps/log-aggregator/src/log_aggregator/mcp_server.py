"""MCP Server for LLM-driven alert analysis."""

import logging
from datetime import datetime, timedelta, timezone
from typing import Any

from mcp.server.fastmcp import FastMCP

from .clients import KubernetesClient, LokiClient, PrometheusClient
from .config import settings

logger = logging.getLogger(__name__)

# Create MCP server instance
mcp = FastMCP(
    "Log Aggregator",
    stateless_http=True,  # No session persistence needed
)

# Singleton clients for MCP tools
_loki_client: LokiClient | None = None
_prometheus_client: PrometheusClient | None = None
_kubernetes_client: KubernetesClient | None = None


def _get_loki() -> LokiClient:
    global _loki_client
    if _loki_client is None:
        _loki_client = LokiClient()
    return _loki_client


def _get_prometheus() -> PrometheusClient:
    global _prometheus_client
    if _prometheus_client is None:
        _prometheus_client = PrometheusClient()
    return _prometheus_client


def _get_kubernetes() -> KubernetesClient:
    global _kubernetes_client
    if _kubernetes_client is None:
        _kubernetes_client = KubernetesClient()
    return _kubernetes_client


@mcp.tool()
async def list_alerts(hours_back: int = 24) -> dict[str, Any]:
    """List recent alerts from the cluster.

    Returns a lightweight summary of alerts - use get_alert_logs, get_alert_events,
    or get_alert_metrics to fetch detailed context for specific alerts.

    Args:
        hours_back: How many hours to look back (default: 24)

    Returns:
        Dictionary with alert summaries grouped by namespace
    """
    # Import here to avoid circular imports
    from sqlalchemy import select
    from .database import async_session_maker
    from .models import AlertContext

    since = datetime.now(timezone.utc) - timedelta(hours=hours_back)

    async with async_session_maker() as session:
        stmt = select(AlertContext).where(
            AlertContext.fired_at >= since
        ).order_by(AlertContext.fired_at.desc())

        result = await session.execute(stmt)
        alerts = result.scalars().all()

    # Build lightweight summary
    by_namespace: dict[str, list[dict[str, Any]]] = {}
    for alert in alerts:
        ns = alert.namespace or "unknown"
        if ns not in by_namespace:
            by_namespace[ns] = []

        by_namespace[ns].append({
            "id": str(alert.id),
            "alertname": alert.alertname,
            "severity": alert.severity,
            "pod": alert.pod,
            "container": alert.container,
            "fired_at": alert.fired_at.isoformat() if alert.fired_at else None,
            "status": alert.status,
            "summary": alert.annotations.get("summary", "") if alert.annotations else "",
        })

    return {
        "total_alerts": len(alerts),
        "period_hours": hours_back,
        "alerts_by_namespace": by_namespace,
    }


@mcp.tool()
async def get_pod_logs(
    namespace: str,
    pod: str,
    container: str | None = None,
    minutes_back: int = 5,
    max_lines: int = 100,
) -> dict[str, Any]:
    """Fetch logs for a specific pod from Loki.

    Args:
        namespace: Kubernetes namespace
        pod: Pod name (can be partial, will match with prefix)
        container: Container name (optional)
        minutes_back: How many minutes of logs to fetch (default: 5)
        max_lines: Maximum number of log lines (default: 100)

    Returns:
        Dictionary with log content and metadata
    """
    loki = _get_loki()
    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(minutes=minutes_back)

    logs = await loki.query_logs(
        namespace=namespace,
        pod=pod,
        container=container,
        start_time=start_time,
        end_time=end_time,
        limit=max_lines,
    )

    # Truncate if too long (keep under 10k chars for context efficiency)
    max_chars = 10000
    truncated = False
    if len(logs) > max_chars:
        logs = logs[:max_chars] + "\n... [truncated]"
        truncated = True

    return {
        "namespace": namespace,
        "pod": pod,
        "container": container,
        "period_minutes": minutes_back,
        "truncated": truncated,
        "logs": logs,
    }


@mcp.tool()
async def get_pod_events(
    namespace: str,
    pod: str | None = None,
    hours_back: int = 1,
) -> dict[str, Any]:
    """Fetch Kubernetes events for a namespace/pod.

    Events are deduplicated by reason+message, showing count and time range.

    Args:
        namespace: Kubernetes namespace
        pod: Pod name (optional, if not specified gets all namespace events)
        hours_back: How many hours of events to fetch (default: 1)

    Returns:
        Dictionary with deduplicated events
    """
    k8s = _get_kubernetes()
    since = datetime.now(timezone.utc) - timedelta(hours=hours_back)

    events = await k8s.get_events(
        namespace=namespace,
        pod=pod,
        since=since,
    )

    # Deduplicate events by reason+message
    deduped: dict[str, dict[str, Any]] = {}
    for event in events:
        key = f"{event.get('reason', '')}:{event.get('message', '')[:100]}"
        if key in deduped:
            deduped[key]["count"] += event.get("count", 1)
            # Update time range
            last_ts = event.get("last_timestamp")
            if last_ts and (not deduped[key]["last_timestamp"] or last_ts > deduped[key]["last_timestamp"]):
                deduped[key]["last_timestamp"] = last_ts
        else:
            deduped[key] = {
                "type": event.get("type"),
                "reason": event.get("reason"),
                "message": event.get("message"),
                "count": event.get("count", 1),
                "first_timestamp": event.get("first_timestamp"),
                "last_timestamp": event.get("last_timestamp"),
                "involved_object": event.get("involved_object"),
            }

    return {
        "namespace": namespace,
        "pod": pod,
        "period_hours": hours_back,
        "total_events": len(deduped),
        "events": list(deduped.values()),
    }

@mcp.tool()
async def get_pod_metrics(
    namespace: str,
    pod: str,
) -> dict[str, Any]:
    """Fetch current CPU and memory metrics for a pod.

    Returns only the latest values (not time series) for efficiency.

    Args:
        namespace: Kubernetes namespace
        pod: Pod name

    Returns:
        Dictionary with current CPU and memory usage per container
    """
    prom = _get_prometheus()
    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(minutes=5)

    metrics = await prom.query_pod_metrics(
        namespace=namespace,
        pod=pod,
        start_time=start_time,
        end_time=end_time,
    )

    # Extract only the latest values per container
    summary: dict[str, dict[str, Any]] = {}

    for cpu_data in metrics.get("cpu", []):
        container = cpu_data.get("container", "unknown")
        values = cpu_data.get("values", [])
        if values:
            latest = values[-1]
            if container not in summary:
                summary[container] = {}
            summary[container]["cpu_cores"] = round(latest.get("value", 0), 4)

    for mem_data in metrics.get("memory", []):
        container = mem_data.get("container", "unknown")
        values = mem_data.get("values", [])
        if values:
            latest = values[-1]
            if container not in summary:
                summary[container] = {}
            # Convert bytes to MiB
            mem_bytes = latest.get("value", 0)
            summary[container]["memory_mib"] = round(mem_bytes / (1024 * 1024), 2)

    return {
        "namespace": namespace,
        "pod": pod,
        "containers": summary,
    }


@mcp.tool()
async def get_cluster_health() -> dict[str, Any]:
    """Get overall cluster health status.

    Returns a high-level summary of cluster health based on recent alerts.
    """
    # Import here to avoid circular imports
    from sqlalchemy import select
    from .database import async_session_maker
    from .models import AlertContext

    since = datetime.now(timezone.utc) - timedelta(hours=24)

    async with async_session_maker() as session:
        stmt = select(AlertContext).where(
            AlertContext.fired_at >= since
        )
        result = await session.execute(stmt)
        alerts = result.scalars().all()

    # Count by severity
    critical = sum(1 for a in alerts if a.severity == "critical")
    warning = sum(1 for a in alerts if a.severity == "warning")
    info = sum(1 for a in alerts if a.severity == "info")

    # Determine health status
    if critical > 0:
        health = "critical"
    elif warning > 5:
        health = "warning"
    elif warning > 0:
        health = "degraded"
    else:
        health = "healthy"

    # Group by alertname for pattern detection
    by_alertname: dict[str, int] = {}
    for alert in alerts:
        name = alert.alertname or "unknown"
        by_alertname[name] = by_alertname.get(name, 0) + 1

    return {
        "status": health,
        "period_hours": 24,
        "total_alerts": len(alerts),
        "by_severity": {
            "critical": critical,
            "warning": warning,
            "info": info,
        },
        "top_alerts": sorted(by_alertname.items(), key=lambda x: x[1], reverse=True)[:10],
    }
