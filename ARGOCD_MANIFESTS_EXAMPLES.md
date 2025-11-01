# ArgoCD Manifest Examples for Migration

This document provides concrete YAML examples for converting your Flux setup to ArgoCD.

---

## 1. Basic Application (Non-VolSync)

### Flux Version
```yaml
# kubernetes/apps/tools/headlamp/ks.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: headlamp
  namespace: tools
spec:
  dependsOn:
    - name: ingress-nginx
      namespace: kube-system
  targetNamespace: tools
  path: ./kubernetes/apps/tools/headlamp/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
```

### ArgoCD Version
```yaml
# kubernetes/argocd/applications/tools/headlamp.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: headlamp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/operinko/homeops.git
    targetRevision: main
    path: kubernetes/apps/tools/headlamp/app
  destination:
    server: https://kubernetes.default.svc
    namespace: tools
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
  # Dependency: ingress-nginx must be deployed first
  info:
    - name: 'Dependencies'
      value: 'ingress-nginx (kube-system)'
```

---

## 2. Application with VolSync (Ceph RBD)

### Flux Version
```yaml
# kubernetes/apps/network/technitium/ks.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: technitium
  namespace: network
spec:
  dependsOn:
    - name: ceph-csi
      namespace: storage
    - name: volsync
      namespace: storage
  components:
    - ../../../../components/gatus/guarded
    - ../../../../components/volsync/ceph-rbd
  path: ./kubernetes/apps/network/technitium/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  postBuild:
    substitute:
      APP: technitium
```

### ArgoCD Version
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
      commonLabels:
        app.kubernetes.io/name: technitium
  destination:
    server: https://kubernetes.default.svc
    namespace: network
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
  info:
    - name: 'Dependencies'
      value: 'ceph-csi, volsync (storage namespace)'
    - name: 'VolSync'
      value: 'Enabled - Ceph RBD backend'
```

---

## 3. Helm Release with SOPS Secrets

### Flux Version
```yaml
# kubernetes/apps/network/crowdsec/app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./secret.sops.yaml
  - ./helmrelease.yaml
```

### ArgoCD Version (with SOPS plugin)
```yaml
# kubernetes/argocd/applications/network/crowdsec.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crowdsec
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/operinko/homeops.git
    targetRevision: main
    path: kubernetes/apps/network/crowdsec/app
    plugin:
      name: sops
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

## 4. ApplicationSet for Multiple Apps (Media Stack)

```yaml
# kubernetes/argocd/applicationsets/media.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: media-apps
  namespace: argocd
spec:
  generators:
  - list:
      elements:
      - app: sonarr
        volsync: true
      - app: radarr
        volsync: true
      - app: prowlarr
        volsync: false
      - app: tautulli
        volsync: true
      - app: sabnzbd
        volsync: true
      - app: bazarr
        volsync: true
      - app: huntarr
        volsync: true
  template:
    metadata:
      name: '{{app}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/operinko/homeops.git
        targetRevision: main
        path: 'kubernetes/apps/media/{{app}}/app'
        kustomize:
          components:
            - '../../../../components/gatus/guarded'
            - '{{#if volsync}}../../../../components/volsync/ceph-rbd{{/if}}'
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

## 5. Infrastructure Layer (Storage)

```yaml
# kubernetes/argocd/applications/storage/volsync.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: volsync
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/operinko/homeops.git
    targetRevision: main
    path: kubernetes/apps/storage/volsync/app
  destination:
    server: https://kubernetes.default.svc
    namespace: storage
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
  info:
    - name: 'Mutators'
      value: 'volsync-mover-jitter, volsync-mover-nfs'
    - name: 'Documentation'
      value: 'https://backube.github.io/volsync/'
```

---

## 6. Root Application (AppOfApps Pattern)

```yaml
# kubernetes/argocd/applications/root.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/operinko/homeops.git
    targetRevision: main
    path: kubernetes/argocd/applications
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## 7. SOPS Plugin Configuration

```yaml
# kubernetes/argocd/plugins/sops-plugin.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cmp-plugin
  namespace: argocd
data:
  sops.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: sops
    spec:
      version: 1.0
      generate:
        command: [sh, -c]
        args: ["sops -d $ARGOCD_ENV_FILE | kustomize build"]
```

---

## 8. ArgoCD Repo Server with SOPS

```yaml
# kubernetes/argocd/patches/repo-server-sops.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-repo-server
  namespace: argocd
spec:
  template:
    spec:
      containers:
      - name: argocd-repo-server
        env:
        - name: SOPS_AGE_KEY_FILE
          value: /etc/sops/age/keys.txt
        volumeMounts:
        - name: sops-age
          mountPath: /etc/sops/age
          readOnly: true
        - name: cmp-plugin
          mountPath: /home/argocd/cmp-server/plugins
          readOnly: true
      volumes:
      - name: sops-age
        secret:
          secretName: sops-age
      - name: cmp-plugin
        configMap:
          name: cmp-plugin
```

---

## 9. Directory Structure

```
kubernetes/argocd/
├── applications/
│   ├── root.yaml                    # Root app (AppOfApps)
│   ├── storage/
│   │   ├── ceph-csi.yaml
│   │   ├── snapshot-controller.yaml
│   │   └── volsync.yaml
│   ├── network/
│   │   ├── external-dns.yaml
│   │   ├── technitium.yaml
│   │   └── crowdsec.yaml
│   ├── media/
│   │   ├── sonarr.yaml
│   │   ├── radarr.yaml
│   │   └── ... (other media apps)
│   └── ... (other namespaces)
├── applicationsets/
│   ├── media.yaml
│   └── ... (other sets)
├── plugins/
│   └── sops-plugin.yaml
└── patches/
    └── repo-server-sops.yaml
```

---

## 10. Migration Script Template

```bash
#!/bin/bash
# migrate-app.sh - Migrate single app from Flux to ArgoCD

set -euo pipefail

APP=${1:?App name required}
NAMESPACE=${2:?Namespace required}

echo "Migrating $APP in $NAMESPACE..."

# 1. Create ArgoCD Application
kubectl apply -f "kubernetes/argocd/applications/$NAMESPACE/$APP.yaml"

# 2. Wait for sync
kubectl wait application/$APP -n argocd \
  --for=condition=Synced --timeout=5m

# 3. Verify pods running
kubectl wait pods -n $NAMESPACE \
  -l app.kubernetes.io/name=$APP \
  --for=condition=Ready --timeout=5m

# 4. Disable Flux Kustomization
flux suspend kustomization $APP -n $NAMESPACE

# 5. Monitor for 24 hours (manual step)
echo "✓ $APP migrated. Monitor for 24 hours before cleanup."
```

---

## Key Differences: Flux → ArgoCD

| Aspect | Flux | ArgoCD |
|--------|------|--------|
| **Dependency** | `dependsOn` | `info` field (informational) |
| **Kustomize** | Native support | Via `kustomize` field |
| **Patches** | `patches` field | Kustomize components |
| **Substitution** | `postBuild.substitute` | Kustomize vars |
| **Sync** | Automatic (interval) | Automatic (webhook) |
| **Pruning** | `prune: true` | `syncPolicy.prune` |


