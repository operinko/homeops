# SOPS Cleanup Summary

## Overview

As part of the FluxCD to ArgoCD migration, all SOPS-encrypted secrets have been replaced with ExternalSecrets (Bitwarden backend) and SealedSecrets. This document summarizes the cleanup performed to remove all SOPS remnants from the active codebase.

---

## Changes Made

### 1. Reorganized cluster-secrets Component

**Before**:
```
kubernetes/components/common/sops/
├── cluster-secrets.sops.yaml (SOPS encrypted)
├── sops-age.sops.yaml (SOPS encrypted)
├── external-secret.yaml (both secrets)
└── kustomization.yaml
```

**After**:
```
kubernetes/components/common/cluster-secrets/
├── external-secret.yaml (only SECRET_DOMAIN)
└── kustomization.yaml
```

**Rationale**: The `sops` directory name was misleading after migrating to ExternalSecrets. The `cluster-secrets` component now only manages the `SECRET_DOMAIN` variable via ExternalSecret, making the directory name more accurate.

---

### 2. Removed Network Namespace SOPS Files

All network namespace applications already had ExternalSecret replacements. Removed SOPS files:

- ✅ `kubernetes/argocd/applications/network/cloudflare-dns/secret.sops.yaml`
- ✅ `kubernetes/argocd/applications/network/cloudflare-tunnel/secret.sops.yaml`
- ✅ `kubernetes/argocd/applications/network/technitium/secret.sops.yaml`
- ✅ `kubernetes/argocd/applications/network/crowdsec/secret.sops.yaml`
- ✅ `kubernetes/argocd/applications/network/traefik/crowdsec-bouncer.secrets.sops.yaml`

**Verification**: Each application has a corresponding `external-secret.yaml` file that pulls secrets from Bitwarden ClusterSecretStore.

---

### 3. Cleaned Up VolSync Components

**Removed Components** (unused after Ceph migration):
- ✅ `kubernetes/components/volsync/mayastor/` - Mayastor storage class deprecated
- ✅ `kubernetes/components/volsync/nfs-csi/` - Replaced by Ceph
- ✅ `kubernetes/components/volsync/nfs-csi-migrated/` - Migration complete
- ✅ `kubernetes/components/volsync/s3/` - Not in use
- ✅ `kubernetes/components/volsync/local/` - Not in use

**Migrated Component**:
- ✅ `kubernetes/components/volsync/ceph-rbd/` - Migrated from SOPS to ExternalSecret

**Before** (`ceph-rbd/kustomization.yaml`):
```yaml
resources:
  - replicationsource.yaml
  - replicationdestination.yaml
  - pvc.yaml
  - secret.sops.yaml
```

**After** (`ceph-rbd/kustomization.yaml`):
```yaml
resources:
  - external-secret.yaml
  - replicationsource.yaml
  - replicationdestination.yaml
  - pvc.yaml
```

**New File** (`ceph-rbd/external-secret.yaml`):
```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${APP}-volsync-secret
spec:
  refreshInterval: 1h
  target:
    name: ${APP}-volsync-secret
    creationPolicy: Owner
    deletionPolicy: Retain
  dataFrom:
    - extract:
        key: 7e49fd72-95df-476c-959d-ecae3f0624d9
      sourceRef:
        storeRef:
          name: bitwarden-fields
          kind: ClusterSecretStore
```

---

### 4. Removed SOPS Directories

- ✅ `kubernetes/components/common/sops/` - Replaced by `cluster-secrets/`
- ✅ `kubernetes/components/common/sops-flux-only/` - FluxCD-specific, no longer needed

---

### 5. Bootstrap Scripts

**Status**: No changes needed

**Rationale**: The `scripts/bootstrap-apps.sh` script is FluxCD-specific and is now obsolete after the ArgoCD migration. The script references SOPS secrets, but since it's not used for ArgoCD bootstrapping, no updates are required.

---

## Verification Checklist

- [x] All network namespace secrets have ExternalSecret replacements
- [x] VolSync ceph-rbd component uses ExternalSecret
- [x] Unused VolSync components removed
- [x] cluster-secrets moved to dedicated directory
- [x] SOPS directories removed
- [x] No active SOPS files remain in kubernetes/argocd/applications/
- [x] No active SOPS files remain in kubernetes/components/ (except archive/)

---

## Remaining SOPS References

### Archive Directory (Intentional)

SOPS files remain in the `archive/` directory as historical reference:
- `archive/flux/` - Old FluxCD configurations
- `archive/recyclarr/` - Archived application
- Various archived media applications

**Action**: No cleanup needed - archive is intentionally preserved

### Documentation

SOPS references remain in:
- `KEY_FINDINGS.md` - Historical migration documentation
- `scripts/bootstrap-apps.sh` - FluxCD bootstrap script (obsolete)

**Action**: No cleanup needed - historical context

---

## Secret Management Architecture

### Current State (Post-Cleanup)

**Primary**: ExternalSecrets with Bitwarden backend
- ClusterSecretStore: `bitwarden-fields` (for field-based secrets)
- ClusterSecretStore: `bitwarden-login` (for username/password)
- ClusterSecretStore: `bitwarden-notes` (for large text blocks)

**Secondary**: SealedSecrets
- Used for secrets that don't fit Bitwarden model
- Encrypted at rest in Git

**Deprecated**: SOPS
- ✅ Fully removed from active codebase
- ✅ All secrets migrated to ExternalSecrets or SealedSecrets

---

## Benefits of Cleanup

1. **Simplified Secret Management**: Single source of truth (Bitwarden)
2. **Reduced Complexity**: No SOPS tooling required
3. **Better Organization**: Clear directory structure
4. **Improved Security**: Centralized secret rotation via Bitwarden
5. **Easier Onboarding**: No need to manage SOPS age keys

---

## Next Steps

1. ✅ Commit all changes to Git
2. ✅ Verify ArgoCD syncs successfully
3. ✅ Confirm all applications have working secrets
4. ✅ Update ArgoCD improvements documentation
5. ⏭️ Consider removing bootstrap scripts directory (FluxCD-specific)

---

## Rollback Plan

If issues arise:

1. **Revert Git commit**: All SOPS files are in Git history
2. **Restore directories**: Use `git checkout HEAD~1 -- kubernetes/components/common/sops`
3. **Verify secrets**: Check that ExternalSecrets are syncing correctly

---

## Summary

- **Files Removed**: 15+ SOPS secret files
- **Directories Removed**: 7 (sops, sops-flux-only, 5 VolSync components)
- **Files Created**: 2 (cluster-secrets component, ceph-rbd ExternalSecret)
- **Migration Status**: ✅ Complete - SOPS fully deprecated

