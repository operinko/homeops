# VolSync Mutator Implementation Guide for ArgoCD

## Overview

This guide explains how to preserve and implement your VolSync MutatingAdmissionPolicies in ArgoCD, ensuring zero data loss during migration.

---

## Current VolSync Mutator Architecture

### What Are These Mutators?

Your cluster uses two MutatingAdmissionPolicies (Kubernetes 1.32+ feature) that automatically modify VolSync jobs:

1. **Jitter Mutator** - Prevents backup thundering herd
2. **NFS Repository Mutator** - Injects TrueNAS NFS mount for backup staging

These are **cluster-level policies** that work independently of the GitOps tool.

### Why They're Critical

- **Jitter**: Without it, all hourly backups start simultaneously, causing resource spikes
- **NFS Repository**: VolSync jobs need access to `/repository` for staging backups before uploading to MinIO

---

## Migration Approach: Direct Kubernetes Resources

### Why This Works

MutatingAdmissionPolicies are standard Kubernetes resources. They don't depend on Flux-specific features like:
- Kustomize patches
- Flux notifications
- Flux reconciliation

**Result**: They work identically under ArgoCD.

### Implementation Steps

#### Step 1: Verify Current Mutators

```bash
# Check existing mutators
kubectl get mutatingadmissionpolicies
kubectl get mutatingadmissionpolicybindings

# Inspect details
kubectl describe map volsync-mover-jitter
kubectl describe map volsync-mover-nfs
```

#### Step 2: Create ArgoCD Application for VolSync

Create `kubernetes/apps/storage/volsync/ks.yaml` (ArgoCD Application):

```yaml
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
  # Ensure VolSync deploys before dependent apps
  info:
    - name: 'Documentation'
      value: 'https://backube.github.io/volsync/'
```

#### Step 3: Verify Mutator Manifests

Your existing `kubernetes/apps/storage/volsync/app/mutatingadmissionpolicy.yaml` is already in the correct format. No changes needed.

**Key points:**
- Mutators are in `volsync-system` namespace (created by Helm chart)
- Policies use CEL expressions for matching
- Mutations use JSONPatch format

#### Step 4: Test Mutator Functionality

After ArgoCD deploys VolSync:

```bash
# 1. Verify mutators are present
kubectl get mutatingadmissionpolicies -n volsync-system

# 2. Create a test VolSync job
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: test-volsync-job
  namespace: storage
  labels:
    app.kubernetes.io/created-by: volsync
spec:
  template:
    metadata:
      labels:
        app.kubernetes.io/created-by: volsync
    spec:
      containers:
      - name: test
        image: busybox:latest
        command: ["sleep", "10"]
      restartPolicy: Never
EOF

# 3. Check if jitter init container was injected
kubectl get job test-volsync-job -n storage -o yaml | grep -A 5 "initContainers"

# 4. Verify NFS volume was injected (if applicable)
kubectl get job test-volsync-job -n storage -o yaml | grep -A 10 "volumes"

# 5. Clean up
kubectl delete job test-volsync-job -n storage
```

---

## Handling VolSync-Enabled Applications

### Application Dependencies

Applications using VolSync must declare dependency on VolSync:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: technitium
  namespace: argocd
spec:
  # ... other fields ...
  
  # Ensure VolSync is deployed first
  info:
    - name: 'Dependencies'
      value: 'volsync (storage namespace)'
```

### Component-Based Approach

Your current Kustomize components should be converted to ArgoCD ApplicationSets:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: volsync-apps
  namespace: argocd
spec:
  generators:
  - list:
      elements:
      - app: technitium
        namespace: network
        component: ceph-rbd
      - app: huntarr
        namespace: media
        component: ceph-rbd
      - app: audiobookshelf
        namespace: default
        component: ceph-rbd
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
          - '../../../../components/volsync/{{component}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{namespace}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

---

## SOPS Integration with VolSync Secrets

### Current Setup

VolSync secrets are encrypted with SOPS (age-based):

```yaml
# kubernetes/components/volsync/ceph-rbd/secret.sops.yaml
apiVersion: v1
kind: Secret
metadata:
  name: ${APP}-volsync-secret
stringData:
  RESTIC_REPOSITORY: s3:https://minio.vaderrp.com:9000/volsync/${APP}
  RESTIC_PASSWORD: [encrypted]
  AWS_ACCESS_KEY_ID: [encrypted]
  # ... other S3 credentials
```

### ArgoCD SOPS Plugin Configuration

1. **Create SOPS plugin ConfigMap** in argocd namespace:

```yaml
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

2. **Mount age key in argocd-repo-server**:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sops-age
  namespace: argocd
type: Opaque
data:
  age.agekey: [base64-encoded age key]
---
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
      volumes:
      - name: sops-age
        secret:
          secretName: sops-age
```

---

## Backup & Restore Verification

### Pre-Migration Backup

Before starting migration:

```bash
# Trigger manual backup for all VolSync apps
for app in technitium huntarr audiobookshelf; do
  kubectl patch replicationsource $app -n storage \
    -p '{"spec":{"trigger":{"manual":"backup-now"}}}' \
    --type merge
done

# Wait for backups to complete
kubectl wait replicationsource --all -n storage \
  --for=condition=Completed --timeout=120m
```

### Post-Migration Restore Test

After ArgoCD deployment:

```bash
# 1. Verify VolSync is running
kubectl get pods -n volsync-system

# 2. Check ReplicationSource status
kubectl get replicationsource -A

# 3. Trigger test backup
kubectl patch replicationsource audiobookshelf -n default \
  -p '{"spec":{"trigger":{"manual":"backup-now"}}}' \
  --type merge

# 4. Monitor backup job
kubectl logs -n default -l app.kubernetes.io/name=volsync -f

# 5. Verify backup in MinIO
# Check s3://volsync/audiobookshelf/ for recent snapshots
```

---

## Troubleshooting

### Mutators Not Injecting

```bash
# Check mutator status
kubectl get mutatingadmissionpolicies -o yaml

# Check policy binding
kubectl get mutatingadmissionpolicybindings -o yaml

# Check CEL expressions
kubectl describe map volsync-mover-jitter

# Test with debug job
kubectl apply -f test-job.yaml
kubectl get job test-job -o yaml | grep -i "jitter\|repository"
```

### SOPS Decryption Failures

```bash
# Verify age key is mounted
kubectl exec -it deployment/argocd-repo-server -n argocd -- \
  ls -la /etc/sops/age/

# Test SOPS decryption
kubectl exec -it deployment/argocd-repo-server -n argocd -- \
  sops -d /path/to/secret.sops.yaml

# Check ArgoCD logs
kubectl logs -n argocd deployment/argocd-repo-server | grep -i sops
```

### VolSync Jobs Failing

```bash
# Check VolSync controller logs
kubectl logs -n volsync-system deployment/volsync -f

# Inspect failed job
kubectl describe job volsync-src-[app]-[timestamp] -n [namespace]

# Check mover pod logs
kubectl logs -n [namespace] pod/volsync-src-[app]-[timestamp]-xxxxx
```

---

## Success Criteria

✅ MutatingAdmissionPolicies present and active
✅ Jitter init container injected into VolSync jobs
✅ NFS repository volume mounted in VolSync jobs
✅ Backup jobs complete successfully
✅ Restore test passes with data integrity verified
✅ All VolSync-enabled apps running under ArgoCD
✅ No data loss during migration


