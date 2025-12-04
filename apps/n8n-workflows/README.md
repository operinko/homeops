# n8n Workflows

This directory contains n8n workflow JSON files for homelab automation.

## Workflows

### 1. Tautulli Watch Metrics (`tautulli-watch-metrics.json`)

**Schedule:** Weekly on Monday at 09:00

Generates a weekly Plex viewing report from Tautulli:
- Top 5 most watched movies and TV shows
- Most active users with play counts and watch time
- Library statistics (plays, duration by library)
- Total watch time and play counts

**Requirements:**
- Tautulli API key (configure in n8n credentials as `tautulli`)
- Discord webhook URL (replace `[discord-webhook]` placeholder)

---

### 2. Gatus Alert Enrichment (`gatus-alert-enrichment.json`)

**Trigger:** Webhook at `/webhook/gatus-alerts`

Enriches Gatus downtime alerts with contextual information:
- Fetches recent pod logs from log-aggregator MCP
- Fetches Kubernetes events for the affected pod
- Sends enriched Discord notification with logs + events embedded

**Gatus Configuration:**
Add to your Gatus alerting config:
```yaml
alerting:
  webhook:
    url: "http://n8n.tools.svc.cluster.local:5678/webhook/gatus-alerts"
    method: POST
```

**Requirements:**
- log-aggregator service running at `http://log-aggregator.tools.svc.cluster.local:8080`
- Discord webhook URL (replace `[discord-webhook]` placeholder)

---

### 3. Grafana Annotation Sync (`grafana-annotation-sync.json`)

**Trigger:** Webhook at `/webhook/grafana-annotations`

Creates Grafana annotations from various cluster events:
- **ArgoCD:** Sync status, health changes, deployments
- **VolSync:** Backup completions
- **System Upgrade:** Talos/K8s version upgrades
- **DNS:** External-dns record changes

**Usage:**
Send POST requests to the webhook with event data:
```json
{
  "source": "argocd",
  "app": "sonarr",
  "status": { "sync": { "status": "Synced", "revision": "abc1234" } }
}
```

**Requirements:**
- Grafana API credentials (HTTP Header Auth with `Authorization: Bearer <token>`)
- Configure n8n credentials for `httpHeaderAuth` with name `Grafana API`

---

### 4. Storj Node Metrics (`storj-node-metrics.json`)

**Schedule:** 
- Every 6 hours (health check, alerts only on issues)
- Weekly on Monday at 10:00 (summary report)

Monitors Storj storage node health:
- Storage usage (used/total GB, percentage)
- Satellite audit scores (alerts if < 99.5%)
- Suspension/disqualification status
- Bandwidth egress tracking
- Weekly summary with all satellite health

**Alert Thresholds:**
- 🔴 **Critical:** Audit score < 99%, any suspension
- ⚠️ **Warning:** Audit score < 99.5%, online score < 95%

**Requirements:**
- Storj node dashboard API at `https://storj.vaderrp.com:14002`
- Discord webhook URL (replace `[discord-webhook]` placeholder)

---

## Installation

1. Import each JSON file into n8n:
   - Open n8n → Workflows → Import from File
   - Select the workflow JSON file

2. Configure credentials:
   - **Discord:** Replace `[discord-webhook]` with your webhook URL
   - **Tautulli:** Create credential with API key
   - **Grafana:** Create HTTP Header Auth credential with API token
   - **Email (optional):** Configure SMTP for email alerts

3. Activate the workflows

## Service Endpoints (In-Cluster)

| Service | Endpoint |
|---------|----------|
| Tautulli | `http://tautulli.media.svc.cluster.local:8181` |
| Log Aggregator | `http://log-aggregator.tools.svc.cluster.local:8080` |
| Grafana | `http://grafana.observability.svc.cluster.local` |
| Storj | `https://storj.vaderrp.com:14002` |
| n8n | `http://n8n.tools.svc.cluster.local:5678` |

