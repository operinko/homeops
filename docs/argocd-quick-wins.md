# ArgoCD Quick Wins - Implementation Guide

This document provides step-by-step instructions for implementing the highest-impact improvements to your ArgoCD setup.

---

## Quick Win #1: Enable ArgoCD Notifications (15 minutes)

### Benefits
- Get notified on sync failures
- Track deployment status
- Reuse existing Pushover setup

### Implementation

1. **Create Pushover secret** (if not already exists):

```bash
kubectl create secret generic argocd-notifications-secret \
  -n argocd \
  --from-literal=pushover-token='YOUR_PUSHOVER_APP_TOKEN' \
  --from-literal=pushover-user='YOUR_PUSHOVER_USER_KEY'
```

2. **Update ArgoCD configuration** in `kubernetes/argocd/applications/argocd/argocd.yaml`:

```yaml
notifications:
  enabled: true
  secret:
    create: false
    name: argocd-notifications-secret
  notifiers:
    service.pushover: |
      token: $pushover-token
      user: $pushover-user
  subscriptions:
    - recipients:
        - pushover
      triggers:
        - on-sync-failed
        - on-health-degraded
        - on-sync-status-unknown
  templates:
    template.app-sync-failed: |
      message: |
        Application {{.app.metadata.name}} sync failed.
        Sync operation details: {{.app.status.operationState.message}}
      title: "ArgoCD Sync Failed"
      priority: 1
```

3. **Commit and sync**:

```bash
git add kubernetes/argocd/applications/argocd/argocd.yaml
git commit -m "feat(argocd): enable notifications with Pushover"
git push
```

---

## Quick Win #2: Standardize Sync Waves (30 minutes)

### Benefits
- Predictable deployment order
- Better dependency management
- Easier troubleshooting

### Standard Wave Numbers

- **Wave 0**: Namespaces
- **Wave 1**: Secrets, ConfigMaps, RBAC, HTTPRoutes
- **Wave 2**: Operators, CRDs, Infrastructure
- **Wave 3**: Operator instances (clusters, databases)
- **Wave 4**: Applications depending on wave 3 services

### Implementation

Review and update sync waves across all namespaces. Example for database namespace:

```yaml
# database-namespace.yaml
annotations:
  argocd.argoproj.io/sync-wave: "0"

# dragonfly-operator.yaml
annotations:
  argocd.argoproj.io/sync-wave: "2"

# dragonfly-resources.yaml (secrets, configmaps)
annotations:
  argocd.argoproj.io/sync-wave: "1"

# dragonfly cluster instance
annotations:
  argocd.argoproj.io/sync-wave: "3"

# Applications using Dragonfly (e.g., in default namespace)
annotations:
  argocd.argoproj.io/sync-wave: "4"
```

---

## Quick Win #3: Add Orphaned Resources Monitoring (10 minutes)

### Benefits
- Detect resources not tracked by ArgoCD
- Prevent configuration drift
- Better cleanup

### Implementation

Update all AppProject files to include:

```yaml
spec:
  orphanedResources:
    warn: true
    ignore:
      - group: ''
        kind: ConfigMap
        name: kube-root-ca.crt
      - group: ''
        kind: Secret
        name: sh.helm.release.*
```

Example for media project (`kubernetes/argocd/applications/projects/media.yaml`):

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: media
  namespace: argocd
spec:
  description: Media namespace project
  sourceRepos:
    - 'https://github.com/operinko/homeops.git'
    - 'https://bjw-s-labs.github.io/helm-charts'
    - 'oci://ghcr.io/bjw-s/helm'
  destinations:
    - namespace: 'media'
      server: 'https://kubernetes.default.svc'
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  orphanedResources:
    warn: true
    ignore:
      - group: ''
        kind: ConfigMap
        name: kube-root-ca.crt
      - group: ''
        kind: Secret
        name: sh.helm.release.*
```

Apply to all 13 project files.

---

## Quick Win #4: Add Health Checks for Custom Resources (20 minutes)

### Benefits
- Better visibility into application health
- Accurate status in ArgoCD UI
- Faster troubleshooting

### Implementation

Update `kubernetes/argocd/applications/argocd/argocd.yaml` to add health checks:

```yaml
configs:
  cm:
    exec.enabled: "true"
    # Existing HelmRelease health check
    resource.customizations.health.helm.toolkit.fluxcd.io_HelmRelease: |
      # ... existing ...
    
    # Dragonfly health check
    resource.customizations.health.dragonflydb.io_Dragonfly: |
      hs = {}
      if obj.status ~= nil then
        if obj.status.phase == "ready" then
          hs.status = "Healthy"
          hs.message = "Dragonfly cluster is ready"
          return hs
        end
      end
      hs.status = "Progressing"
      hs.message = "Dragonfly cluster is not ready"
      return hs
    
    # CloudNative-PG Cluster health check
    resource.customizations.health.postgresql.cnpg.io_Cluster: |
      hs = {}
      if obj.status ~= nil then
        if obj.status.phase == "Cluster in healthy state" then
          hs.status = "Healthy"
          hs.message = obj.status.phase
          return hs
        end
      end
      hs.status = "Progressing"
      hs.message = "Cluster is not ready"
      return hs
```

---

## Verification

After implementing these quick wins:

1. **Check ArgoCD UI** - Verify notifications are configured
2. **Test notification** - Trigger a sync failure to test Pushover
3. **Review sync waves** - Check application sync order in UI
4. **Check orphaned resources** - Look for warnings in ArgoCD UI
5. **Verify health checks** - Ensure custom resources show correct health status

---

## Next Steps

After completing these quick wins, consider:

1. **Media ApplicationSet** - See `docs/argocd-improvements-proposal.md`
2. **Storage ApplicationSet** - See `docs/examples/storage-csi-applicationset-example.yaml`
3. **ArgoCD Metrics Dashboard** - Create Grafana dashboard
4. **Documentation** - Add README files to namespace directories

---

## Rollback Plan

If any changes cause issues:

1. **Revert git commit**:
   ```bash
   git revert HEAD
   git push
   ```

2. **Force sync in ArgoCD UI** or CLI:
   ```bash
   argocd app sync argocd --force
   ```

3. **Check ArgoCD logs**:
   ```bash
   kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
   ```

