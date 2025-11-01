# ArgoCD VolSync Implementation: Step-by-Step Guide

## Overview

Your VolSync components work perfectly in ArgoCD. The migration requires:
1. **No changes** to component files
2. **Minimal changes** to app kustomization.yaml files
3. **New** ArgoCD Application manifests

---

## Step 1: Understand Current Variable Usage

### Find all variables used in components

```bash
# Check what variables are used in VolSync components
grep -r '\${' kubernetes/components/volsync/

# Output will show:
# ${APP} - Application name
# ${VOLSYNC_COPYMETHOD:=Snapshot} - Copy method (default: Snapshot)
# ${VOLSYNC_SNAPSHOTCLASS:=csi-rbd-snapclass} - Snapshot class
# ${VOLSYNC_CACHE_CAPACITY:=5Gi} - Cache size
# ${VOLSYNC_CACHE_SNAPSHOTCLASS:=ceph-rbd} - Cache storage class
# ${VOLSYNC_CACHE_ACCESSMODES:=ReadWriteOnce} - Cache access mode
# ${VOLSYNC_STORAGECLASS:=ceph-rbd} - Storage class
# ${VOLSYNC_SNAP_ACCESSMODES:=ReadWriteOnce} - Snapshot access mode
# ${VOLSYNC_UID:=65534} - User ID
# ${VOLSYNC_GID:=65534} - Group ID
# ${VOLSYNC_PUID} - Pod user ID (app-specific)
# ${VOLSYNC_PGID} - Pod group ID (app-specific)
```

### Check current Flux substitutions

```bash
# See what each app currently substitutes
grep -A 10 "postBuild:" kubernetes/apps/*/*/ks.yaml | grep -A 5 "substitute:"

# Example output:
# kubernetes/apps/media/sonarr/ks.yaml:
#   VOLSYNC_PUID: "568"
#   VOLSYNC_PGID: "568"
```

---

## Step 2: Update App Kustomization Files

For each app with VolSync, add a `vars:` section to `kubernetes/apps/[namespace]/[app]/app/kustomization.yaml`.

### Example: Sonarr

**Before (Flux only):**
```yaml
# kubernetes/apps/media/sonarr/app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: media
resources:
  - helmrelease.yaml
  - pvc.yaml
  - secret.sops.yaml
  - httproute.yaml
  - lokirule.yaml
```

**After (Flux + ArgoCD compatible):**
```yaml
# kubernetes/apps/media/sonarr/app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: media
resources:
  - helmrelease.yaml
  - pvc.yaml
  - secret.sops.yaml
  - httproute.yaml
  - lokirule.yaml

# Variables for VolSync component substitution
vars:
  - name: APP
    literal: sonarr
  - name: VOLSYNC_PUID
    literal: "568"
  - name: VOLSYNC_PGID
    literal: "568"
  # Optional: override defaults if needed
  # - name: VOLSYNC_CACHE_CAPACITY
  #   literal: "10Gi"
```

### Example: Technitium (no PUID/PGID)

```yaml
# kubernetes/apps/network/technitium/app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: network
resources:
  - helmrelease.yaml
  - secret.sops.yaml

vars:
  - name: APP
    literal: technitium
  # Technitium doesn't need PUID/PGID override
```

### Apps to Update

Find all apps with VolSync:
```bash
grep -l "volsync" kubernetes/apps/*/*/ks.yaml

# Expected output:
# kubernetes/apps/media/sonarr/ks.yaml
# kubernetes/apps/media/radarr/ks.yaml
# kubernetes/apps/media/tautulli/ks.yaml
# kubernetes/apps/media/sabnzbd/ks.yaml
# kubernetes/apps/media/bazarr/ks.yaml
# kubernetes/apps/media/huntarr/ks.yaml
# kubernetes/apps/network/technitium/ks.yaml
# kubernetes/apps/default/audiobookshelf/ks.yaml
```

---

## Step 3: Create ArgoCD Applications

Create one Application per app with VolSync.

### Template

```yaml
# kubernetes/argocd/applications/[namespace]/[app].yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: [app]
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/operinko/homeops.git
    targetRevision: main
    path: kubernetes/apps/[namespace]/[app]/app
    kustomize:
      # Include the same components as Flux
      components:
        - ../../../../components/gatus/[external|guarded]
        - ../../../../components/volsync/ceph-rbd
  destination:
    server: https://kubernetes.default.svc
    namespace: [namespace]
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Example: Sonarr

```yaml
# kubernetes/argocd/applications/media/sonarr.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sonarr
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/operinko/homeops.git
    targetRevision: main
    path: kubernetes/apps/media/sonarr/app
    kustomize:
      components:
        - ../../../../components/gatus/external
        - ../../../../components/volsync/ceph-rbd
  destination:
    server: https://kubernetes.default.svc
    namespace: media
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Example: Technitium

```yaml
# kubernetes/argocd/applications/network/technitium.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: technitium
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/operinko/homeops.git
    targetRevision: main
    path: kubernetes/apps/network/technitium/app
    kustomize:
      components:
        - ../../../../components/gatus/guarded
        - ../../../../components/volsync/ceph-rbd
  destination:
    server: https://kubernetes.default.svc
    namespace: network
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## Step 4: Verify Variable Substitution

Test that variables are substituted correctly:

```bash
# Build kustomization locally to verify substitution
cd kubernetes/apps/media/sonarr/app
kustomize build . --enable-alpha-plugins

# Look for:
# - ReplicationSource with name: sonarr
# - Secret with name: sonarr-volsync-secret
# - PVC with correct storage class
# - Correct UID/GID in moverSecurityContext
```

### Expected Output

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: sonarr  # ✓ Substituted from ${APP}
spec:
  sourcePVC: sonarr  # ✓ Substituted from ${APP}
  restic:
    repository: sonarr-volsync-secret  # ✓ Substituted
    moverSecurityContext:
      runAsUser: 568  # ✓ Substituted from ${VOLSYNC_PUID}
      runAsGroup: 568  # ✓ Substituted from ${VOLSYNC_PGID}
---
apiVersion: v1
kind: Secret
metadata:
  name: sonarr-volsync-secret  # ✓ Substituted
```

---

## Step 5: Deploy via ArgoCD

### Option A: Manual Application Creation

```bash
# Create Application
kubectl apply -f kubernetes/argocd/applications/media/sonarr.yaml

# Monitor sync
argocd app get sonarr
argocd app logs sonarr --follow
```

### Option B: ApplicationSet (Recommended for Multiple Apps)

```yaml
# kubernetes/argocd/applicationsets/volsync-apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: volsync-apps
  namespace: argocd
spec:
  generators:
  - list:
      elements:
      - app: sonarr
        namespace: media
        gatus: external
      - app: radarr
        namespace: media
        gatus: external
      - app: tautulli
        namespace: media
        gatus: external
      - app: sabnzbd
        namespace: media
        gatus: external
      - app: bazarr
        namespace: media
        gatus: external
      - app: huntarr
        namespace: media
        gatus: external
      - app: technitium
        namespace: network
        gatus: guarded
      - app: audiobookshelf
        namespace: default
        gatus: external
  template:
    metadata:
      name: '{{app}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/operinko/homeops.git
        targetRevision: main
        path: 'kubernetes/apps/{{namespace}}/{{app}}/app'
        kustomize:
          components:
            - '../../../../components/gatus/{{gatus}}'
            - '../../../../components/volsync/ceph-rbd'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{namespace}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

---

## Step 6: Verify VolSync Resources

After ArgoCD deploys:

```bash
# Check ReplicationSource created
kubectl get replicationsource -A
# Expected: sonarr, radarr, tautulli, etc.

# Check ReplicationDestination created
kubectl get replicationdestination -A
# Expected: sonarr-dst, radarr-dst, etc.

# Check backup schedule active
kubectl describe replicationsource sonarr -n media
# Look for: "Last sync time", "Next sync time"

# Check backup job running
kubectl get jobs -n media | grep volsync
# Expected: volsync-src-sonarr-* jobs

# Verify secret created
kubectl get secret sonarr-volsync-secret -n media
# Expected: Secret with S3 credentials
```

---

## Step 7: Test Backup/Restore

```bash
# Trigger manual backup
kubectl patch replicationsource sonarr -n media \
  -p '{"spec":{"trigger":{"manual":"backup-now"}}}' \
  --type merge

# Monitor backup job
kubectl logs -n media -l app.kubernetes.io/name=volsync -f

# Verify backup in MinIO
# Check s3://volsync/sonarr/ for recent snapshots

# Test restore (on non-critical app first)
kubectl patch replicationdestination sonarr-dst -n media \
  -p '{"spec":{"trigger":{"manual":"restore-once"}}}' \
  --type merge

# Monitor restore job
kubectl logs -n media -l app.kubernetes.io/name=volsync -f
```

---

## Troubleshooting

### Variables Not Substituted

```bash
# Check if vars are defined
grep -A 20 "^vars:" kubernetes/apps/media/sonarr/app/kustomization.yaml

# Verify kustomize can build
kustomize build kubernetes/apps/media/sonarr/app

# Check ArgoCD logs
kubectl logs -n argocd deployment/argocd-repo-server | grep -i sonarr
```

### ReplicationSource Not Created

```bash
# Check Application sync status
argocd app get sonarr

# Check for errors
kubectl describe application sonarr -n argocd

# Check kustomize build output
argocd app manifests sonarr | grep -A 10 "ReplicationSource"
```

### SOPS Decryption Failing

```bash
# Verify SOPS plugin configured
kubectl get configmap cmp-plugin -n argocd

# Check age key mounted
kubectl exec -it deployment/argocd-repo-server -n argocd -- \
  ls -la /etc/sops/age/

# Test SOPS decryption
kubectl exec -it deployment/argocd-repo-server -n argocd -- \
  sops -d kubernetes/components/volsync/ceph-rbd/secret.sops.yaml
```

---

## Summary

✅ **No changes to component files needed**
✅ **Add `vars:` to app kustomization.yaml**
✅ **Create ArgoCD Application with `kustomize.components:`**
✅ **Same VolSync resources created as with Flux**
✅ **Backup/restore works identically**


