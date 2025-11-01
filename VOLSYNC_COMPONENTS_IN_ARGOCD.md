# VolSync Components in ArgoCD: Detailed Implementation Guide

## Current Flux Approach

Your current setup uses Kustomize components to add VolSync to applications:

```yaml
# kubernetes/apps/media/sonarr/ks.yaml (Flux Kustomization)
components:
  - ../../../../components/gatus/external
  - ../../../../components/volsync/ceph-rbd
```

This tells Flux to include the `ceph-rbd` component, which contains:
- `replicationsource.yaml` - Hourly backup schedule
- `replicationdestination.yaml` - Manual restore capability
- `pvc.yaml` - PVC for backup cache
- `secret.sops.yaml` - S3 credentials (encrypted)

The component uses **variable substitution** for app-specific values:
```yaml
metadata:
  name: "${APP}"  # Substituted from postBuild.substitute
spec:
  sourcePVC: "${APP}"
  moverSecurityContext:
    runAsUser: "${VOLSYNC_UID:=65534}"
    runAsGroup: "${VOLSYNC_GID:=65534}"
```

---

## How ArgoCD Handles Kustomize Components

**Good news**: ArgoCD has **native support for Kustomize components** via the `kustomize.components` field.

### ArgoCD Application with Components

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
      # This is the key - specify components here
      components:
        - ../../../../components/gatus/external
        - ../../../../components/volsync/ceph-rbd
      # Variable substitution (replaces Flux postBuild.substitute)
      commonLabels:
        app.kubernetes.io/name: sonarr
  destination:
    server: https://kubernetes.default.svc
    namespace: media
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## Variable Substitution: Flux vs ArgoCD

### Flux Approach (postBuild.substitute)
```yaml
# kubernetes/apps/media/sonarr/ks.yaml
postBuild:
  substitute:
    APP: sonarr
    VOLSYNC_PUID: "568"
    VOLSYNC_PGID: "568"
```

### ArgoCD Approach (Multiple Options)

#### Option 1: Kustomize vars (Recommended)
```yaml
# kubernetes/apps/media/sonarr/app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
  - pvc.yaml
  - secret.sops.yaml
  - httproute.yaml

# Define variables for substitution
vars:
  - name: APP
    objref:
      kind: Deployment
      name: sonarr
      apiVersion: apps/v1
    fieldref:
      fieldpath: metadata.labels.app.kubernetes.io/name
  - name: VOLSYNC_PUID
    literal: "568"
  - name: VOLSYNC_PGID
    literal: "568"
```

#### Option 2: ArgoCD Application values
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sonarr
spec:
  source:
    path: kubernetes/apps/media/sonarr/app
    kustomize:
      # Pass variables to kustomize
      commonLabels:
        app.kubernetes.io/name: sonarr
      # For more complex substitution, use patches
```

#### Option 3: ConfigMap-based (Most Flexible)
```yaml
# kubernetes/apps/media/sonarr/app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
  - pvc.yaml
  - secret.sops.yaml

configMapGenerator:
  - name: sonarr-vars
    literals:
      - APP=sonarr
      - VOLSYNC_PUID=568
      - VOLSYNC_PGID=568

# Then reference in components via replacements
replacements:
  - source:
      kind: ConfigMap
      name: sonarr-vars
      fieldPath: data.APP
    targets:
      - select:
          kind: ReplicationSource
        fieldPath: metadata.name
```

---

## Recommended Migration Strategy

### Step 1: Keep Existing Component Structure
Your component structure is perfect - no changes needed:
```
kubernetes/components/volsync/
├── ceph-rbd/
│   ├── kustomization.yaml
│   ├── replicationsource.yaml
│   ├── replicationdestination.yaml
│   ├── pvc.yaml
│   └── secret.sops.yaml
├── nfs-csi/
├── s3/
└── ... (other backends)
```

### Step 2: Update Application kustomization.yaml
Add variables to each app's kustomization:

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

# Define variables for VolSync component
vars:
  - name: APP
    literal: sonarr
  - name: VOLSYNC_PUID
    literal: "568"
  - name: VOLSYNC_PGID
    literal: "568"
  - name: VOLSYNC_UID
    literal: "568"
  - name: VOLSYNC_GID
    literal: "568"
```

### Step 3: Create ArgoCD Application
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
      # Include the same components as Flux
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

---

## How It Works: Step-by-Step

### 1. ArgoCD Reads Application
```yaml
path: kubernetes/apps/media/sonarr/app
components:
  - ../../../../components/volsync/ceph-rbd
```

### 2. Kustomize Processes Components
- Loads `kubernetes/apps/media/sonarr/app/kustomization.yaml`
- Includes component `kubernetes/components/volsync/ceph-rbd/kustomization.yaml`
- Component resources are merged

### 3. Variable Substitution
- `${APP}` → `sonarr` (from vars)
- `${VOLSYNC_PUID}` → `568` (from vars)
- `${VOLSYNC_UID:=65534}` → `568` (from vars, overrides default)

### 4. SOPS Decryption
- ArgoCD SOPS plugin decrypts `secret.sops.yaml`
- Credentials injected into Secret

### 5. Resources Created
- ReplicationSource: `sonarr` (with hourly schedule)
- ReplicationDestination: `sonarr-dst` (for manual restore)
- PVC: `sonarr-volsync-cache` (for backup staging)
- Secret: `sonarr-volsync-secret` (S3 credentials)

---

## Comparison: Flux vs ArgoCD

| Aspect | Flux | ArgoCD |
|--------|------|--------|
| **Component inclusion** | `components:` in Kustomization | `kustomize.components:` in Application |
| **Variable substitution** | `postBuild.substitute:` | `vars:` in kustomization.yaml |
| **Default values** | `${VAR:=default}` | `${VAR:=default}` (same) |
| **SOPS decryption** | Native support | Via plugin |
| **Result** | Identical resources | Identical resources |

---

## Migration Checklist for VolSync Components

- [ ] **No changes to component files needed**
  - `kubernetes/components/volsync/*/` stays as-is
  - All variable substitution syntax compatible

- [ ] **Update app kustomization.yaml**
  - Add `vars:` section with app-specific values
  - Keep existing resources

- [ ] **Create ArgoCD Application**
  - Specify `kustomize.components:` field
  - Include same components as Flux

- [ ] **Test variable substitution**
  ```bash
  # Verify variables are substituted correctly
  kustomize build kubernetes/apps/media/sonarr/app \
    --enable-alpha-plugins
  ```

- [ ] **Verify SOPS decryption**
  - Ensure ArgoCD SOPS plugin configured
  - Test secret decryption

- [ ] **Deploy and verify**
  - Check ReplicationSource created
  - Check ReplicationDestination created
  - Verify backup schedule active

---

## Example: Complete Migration for Sonarr

### Before (Flux)
```yaml
# kubernetes/apps/media/sonarr/ks.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: sonarr
  namespace: media
spec:
  components:
    - ../../../../components/gatus/external
    - ../../../../components/volsync/ceph-rbd
  path: ./kubernetes/apps/media/sonarr/app
  postBuild:
    substitute:
      APP: sonarr
      VOLSYNC_PUID: "568"
      VOLSYNC_PGID: "568"
```

### After (ArgoCD)
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
```

### Updated kustomization.yaml
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

vars:
  - name: APP
    literal: sonarr
  - name: VOLSYNC_PUID
    literal: "568"
  - name: VOLSYNC_PGID
    literal: "568"
  - name: VOLSYNC_UID
    literal: "568"
  - name: VOLSYNC_GID
    literal: "568"
```

---

## Key Takeaway

**Your component-based approach works identically in ArgoCD.**

The only change needed is moving variable definitions from Flux's `postBuild.substitute` to Kustomize's `vars:` field. This is a **one-time, straightforward change** that makes the setup more portable and GitOps-tool-agnostic.


