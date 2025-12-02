"""Database models and Pydantic schemas."""

import uuid
from datetime import datetime
from enum import Enum
from typing import Any

from pydantic import BaseModel, Field
from sqlalchemy import JSON, DateTime, String, Text, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


# SQLAlchemy Models
class Base(DeclarativeBase):
    """Base class for SQLAlchemy models."""

    pass


class AlertContext(Base):
    """Stored alert context with collected logs, events, and metrics."""

    __tablename__ = "alert_contexts"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    alert_name: Mapped[str] = mapped_column(String(255), nullable=False, index=True)
    alertname: Mapped[str] = mapped_column(String(255), nullable=False, index=True)
    namespace: Mapped[str] = mapped_column(String(255), nullable=False, index=True)
    pod: Mapped[str | None] = mapped_column(String(255), nullable=True)
    container: Mapped[str | None] = mapped_column(String(255), nullable=True)
    severity: Mapped[str] = mapped_column(String(50), nullable=False, index=True)
    status: Mapped[str] = mapped_column(String(50), nullable=False, default="firing")
    fired_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    
    # Collected context
    logs: Mapped[str | None] = mapped_column(Text, nullable=True)
    previous_logs: Mapped[str | None] = mapped_column(Text, nullable=True)
    events: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)
    metrics: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)
    
    # Alert labels and annotations
    labels: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False, default=dict)
    annotations: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False, default=dict)
    
    # Timestamps
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )


# Pydantic Schemas
class AlertSeverity(str, Enum):
    """Alert severity levels."""

    CRITICAL = "critical"
    WARNING = "warning"
    INFO = "info"


class AlertStatus(str, Enum):
    """Alert status."""

    FIRING = "firing"
    RESOLVED = "resolved"


class AlertmanagerAlert(BaseModel):
    """Single alert from Alertmanager webhook."""

    status: AlertStatus
    labels: dict[str, str]
    annotations: dict[str, str] = Field(default_factory=dict)
    startsAt: datetime
    endsAt: datetime | None = None
    generatorURL: str | None = None
    fingerprint: str | None = None


class AlertmanagerWebhook(BaseModel):
    """Alertmanager webhook payload."""

    receiver: str
    status: AlertStatus
    alerts: list[AlertmanagerAlert]
    groupLabels: dict[str, str] = Field(default_factory=dict)
    commonLabels: dict[str, str] = Field(default_factory=dict)
    commonAnnotations: dict[str, str] = Field(default_factory=dict)
    externalURL: str | None = None
    version: str = "4"
    groupKey: str | None = None
    truncatedAlerts: int = 0


class AlertContextResponse(BaseModel):
    """Response schema for alert context."""

    id: uuid.UUID
    alert_name: str
    alertname: str
    namespace: str
    pod: str | None
    container: str | None
    severity: str
    status: str
    fired_at: datetime
    resolved_at: datetime | None
    logs: str | None
    previous_logs: str | None
    events: dict[str, Any] | None
    metrics: dict[str, Any] | None
    labels: dict[str, Any]
    annotations: dict[str, Any]
    created_at: datetime

    class Config:
        from_attributes = True


class DailySummaryResponse(BaseModel):
    """Response for daily summary endpoint."""

    date: str
    total_alerts: int
    alerts_by_severity: dict[str, int]
    alerts_by_namespace: dict[str, int]
    alerts: list[AlertContextResponse]


class HealthResponse(BaseModel):
    """Health check response."""

    status: str
    version: str
    database: str
    loki: str
    prometheus: str

