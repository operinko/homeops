# Running ArgoCD and Flux Side-by-Side: Complete Guide

## Short Answer: YES, It's Safe ✅

Running both ArgoCD and Flux on the same cluster is **completely safe and a standard migration pattern**. Your setup is actually ideal for this because:

1. **Separate namespaces** - Flux uses `flux-system`, ArgoCD uses `argocd`
2. **No CRD conflicts** - Different CRD groups (flux vs argoproj)
3. **No webhook conflicts** - Different webhook paths and ports
4. **No label conflicts** - Different label schemes
5. **No resource conflicts** - They manage different resources

---

## Your Current Flux Setup

### Namespaces
- **flux-system** - Flux controllers and webhooks
- **flux-operator** - Flux operator (manages Flux instance)

### Flux Components (v2.7.3)
- source-controller
- kustomize-controller
- helm-controller
- notification-controller

### Flux CRDs (No Conflicts)
- `source.toolkit.fluxcd.io` - GitRepository, HelmRepository, etc.
- `kustomize.toolkit.fluxcd.io` - Kustomization
- `helm.toolkit.fluxcd.io` - HelmRelease
- `notification.toolkit.fluxcd.io` - Receiver, Alert

### Flux Webhooks
- **Path**: `/hook` on `flux-webhook.vaderrp.com`
- **Port**: 80 (internal), exposed via Gateway
- **Type**: GitHub webhook receiver

---

## Why There Are No Conflicts

### 1. Different CRD Groups
```
Flux CRDs:
  - source.toolkit.fluxcd.io/v1
  - kustomize.toolkit.fluxcd.io/v1
  - helm.toolkit.fluxcd.io/v2
  - notification.toolkit.fluxcd.io/v1

ArgoCD CRDs:
  - argoproj.io/v1alpha1 (Application, ApplicationSet)
  - argoproj.io/v1beta1 (AppProject)
```
**Result**: No overlap, no conflicts ✅

### 2. Different Namespaces
```
Flux:
  - flux-system (controllers, webhooks)
  - flux-operator (operator)

ArgoCD:
  - argocd (controllers, UI, repo-server)
```
**Result**: Isolated deployments ✅

### 3. Different Webhook Paths
```
Flux:
  - https://flux-webhook.vaderrp.com/hook

ArgoCD:
  - https://argocd-webhook.vaderrp.com/api/webhook (if configured)
```
**Result**: No port conflicts ✅

### 4. Different Resource Labels
```
Flux labels:
  - app.kubernetes.io/part-of: flux
  - app.kubernetes.io/instance: flux-system

ArgoCD labels:
  - app.kubernetes.io/part-of: argocd
  - app.kubernetes.io/instance: argocd
```
**Result**: Easy to distinguish ✅

---

## Potential Issues and How to Avoid Them

### Issue 1: Resource Ownership Conflicts

**Problem**: If both Flux and ArgoCD try to manage the same resource, they'll fight over it.

**Solution**: Use clear ownership boundaries:
- **Flux manages**: Infrastructure, storage, system components
- **ArgoCD manages**: Applications (during migration)

**Implementation**:
```yaml
# Flux Kustomization (keep managing infrastructure)
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
spec:
  path: ./kubernetes/infrastructure/

# ArgoCD Application (manage apps)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sonarr
spec:
  source:
    path: kubernetes/apps/media/sonarr/app
```

### Issue 2: Webhook Receiver Conflicts

**Problem**: GitHub webhook might trigger both Flux and ArgoCD reconciliations.

**Solution**: Configure separate webhooks:
- **Flux webhook**: `flux-webhook.vaderrp.com/hook`
- **ArgoCD webhook**: `argocd-webhook.vaderrp.com/api/webhook`

**Or**: Disable Flux webhook during migration:
```bash
# Suspend Flux receiver to prevent duplicate reconciliations
kubectl patch receiver github-webhook -n flux-system \
  -p '{"spec":{"suspend":true}}' --type merge
```

### Issue 3: Resource Quota Conflicts

**Problem**: Both controllers might compete for resources.

**Solution**: Set resource limits for ArgoCD:
```yaml
# kubernetes/argocd/argocd-server.yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

### Issue 4: RBAC and ServiceAccount Conflicts

**Problem**: Different RBAC models might cause permission issues.

**Solution**: Each tool has its own ServiceAccounts:
```bash
# Flux ServiceAccounts
kubectl get sa -n flux-system
# Expected: source-controller, kustomize-controller, helm-controller, etc.

# ArgoCD ServiceAccounts
kubectl get sa -n argocd
# Expected: argocd-server, argocd-repo-server, argocd-controller-manager, etc.
```

---

## Migration Strategy: Parallel Running

### Phase 1: Install ArgoCD (Week 1)
```bash
# Install ArgoCD in separate namespace
kubectl create namespace argocd
kubectl apply -n argocd -f argocd-install.yaml

# Verify no conflicts
kubectl get pods -n flux-system
kubectl get pods -n argocd
# Both should be running
```

### Phase 2: Migrate Non-Critical Apps (Week 2)
```bash
# Deploy ArgoCD Applications for non-critical apps
kubectl apply -f kubernetes/argocd/applications/tools/

# Verify both are running
kubectl get applications -n argocd
kubectl get kustomizations -n flux-system
# Both should show resources
```

### Phase 3: Monitor for Conflicts (Week 2-3)
```bash
# Check for resource conflicts
kubectl get events -A | grep -i conflict

# Check controller logs
kubectl logs -n flux-system -l app=kustomize-controller -f
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-controller-manager -f

# Verify no duplicate reconciliations
kubectl get replicationsource -A
# Should see only one instance per app
```

### Phase 4: Migrate Critical Apps (Week 3-4)
```bash
# Once confident, migrate critical apps
kubectl apply -f kubernetes/argocd/applications/network/
kubectl apply -f kubernetes/argocd/applications/storage/

# Verify VolSync resources created correctly
kubectl get replicationsource -A
kubectl get replicationdestination -A
```

### Phase 5: Decommission Flux (Week 5)
```bash
# Only after all apps migrated and verified
kubectl delete namespace flux-system
```

---

## Monitoring During Coexistence

### Check for Resource Conflicts
```bash
# Look for resources managed by both
kubectl get all -A -o json | \
  jq '.items[] | select(.metadata.ownerReferences | length > 1)'

# Check for duplicate resources
kubectl get replicationsource -A
# Should see each app only once
```

### Monitor Controller Logs
```bash
# Flux logs
kubectl logs -n flux-system -l app=kustomize-controller --tail=50

# ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-controller-manager --tail=50

# Look for errors or conflicts
```

### Check Webhook Activity
```bash
# Flux webhook logs
kubectl logs -n flux-system -l app=notification-controller --tail=50

# ArgoCD webhook logs (if configured)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=50
```

### Verify Resource Health
```bash
# Check all resources are healthy
kubectl get all -A --no-headers | grep -i error

# Check for pending resources
kubectl get all -A --no-headers | grep -i pending

# Check for failed reconciliations
kubectl get kustomizations -A
kubectl get applications -A
```

---

## Best Practices for Coexistence

### 1. Use Clear Naming Conventions
```yaml
# Flux resources
metadata:
  name: infrastructure-storage
  labels:
    managed-by: flux

# ArgoCD resources
metadata:
  name: sonarr
  labels:
    managed-by: argocd
```

### 2. Separate Git Paths
```
kubernetes/
├── flux/                    # Flux-managed resources
│   ├── cluster/
│   ├── meta/
│   └── repositories/
├── apps/                    # Shared app definitions
│   ├── media/
│   ├── network/
│   └── storage/
└── argocd/                  # ArgoCD-specific resources
    ├── applications/
    ├── applicationsets/
    └── projects/
```

### 3. Document Ownership
```yaml
# kubernetes/argocd/applications/media/sonarr.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sonarr
  namespace: argocd
  annotations:
    # Document that this is ArgoCD-managed
    managed-by: argocd
    migration-status: "in-progress"
    flux-equivalent: "kubernetes/apps/media/sonarr/ks.yaml"
```

### 4. Disable Flux Reconciliation During Migration
```bash
# Suspend Flux Kustomization for apps being migrated
kubectl patch kustomization sonarr -n media \
  -p '{"spec":{"suspend":true}}' --type merge

# Verify it's suspended
kubectl get kustomization sonarr -n media
# Should show: Suspended: True
```

### 5. Keep Rollback Capability
```bash
# Keep Flux running for 2 weeks after migration
# If ArgoCD has issues, you can quickly resume Flux

# Resume Flux if needed
kubectl patch kustomization sonarr -n media \
  -p '{"spec":{"suspend":false}}' --type merge
```

---

## Troubleshooting Coexistence Issues

### Resources Not Syncing
```bash
# Check if resource is managed by both
kubectl describe replicationsource sonarr -n media | grep -i owner

# Check ArgoCD Application status
argocd app get sonarr

# Check Flux Kustomization status
kubectl describe kustomization sonarr -n media
```

### Webhook Conflicts
```bash
# Check if both webhooks are firing
kubectl logs -n flux-system -l app=notification-controller | grep sonarr
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server | grep sonarr

# If both firing, suspend Flux webhook
kubectl patch receiver github-webhook -n flux-system \
  -p '{"spec":{"suspend":true}}' --type merge
```

### Resource Quota Issues
```bash
# Check resource usage
kubectl top nodes
kubectl top pods -n flux-system
kubectl top pods -n argocd

# If high, adjust resource limits
kubectl set resources deployment argocd-server -n argocd \
  --limits=cpu=500m,memory=512Mi
```

---

## Summary

✅ **Safe to run both side-by-side**
✅ **No CRD conflicts**
✅ **No namespace conflicts**
✅ **No webhook conflicts**
✅ **Standard migration pattern**
✅ **Easy to monitor and troubleshoot**

**Recommendation**: Start with non-critical apps, monitor for 24 hours, then migrate critical apps. Keep Flux running for 2 weeks post-migration as a rollback safety net.


