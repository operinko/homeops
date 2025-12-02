# Log Aggregator Middleware

FastAPI middleware for aggregating Kubernetes logs, events, and metrics when alerts fire, enabling LLM-based log summarization.

## Features

- **Alertmanager Webhook Receiver**: Receives alerts and collects contextual data
- **Loki Integration**: Queries pod logs around alert time (±30 min window)
- **Prometheus Integration**: Collects CPU/memory metrics for affected pods
- **Kubernetes Events**: Captures relevant Warning and context events
- **PostgreSQL Storage**: Persists alert contexts for daily summarization
- **Daily Summary API**: Provides aggregated data for n8n workflow

## Architecture

```
Alertmanager → POST /api/alert → Log Aggregator → Loki/Prometheus/K8s API
                                      ↓
                                 PostgreSQL
                                      ↓
n8n (nightly) → GET /api/daily-summary → Ollama → Discord/Email
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check with dependency status |
| POST | `/api/alert` | Alertmanager webhook receiver |
| GET | `/api/daily-summary` | Get alerts for a day (query: `?date=YYYY-MM-DD`) |
| POST | `/api/cleanup` | Remove old alert contexts |

## Configuration

Environment variables (prefix: `LOG_AGGREGATOR_`):

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | `postgresql+asyncpg://...` | PostgreSQL connection string |
| `LOKI_URL` | `http://loki-headless...` | Loki API URL |
| `PROMETHEUS_URL` | `http://kube-prometheus...` | Prometheus API URL |
| `LOKI_LOG_WINDOW_MINUTES` | `30` | Minutes before/after alert to collect logs |
| `LOKI_PREVIOUS_LOGS_LINES` | `30` | Lines of previous container logs |
| `ALERT_RETENTION_DAYS` | `7` | Days to keep alert contexts |
| `DEBUG` | `false` | Enable debug logging |

## Local Development

```bash
# Install dependencies
uv venv
source .venv/bin/activate
uv pip install -e ".[dev]"

# Run locally (requires port-forwarding to cluster services)
LOG_AGGREGATOR_KUBERNETES_IN_CLUSTER=false \
LOG_AGGREGATOR_LOKI_URL=http://localhost:3100 \
LOG_AGGREGATOR_PROMETHEUS_URL=http://localhost:9090 \
python -m log_aggregator.main
```

## Docker Build

```bash
docker build -t log-aggregator .
docker run -p 8080:8080 log-aggregator
```

## Kubernetes Deployment

The application is deployed via ArgoCD in the `tools` namespace. See `kubernetes/argocd/applications/tools/apps/log-aggregator/` for manifests.

