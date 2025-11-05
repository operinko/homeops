# Media ApplicationSet Migration - Before & After

This document shows the transformation from individual Application manifests to ApplicationSet.

---

## Current State (Before)

### File Structure
```
kubernetes/argocd/applications/media/
├── kustomization.yaml (38 lines)
├── media-namespace.yaml
├── bazarr.yaml
├── bazarr-resources.yaml
├── bazarr/
│   ├── external-secret.yaml
│   ├── httproute.yaml
│   └── volsync.yaml
├── sonarr.yaml
├── sonarr-resources.yaml
├── sonarr/
│   ├── external-secret.yaml
│   ├── httproute.yaml
│   └── volsync.yaml
├── radarr.yaml
├── radarr-resources.yaml
├── radarr/
│   ├── external-secret.yaml
│   ├── httproute.yaml
│   └── volsync.yaml
... (10 more apps with same pattern)
```

### Statistics
- **Total files**: 26 Application manifests (13 apps × 2 files each)
- **Lines of YAML**: ~3,000 lines
- **Repetition**: Very high - same chart, version, patterns
- **Maintenance**: Update chart version in 13 places

### Example: sonarr.yaml (Current)
```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sonarr
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: media
  source:
    repoURL: https://bjw-s-labs.github.io/helm-charts
    chart: app-template
    targetRevision: 4.4.0  # Repeated 13 times!
    helm:
      valuesObject:
        controllers:
          sonarr:
            # ... 100+ lines of values ...
  destination:
    server: https://kubernetes.default.svc
    namespace: media
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
```

---

## Proposed State (After)

### File Structure
```
kubernetes/argocd/applications/media/
├── kustomization.yaml (simplified)
├── media-namespace.yaml
├── media-apps.applicationset.yaml (ONE file for all apps!)
└── apps/
    ├── bazarr/
    │   ├── config.yaml (app-specific values)
    │   └── resources/
    │       ├── external-secret.yaml
    │       ├── httproute.yaml
    │       └── volsync.yaml
    ├── sonarr/
    │   ├── config.yaml
    │   └── resources/
    │       ├── external-secret.yaml
    │       ├── httproute.yaml
    │       └── volsync.yaml
    ├── radarr/
    │   ├── config.yaml
    │   └── resources/
    │       └── ...
    ... (10 more apps)
```

### Statistics
- **Total Application manifests**: 1 ApplicationSet (replaces 26 files!)
- **Lines of YAML**: ~1,500 lines (50% reduction)
- **Repetition**: Minimal - chart version in ONE place
- **Maintenance**: Update chart version in 1 place, applies to all 13 apps

### Example: media-apps.applicationset.yaml (Proposed)
```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: media-apps
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  goTemplate: true
  generators:
    - git:
        repoURL: https://github.com/operinko/homeops.git
        revision: main
        files:
          - path: "kubernetes/argocd/applications/media/apps/*/config.yaml"
  template:
    metadata:
      name: '{{.app.name}}'
      namespace: argocd
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: media
      sources:
        - repoURL: https://bjw-s-labs.github.io/helm-charts
          targetRevision: '{{.app.chartVersion | default "4.4.0"}}'  # ONE place!
          chart: app-template
          helm:
            valuesObject: '{{.app.values | toJson}}'
        - repoURL: https://github.com/operinko/homeops.git
          targetRevision: main
          path: 'kubernetes/argocd/applications/media/apps/{{.app.name}}/resources'
      destination:
        server: https://kubernetes.default.svc
        namespace: media
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=false
```

### Example: apps/sonarr/config.yaml (Proposed)
```yaml
app:
  name: sonarr
  # chartVersion: "4.4.0"  # Optional override, defaults to 4.4.0
  values:
    controllers:
      sonarr:
        # ... same 100+ lines of values as before ...
        # But now in a dedicated config file!
```

---

## Migration Benefits

### 1. Reduced Repetition
- **Before**: Chart version repeated 13 times
- **After**: Chart version in 1 place (or per-app override)

### 2. Easier Updates
- **Before**: Update `targetRevision: 4.4.0` → `4.5.0` in 13 files
- **After**: Update default in 1 place, all apps get new version

### 3. Better Organization
- **Before**: Flat structure with 26+ files
- **After**: Hierarchical structure, each app in own directory

### 4. Simpler Onboarding
- **Before**: Copy 2 files, update in multiple places
- **After**: Copy 1 directory, update config.yaml

### 5. Consistent Patterns
- **Before**: Easy to have inconsistencies across apps
- **After**: Template enforces consistency

---

## Migration Steps

### Step 1: Create ApplicationSet
1. Create `media-apps.applicationset.yaml`
2. Test with one app first (e.g., echo or test app)

### Step 2: Migrate One App
1. Create `apps/sonarr/` directory
2. Move values to `apps/sonarr/config.yaml`
3. Move resources to `apps/sonarr/resources/`
4. Commit and verify sync

### Step 3: Migrate Remaining Apps
1. Repeat for each app
2. Can do incrementally (ApplicationSet + old Applications can coexist)

### Step 4: Cleanup
1. Remove old Application manifests
2. Update kustomization.yaml
3. Commit final changes

---

## Rollback Plan

If ApplicationSet doesn't work as expected:

1. **Keep old files** during migration (don't delete immediately)
2. **Test with one app** before migrating all
3. **Revert git commit** if issues arise
4. **ArgoCD will sync back** to old state automatically

---

## Advanced: Per-App Overrides

Some apps might need different chart versions or special handling:

```yaml
# apps/special-app/config.yaml
app:
  name: special-app
  chartVersion: "4.3.0"  # Override default 4.4.0
  values:
    # ... app values ...
  ignoreDifferences:  # App-specific ignore rules
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
```

---

## Comparison Table

| Aspect | Before (Individual Apps) | After (ApplicationSet) |
|--------|-------------------------|------------------------|
| Files | 26 Application manifests | 1 ApplicationSet |
| Chart version updates | 13 places | 1 place |
| New app onboarding | Copy 2 files, edit both | Copy 1 directory, edit config |
| Consistency | Manual enforcement | Template enforced |
| Readability | Scattered across files | Organized by app |
| Git diff size | Large (multiple files) | Small (one config) |
| Maintenance burden | High | Low |

---

## Conclusion

The ApplicationSet approach provides:
- ✅ **50% reduction** in YAML files
- ✅ **90% reduction** in repetition
- ✅ **Easier maintenance** - update once, apply everywhere
- ✅ **Better organization** - clear structure
- ✅ **Faster onboarding** - simpler to add new apps

**Recommendation**: Start with media namespace as proof of concept, then expand to other namespaces.

