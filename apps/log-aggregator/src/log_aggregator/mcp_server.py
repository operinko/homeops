"""MCP Server for LLM-driven alert analysis."""

import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

from .clients import KubernetesClient, LokiClient, PrometheusClient
from .config import settings

logger = logging.getLogger(__name__)

# Configure security to allow Kubernetes service hostnames
security_settings = TransportSecuritySettings(
    enable_dns_rebinding_protection=False,  # Disable for internal K8s traffic
)

# Create MCP server instance
mcp = FastMCP(
    "Log Aggregator",
    stateless_http=True,  # No session persistence needed
    transport_security=security_settings,
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
async def list_alerts(
    hours_back: int = 24,
    severity: str | None = None,
    limit: int = 50,
) -> dict[str, Any]:
    """List recent alerts from the cluster (lightweight).

    Returns only essential info per alert. Use get_alert_details(alert_id) to
    fetch full details for specific alerts worth investigating.

    Args:
        hours_back: How many hours to look back (default: 24)
        severity: Filter by severity - "critical", "warning", or "info" (default: all)
        limit: Maximum number of alerts to return (default: 50)

    Returns:
        Dictionary with minimal alert info grouped by namespace
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

    # Filter by severity if specified
    if severity:
        alerts = [a for a in alerts if a.severity == severity]

    total_before_limit = len(alerts)
    alerts = alerts[:limit]

    # Build lightweight list - just enough to identify and prioritize
    alert_list = []
    for alert in alerts:
        # Extract service name from pod
        service = None
        if alert.pod:
            parts = alert.pod.rsplit("-", 2)
            service = parts[0] if len(parts) >= 2 else alert.pod

        alert_list.append({
            "id": str(alert.id),
            "alert": alert.alertname,
            "severity": alert.severity,
            "service": service,
            "namespace": alert.namespace or "unknown",
        })

    return {
        "total_matching": total_before_limit,
        "returned": len(alerts),
        "period_hours": hours_back,
        "severity_filter": severity,
        "alerts": alert_list,
    }


@mcp.tool()
async def get_alert_details(alert_id: str) -> dict[str, Any]:
    """Get full details for a specific alert.

    Use this after list_alerts to get complete information about an alert
    including pod name, container, timestamps, status, and annotations.

    Args:
        alert_id: The alert ID from list_alerts

    Returns:
        Dictionary with full alert details
    """
    from sqlalchemy import select
    from .database import async_session_maker
    from .models import AlertContext

    try:
        from uuid import UUID
        alert_uuid = UUID(alert_id)
    except ValueError:
        return {"error": f"Invalid alert ID format: {alert_id}"}

    async with async_session_maker() as session:
        stmt = select(AlertContext).where(AlertContext.id == alert_uuid)
        result = await session.execute(stmt)
        alert = result.scalar_one_or_none()

    if not alert:
        return {"error": f"Alert not found: {alert_id}"}

    return {
        "id": str(alert.id),
        "alertname": alert.alertname,
        "severity": alert.severity,
        "namespace": alert.namespace,
        "pod": alert.pod,
        "container": alert.container,
        "node": alert.node,
        "status": alert.status,
        "fired_at": alert.fired_at.isoformat() if alert.fired_at else None,
        "resolved_at": alert.resolved_at.isoformat() if alert.resolved_at else None,
        "labels": alert.labels or {},
        "annotations": alert.annotations or {},
        "summary": alert.annotations.get("summary", "") if alert.annotations else "",
        "description": alert.annotations.get("description", "") if alert.annotations else "",
    }


@mcp.tool()
async def get_pod_logs(
    namespace: str,
    pod: str,
    container: Optional[str] = None,
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
    pod: Optional[str] = None,
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

    # Group by alertname with affected services
    by_alertname: dict[str, dict[str, Any]] = {}
    for alert in alerts:
        name = alert.alertname or "unknown"
        if name not in by_alertname:
            by_alertname[name] = {"count": 0, "services": []}
        by_alertname[name]["count"] += 1

        # Extract service name from pod name (e.g., "sonarr-abc123" -> "sonarr")
        service = None
        if alert.pod:
            # Remove common suffixes like -abc123, -deployment-hash, etc.
            parts = alert.pod.rsplit("-", 2)
            if len(parts) >= 2:
                service = parts[0]
            else:
                service = alert.pod

        if service and alert.namespace:
            service_key = f"{service} ({alert.namespace})"
            if service_key not in by_alertname[name]["services"]:
                by_alertname[name]["services"].append(service_key)

    # Format top alerts with affected services
    top_alerts = []
    for name, data in sorted(by_alertname.items(), key=lambda x: x[1]["count"], reverse=True)[:10]:
        top_alerts.append({
            "alert": name,
            "count": data["count"],
            "affected_services": data["services"][:5],  # Limit to top 5 services per alert type
        })

    return {
        "status": health,
        "period_hours": 24,
        "total_alerts": len(alerts),
        "by_severity": {
            "critical": critical,
            "warning": warning,
            "info": info,
        },
        "top_alerts": top_alerts,
    }
