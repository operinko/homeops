# Parallel Migration: Running ArgoCD and Flux Together

## Your Situation

You want to migrate from Flux to ArgoCD but can't spin up a second cluster. **This is perfectly fine** - running both on the same cluster is the standard approach.

---

## Week-by-Week Plan

### Week 1: Install ArgoCD (Parallel with Flux)

#### Day 1-2: Install ArgoCD
```bash
# Create ArgoCD namespace
kubectl create namespace argocd

# Install ArgoCD (using your preferred method)
# Option A: Helm
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd

# Option B: Manifests
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Verify installation
kubectl get pods -n argocd
# Expected: argocd-server, argocd-repo-server, argocd-controller-manager, etc.

# Verify Flux still running
kubectl get pods -n flux-system
# Expected: source-controller, kustomize-controller, helm-controller, notification-controller
```

#### Day 3: Configure ArgoCD SOPS Plugin
```bash
# Create SOPS plugin ConfigMap
kubectl create configmap cmp-plugin -n argocd \
  --from-file=plugin.yaml=argocd-sops-plugin.yaml

# Mount age key in argocd-repo-server
kubectl patch deployment argocd-repo-server -n argocd \
  --type json -p='[
    {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {
      "name": "sops-age",
      "secret": {"secretName": "sops-age"}
    }},
    {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {
      "name": "sops-age",
      "mountPath": "/etc/sops/age"
    }}
  ]'

# Verify plugin loaded
kubectl logs -n argocd deployment/argocd-repo-server | grep -i sops
```

#### Day 4: Test ArgoCD with Non-Critical App
```bash
# Create a simple test Application
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: test-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/operinko/homeops.git
    targetRevision: main
    path: kubernetes/apps/tools/homepage/app
  destination:
    server: https://kubernetes.default.svc
    namespace: tools
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# Monitor sync
argocd app get test-app
argocd app logs test-app --follow

# Verify resource created
kubectl get deployment -n tools | grep homepage
```

#### Day 5: Verify No Conflicts
```bash
# Check both systems running
kubectl get pods -n flux-system
kubectl get pods -n argocd

# Check for resource conflicts
kubectl get events -A | grep -i conflict

# Check logs for errors
kubectl logs -n flux-system -l app=kustomize-controller --tail=20
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-controller-manager --tail=20

# Verify test app is healthy
kubectl get application test-app -n argocd
kubectl get deployment -n tools
```

---

### Week 2: Migrate Non-Critical Apps

#### Day 1-2: Migrate Tools Namespace
```bash
# Create ArgoCD Applications for tools
kubectl apply -f kubernetes/argocd/applications/tools/

# Monitor sync
argocd app list
argocd app get homepage
argocd app get headlamp

# Verify resources created
kubectl get all -n tools

# Check for conflicts
kubectl get events -n tools | grep -i conflict
```

#### Day 3: Migrate Media Stack (Non-Critical)
```bash
# Create ArgoCD Applications for media
kubectl apply -f kubernetes/argocd/applications/media/

# Monitor sync
argocd app list | grep media

# Verify VolSync resources created
kubectl get replicationsource -n media
kubectl get replicationdestination -n media

# Check backup jobs running
kubectl get jobs -n media | grep volsync

# Verify no conflicts
kubectl get events -n media | grep -i conflict
```

#### Day 4-5: Monitor and Verify
```bash
# Check all apps synced
argocd app list | grep -v Synced

# Verify backups running
kubectl get replicationsource -A
# Should see: sonarr, radarr, tautulli, etc.

# Check backup logs
kubectl logs -n media -l app.kubernetes.io/name=volsync -f

# Verify no duplicate resources
kubectl get replicationsource sonarr -n media -o yaml | grep -i owner
# Should show only ArgoCD as owner
```

---

### Week 3: Migrate Critical Apps

#### Day 1-2: Migrate Storage & Infrastructure
```bash
# Create ArgoCD Applications for storage
kubectl apply -f kubernetes/argocd/applications/storage/

# Monitor sync
argocd app list | grep storage

# Verify Ceph still healthy
kubectl get pods -n ceph-system
kubectl get cephcluster -n ceph-system

# Verify VolSync still working
kubectl get replicationsource -A
```

#### Day 3: Migrate Network (Technitium)
```bash
# CRITICAL: Technitium is DNS - be careful
# Verify backup is current first
kubectl get replicationsource technitium -n network -o yaml | grep lastScheduleTime

# Create ArgoCD Application
kubectl apply -f kubernetes/argocd/applications/network/technitium.yaml

# Monitor sync
argocd app get technitium

# Verify DNS still working
nslookup vaderrp.com 192.168.7.7
# Should resolve correctly

# Check backup running
kubectl get jobs -n network | grep volsync
```

#### Day 4-5: Verify Everything
```bash
# Check all critical apps synced
argocd app list | grep -E "technitium|ceph|volsync"

# Verify backups running
kubectl get replicationsource -A
kubectl get jobs -A | grep volsync

# Test backup/restore
kubectl patch replicationsource sonarr -n media \
  -p '{"spec":{"trigger":{"manual":"backup-now"}}}' \
  --type merge

# Monitor backup
kubectl logs -n media -l app.kubernetes.io/name=volsync -f

# Verify backup in MinIO
# Check s3://volsync/ for recent snapshots
```

---

### Week 4: Decommission Flux

#### Day 1-2: Suspend Flux
```bash
# Suspend all Flux Kustomizations
kubectl patch kustomization cluster-meta -n flux-system \
  -p '{"spec":{"suspend":true}}' --type merge

kubectl patch kustomization cluster-apps -n flux-system \
  -p '{"spec":{"suspend":true}}' --type merge

# Verify suspended
kubectl get kustomization -n flux-system
# Should show: Suspended: True
```

#### Day 3-4: Monitor ArgoCD
```bash
# Verify all apps still healthy under ArgoCD
argocd app list | grep -v Synced

# Check for any issues
kubectl get events -A | grep -i error

# Verify backups still running
kubectl get replicationsource -A
kubectl get jobs -A | grep volsync

# Test restore on non-critical app
kubectl patch replicationdestination sonarr-dst -n media \
  -p '{"spec":{"trigger":{"manual":"restore-once"}}}' \
  --type merge
```

#### Day 5: Remove Flux
```bash
# Only if everything is stable for 24+ hours

# Delete Flux namespace
kubectl delete namespace flux-system

# Delete Flux CRDs (optional, but clean)
kubectl delete crd \
  buckets.source.toolkit.fluxcd.io \
  gitrepositories.source.toolkit.fluxcd.io \
  helmcharts.source.toolkit.fluxcd.io \
  helmrepositories.source.toolkit.fluxcd.io \
  kustomizations.kustomize.toolkit.fluxcd.io \
  helmreleases.helm.toolkit.fluxcd.io \
  receivers.notification.toolkit.fluxcd.io

# Verify Flux removed
kubectl get pods -n flux-system
# Should error: namespace not found

# Verify ArgoCD still running
kubectl get pods -n argocd
# Should show all pods running
```

---

## Monitoring During Migration

### Daily Checks
```bash
# Check both systems running
kubectl get pods -n flux-system
kubectl get pods -n argocd

# Check for conflicts
kubectl get events -A | grep -i conflict

# Check controller logs
kubectl logs -n flux-system -l app=kustomize-controller --tail=20
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-controller-manager --tail=20

# Check VolSync backups
kubectl get replicationsource -A
kubectl get jobs -A | grep volsync
```

### Weekly Checks
```bash
# Verify all apps synced
argocd app list | grep -v Synced

# Check resource health
kubectl get all -A --no-headers | grep -i error

# Verify backups running
kubectl get replicationsource -A -o wide

# Test restore on non-critical app
kubectl patch replicationdestination sonarr-dst -n media \
  -p '{"spec":{"trigger":{"manual":"restore-once"}}}' \
  --type merge
```

---

## Rollback Plan

If something goes wrong:

```bash
# Resume Flux
kubectl patch kustomization cluster-meta -n flux-system \
  -p '{"spec":{"suspend":false}}' --type merge

kubectl patch kustomization cluster-apps -n flux-system \
  -p '{"spec":{"suspend":false}}' --type merge

# Verify Flux reconciling
kubectl get kustomization -n flux-system

# Delete ArgoCD Applications (optional)
kubectl delete applications -n argocd --all

# Verify Flux managing resources again
kubectl get all -A
```

---

## Key Points

✅ **Safe to run both side-by-side**
✅ **No resource conflicts**
✅ **Easy to monitor**
✅ **Easy to rollback**
✅ **Standard migration pattern**

**Recommendation**: Take your time, migrate non-critical apps first, monitor for 24 hours between waves, and keep Flux running as a safety net for 2 weeks after migration.


