# How VolSync Components Work in ArgoCD - Direct Answer

## Your Question
> "The way Volsync is added to specific apps currently is via component includes in the kustomize. How will that work in Argo?"

## The Answer: It Works Perfectly ✅

Your component-based approach is **fully compatible with ArgoCD** with minimal changes.

---

## Current Flux Approach

```yaml
# kubernetes/apps/media/sonarr/ks.yaml (Flux Kustomization)
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: sonarr
spec:
  components:
    - ../../../../components/gatus/external
    - ../../../../components/volsync/ceph-rbd  # ← Component include
  path: ./kubernetes/apps/media/sonarr/app
  postBuild:
    substitute:
      APP: sonarr
      VOLSYNC_PUID: "568"
      VOLSYNC_PGID: "568"
```

This tells Flux to:
1. Include the `volsync/ceph-rbd` component
2. Substitute variables like `${APP}` → `sonarr`
3. Create ReplicationSource, ReplicationDestination, PVC, Secret

---

## ArgoCD Approach: Nearly Identical

```yaml
# kubernetes/argocd/applications/media/sonarr.yaml (ArgoCD Application)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sonarr
  namespace: argocd
spec:
  source:
    path: kubernetes/apps/media/sonarr/app
    kustomize:
      components:  # ← Same component include!
        - ../../../../components/gatus/external
        - ../../../../components/volsync/ceph-rbd
  destination:
    server: https://kubernetes.default.svc
    namespace: media
```

---

## The Key Difference: Variable Substitution

### Flux (postBuild.substitute)
```yaml
postBuild:
  substitute:
    APP: sonarr
    VOLSYNC_PUID: "568"
```

### ArgoCD (Kustomize vars)
```yaml
# kubernetes/apps/media/sonarr/app/kustomization.yaml
vars:
  - name: APP
    literal: sonarr
  - name: VOLSYNC_PUID
    literal: "568"
```

**That's it.** Move the variable definitions from Flux's `postBuild.substitute` to Kustomize's `vars:` field.

---

## What Needs to Change

### 1. Component Files
**No changes needed.** Keep all files as-is:
```
kubernetes/components/volsync/ceph-rbd/
├── kustomization.yaml
├── replicationsource.yaml
├── replicationdestination.yaml
├── pvc.yaml
└── secret.sops.yaml
```

### 2. App Kustomization Files
**Add `vars:` section** to each app's `kubernetes/apps/[namespace]/[app]/app/kustomization.yaml`:

```yaml
# Before (Flux only)
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: media
resources:
  - helmrelease.yaml
  - pvc.yaml
  - secret.sops.yaml

# After (Flux + ArgoCD compatible)
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: media
resources:
  - helmrelease.yaml
  - pvc.yaml
  - secret.sops.yaml

vars:
  - name: APP
    literal: sonarr
  - name: VOLSYNC_PUID
    literal: "568"
  - name: VOLSYNC_PGID
    literal: "568"
```

### 3. Create ArgoCD Applications
**Create new Application manifests** in `kubernetes/argocd/applications/`:

```yaml
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
```

---

## How It Works: Step-by-Step

```
1. ArgoCD reads Application manifest
   ↓
2. Sees: path: kubernetes/apps/media/sonarr/app
   ↓
3. Loads: kubernetes/apps/media/sonarr/app/kustomization.yaml
   ↓
4. Sees: vars: [APP: sonarr, VOLSYNC_PUID: 568]
   ↓
5. Includes component: ../../../../components/volsync/ceph-rbd
   ↓
6. Kustomize processes component files:
   - replicationsource.yaml: ${APP} → sonarr
   - secret.sops.yaml: ${APP}-volsync-secret → sonarr-volsync-secret
   - pvc.yaml: ${VOLSYNC_PUID} → 568
   ↓
7. ArgoCD SOPS plugin decrypts secret.sops.yaml
   ↓
8. Resources created:
   - ReplicationSource: sonarr
   - ReplicationDestination: sonarr-dst
   - PVC: sonarr-volsync-cache
   - Secret: sonarr-volsync-secret
```

---

## Apps That Need Updates

Find all apps with VolSync:
```bash
grep -l "volsync" kubernetes/apps/*/*/ks.yaml
```

Expected list:
- `kubernetes/apps/media/sonarr/ks.yaml`
- `kubernetes/apps/media/radarr/ks.yaml`
- `kubernetes/apps/media/tautulli/ks.yaml`
- `kubernetes/apps/media/sabnzbd/ks.yaml`
- `kubernetes/apps/media/bazarr/ks.yaml`
- `kubernetes/apps/media/huntarr/ks.yaml`
- `kubernetes/apps/network/technitium/ks.yaml`
- `kubernetes/apps/default/audiobookshelf/ks.yaml`

For each app:
1. Add `vars:` to `app/kustomization.yaml`
2. Create ArgoCD Application manifest

---

## Verification

After deploying via ArgoCD:

```bash
# Check ReplicationSource created
kubectl get replicationsource -A
# Expected: sonarr, radarr, tautulli, etc.

# Check variables substituted correctly
kubectl describe replicationsource sonarr -n media
# Look for: name: sonarr, sourcePVC: sonarr

# Check backup schedule active
kubectl get jobs -n media | grep volsync
# Expected: volsync-src-sonarr-* jobs running
```

---

## Summary

| Aspect | Flux | ArgoCD | Change Required |
|--------|------|--------|-----------------|
| Component inclusion | `components:` | `kustomize.components:` | ✅ Yes (in Application) |
| Variable substitution | `postBuild.substitute:` | `vars:` in kustomization.yaml | ✅ Yes (move to kustomization.yaml) |
| Component files | `kubernetes/components/volsync/` | Same | ❌ No |
| Result | ReplicationSource created | ReplicationSource created | ✅ Identical |

---

## Next Steps

1. **Read**: VOLSYNC_COMPONENTS_IN_ARGOCD.md (detailed explanation)
2. **Read**: ARGOCD_VOLSYNC_IMPLEMENTATION.md (step-by-step guide)
3. **Update**: Add `vars:` to each app's kustomization.yaml
4. **Create**: ArgoCD Application manifests
5. **Test**: Verify VolSync resources created
6. **Deploy**: Migrate apps in waves

---

## Key Takeaway

✅ **Your component-based approach works perfectly in ArgoCD**
✅ **No changes to component files needed**
✅ **Only move variable definitions to kustomization.yaml**
✅ **Same VolSync resources created as with Flux**
✅ **Backup/restore works identically**


