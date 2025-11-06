# ArgoCD Progressive Sync & Resource Hooks

This document describes the progressive sync and resource hooks implementation for critical applications.

## Overview

Progressive sync and resource hooks provide:
- **Zero-downtime updates** through controlled rollouts
- **Automated pre-upgrade backups** for stateful applications
- **Post-deployment validation** to catch issues early
- **Automatic retries** on transient failures

## Implemented Applications

### 1. Traefik (Ingress Controller)

**Location**: `kubernetes/argocd/applications/network/traefik.yaml`

**Progressive Sync Configuration**:
```yaml
deployment:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
```

**Retry Policy**:
```yaml
syncPolicy:
  retry:
    limit: 5
    backoff:
      duration: 5s
      factor: 2
      maxDuration: 3m
```

**Post-Sync Hook**: `kubernetes/argocd/applications/network/traefik/post-sync-validation.yaml`
- Validates Traefik API endpoint (port 9000)
- Checks dashboard accessibility
- Tests web service endpoint (port 80)
- Runs after every sync operation
- Fails the sync if validation fails

**Benefits**:
- Zero-downtime ingress updates
- Automatic validation after deployments
- Quick rollback on failures

---

### 2. CloudNative-PG (PostgreSQL Cluster)

**Location**: `kubernetes/argocd/applications/database/cloudnative-pg-cluster.yaml`

**Retry Policy**:
```yaml
syncPolicy:
  retry:
    limit: 5
    backoff:
      duration: 10s
      factor: 2
      maxDuration: 5m
```

**Pre-Sync Hook**: `kubernetes/argocd/applications/database/cloudnative-pg/cluster/pre-sync-backup.yaml`
- Creates on-demand backup before cluster updates
- Checks cluster health before backup
- Uses barman-cloud plugin for S3 backup to MinIO
- Skips backup if cluster is unhealthy or doesn't exist
- Runs before every sync operation

**Post-Sync Hook**: `kubernetes/argocd/applications/database/cloudnative-pg/cluster/post-sync-validation.yaml`
- Waits 30 seconds for cluster stabilization
- Validates cluster health status
- Checks all instances are ready (4/4)
- Tests database connectivity via psql
- Verifies replication status
- Checks WAL archiving status
- Runs after every sync operation

**RBAC**: `kubernetes/argocd/applications/database/cloudnative-pg/cluster/hook-rbac.yaml`
- Role: `cnpg-hook-manager`
- Permissions: Read clusters, create/manage backups, exec into pods
- ServiceAccount: `postgres17` (created by CNPG operator)

**Benefits**:
- Automated pre-upgrade backups
- Comprehensive post-upgrade validation
- Safe database cluster updates
- Quick detection of issues

---

## How It Works

### Hook Lifecycle

1. **PreSync Hook** (if configured)
   - Runs before any resources are synced
   - Can fail the sync if pre-conditions aren't met
   - Example: Create backup before database update

2. **Sync Operation**
   - ArgoCD applies resources to cluster
   - Respects sync waves for ordering
   - Uses retry policy on failures

3. **PostSync Hook** (if configured)
   - Runs after all resources are synced
   - Validates deployment health
   - Can fail the sync if validation fails
   - Example: Test connectivity after ingress update

### Hook Annotations

```yaml
annotations:
  argocd.argoproj.io/hook: PreSync|PostSync|Sync|Skip
  argocd.argoproj.io/hook-delete-policy: BeforeHookCreation|HookSucceeded|HookFailed
```

### Retry Behavior

- **limit**: Maximum number of retry attempts
- **duration**: Initial backoff duration
- **factor**: Backoff multiplier (exponential backoff)
- **maxDuration**: Maximum backoff duration

Example: 5s → 10s → 20s → 40s → 80s (capped at 3m)

---

## Testing Hooks

### Manual Sync Test

Trigger a manual sync to test hooks:

```bash
# Force sync Traefik
kubectl patch application traefik -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'

# Force sync CNPG cluster
kubectl patch application cloudnative-pg-cluster -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
```

### Check Hook Job Status

```bash
# Check Traefik post-sync hook
kubectl get job traefik-post-sync-validation -n network
kubectl logs job/traefik-post-sync-validation -n network

# Check CNPG hooks
kubectl get job cnpg-pre-sync-backup -n database
kubectl get job cnpg-post-sync-validation -n database
kubectl logs job/cnpg-pre-sync-backup -n database
kubectl logs job/cnpg-post-sync-validation -n database
```

**Note**: Hook jobs are automatically deleted based on `hook-delete-policy`. Use `BeforeHookCreation` to see logs from the most recent run.

---

## Future Enhancements

Potential candidates for progressive sync and hooks:

1. **Authentik** - Authentication service
   - Pre-sync: Database backup
   - Post-sync: Login validation

2. **Loki** - Log aggregation
   - Post-sync: Query validation
   - Progressive: StatefulSet rolling update

3. **Prometheus** - Metrics collection
   - Post-sync: Scrape target validation
   - Progressive: StatefulSet rolling update

4. **MinIO** - Object storage
   - Pre-sync: Backup validation
   - Post-sync: S3 API validation

