"""Business logic services."""

import logging
from collections import Counter
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .clients import KubernetesClient, LokiClient, PrometheusClient
from .config import settings
from .models import AlertContext, AlertmanagerWebhook, AlertSeverity

logger = logging.getLogger(__name__)


class AlertService:
    """Service for processing and storing alerts."""

    def __init__(
        self,
        session: AsyncSession,
        loki: LokiClient,
        prometheus: PrometheusClient,
        kubernetes: KubernetesClient,
    ) -> None:
        self.session = session
        self.loki = loki
        self.prometheus = prometheus
        self.kubernetes = kubernetes

    async def process_webhook(self, webhook: AlertmanagerWebhook) -> list[AlertContext]:
        """Process incoming Alertmanager webhook and collect context for each alert."""
        contexts: list[AlertContext] = []
        
        for alert in webhook.alerts:
            labels = alert.labels
            namespace = labels.get("namespace", "unknown")
            pod = labels.get("pod")
            container = labels.get("container")
            alertname = labels.get("alertname", "unknown")
            severity = labels.get("severity", "warning")
            
            # Determine alert time for log queries
            alert_time = alert.startsAt
            start_time = alert_time - timedelta(minutes=settings.loki_log_window_minutes)
            end_time = alert_time + timedelta(minutes=settings.loki_log_window_minutes)
            
            # Collect context in parallel
            logs = ""
            previous_logs = ""
            events: list[dict[str, Any]] = []
            metrics: dict[str, Any] = {}
            
            try:
                # Get logs from Loki
                if pod:
                    logs = await self.loki.query_logs(
                        namespace=namespace,
                        pod=pod,
                        container=container,
                        start_time=start_time,
                        end_time=end_time,
                    )
                    
                    # Get previous logs if crashloop
                    if "crash" in alertname.lower() or "restart" in alertname.lower():
                        previous_logs = await self.loki.query_previous_logs(
                            namespace=namespace,
                            pod=pod,
                            container=container,
                        )
                    
                    # Get metrics
                    metrics = await self.prometheus.query_pod_metrics(
                        namespace=namespace,
                        pod=pod,
                        start_time=start_time,
                        end_time=end_time,
                    )
                
                # Get Kubernetes events
                events = await self.kubernetes.get_events(
                    namespace=namespace,
                    pod=pod,
                    since=start_time,
                )
                
            except Exception as e:
                logger.error(f"Error collecting context for alert {alertname}: {e}")
            
            # Create alert context
            context = AlertContext(
                alert_name=f"{namespace}/{alertname}",
                alertname=alertname,
                namespace=namespace,
                pod=pod,
                container=container,
                severity=severity,
                status=alert.status.value,
                fired_at=alert_time,
                resolved_at=alert.endsAt if alert.status.value == "resolved" else None,
                logs=logs if logs else None,
                previous_logs=previous_logs if previous_logs else None,
                events=events if events else None,
                metrics=metrics if metrics else None,
                labels=labels,
                annotations=alert.annotations,
            )
            
            self.session.add(context)
            contexts.append(context)
        
        await self.session.commit()
        return contexts

    async def get_daily_summary(
        self,
        date: datetime | None = None,
    ) -> dict[str, Any]:
        """Get summary of alerts for a specific day."""
        if date is None:
            date = datetime.now(timezone.utc)
        
        # Calculate day boundaries
        start_of_day = date.replace(hour=0, minute=0, second=0, microsecond=0)
        end_of_day = start_of_day + timedelta(days=1)
        
        # Query alerts for the day
        stmt = select(AlertContext).where(
            AlertContext.fired_at >= start_of_day,
            AlertContext.fired_at < end_of_day,
        ).order_by(AlertContext.fired_at.desc())
        
        result = await self.session.execute(stmt)
        alerts = result.scalars().all()
        
        # Build summary
        severity_counts = Counter(a.severity for a in alerts)
        namespace_counts = Counter(a.namespace for a in alerts)
        
        return {
            "date": start_of_day.strftime("%Y-%m-%d"),
            "total_alerts": len(alerts),
            "alerts_by_severity": dict(severity_counts),
            "alerts_by_namespace": dict(namespace_counts),
            "alerts": alerts,
        }

    async def cleanup_old_alerts(self) -> int:
        """Delete alerts older than retention period."""
        cutoff = datetime.now(timezone.utc) - timedelta(days=settings.alert_retention_days)
        stmt = select(AlertContext).where(AlertContext.created_at < cutoff)
        result = await self.session.execute(stmt)
        old_alerts = result.scalars().all()
        
        for alert in old_alerts:
            await self.session.delete(alert)
        
        await self.session.commit()
        return len(old_alerts)

