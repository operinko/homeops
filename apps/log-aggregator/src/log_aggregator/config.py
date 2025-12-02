"""Application configuration using Pydantic settings."""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    model_config = SettingsConfigDict(
        env_prefix="LOG_AGGREGATOR_",
        env_file=".env",
        env_file_encoding="utf-8",
    )

    # Database
    database_url: str = "postgresql+asyncpg://log_aggregator:log_aggregator@localhost:5432/log_aggregator"

    # Loki
    loki_url: str = "http://loki-headless.observability.svc.cluster.local:3100"
    loki_log_window_minutes: int = 30
    loki_previous_logs_lines: int = 30

    # Prometheus
    prometheus_url: str = "http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090"

    # Kubernetes API (in-cluster)
    kubernetes_in_cluster: bool = True

    # Server
    host: str = "0.0.0.0"
    port: int = 8080
    debug: bool = False

    # Retention
    alert_retention_days: int = 7


settings = Settings()

