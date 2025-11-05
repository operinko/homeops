# ArgoCD Configuration Improvements Proposal

## Executive Summary

After analyzing your ArgoCD migration, I've identified several opportunities to improve both structure and functionality. The main focus is on leveraging **ApplicationSets** to reduce repetition and improve maintainability.

---

## Current State Analysis

### ✅ What's Working Well

1. **Clean namespace organization** - Applications logically grouped by namespace
2. **Sync wave ordering** - Proper dependency management (0=namespace, 1=resources, 2=apps)
3. **App-of-apps pattern** - Root application managing all child applications
4. **Project-based RBAC** - Each namespace has dedicated AppProject
5. **Consistent patterns** - Resources separated from applications
6. **Health checks** - Custom health check for Flux HelmRelease resources

### 📊 Current Statistics

- **Total Applications**: ~60+ individual Application manifests
- **Namespaces**: 13 (argocd, media, database, storage, observability, network, etc.)
- **ApplicationSets**: 0 (enabled but not used)
- **Repetitive patterns**: High (especially in media namespace with 13 similar apps)

---

## Proposed Improvements

### 1. 🎯 **ApplicationSets for Media Applications** (HIGH PRIORITY)

**Problem**: 13 media apps (sonarr, radarr, bazarr, prowlarr, etc.) have nearly identical structure:
- All use `bjw-s-labs.github.io/helm-charts/app-template:4.4.0`
- All follow same pattern: `{app}.yaml` + `{app}-resources.yaml`
- All use sync-wave "2"
- All belong to "media" project

**Solution**: Create ApplicationSet with Git Files generator

**Benefits**:
- Reduce ~26 files (13 apps × 2 files) to 1 ApplicationSet + 13 config files
- Easier to update chart version across all apps
- Consistent configuration patterns
- Simpler onboarding for new media apps

**Implementation**: Create `media-apps-applicationset.yaml`

### 2. 📦 **ApplicationSets for Storage CSI Drivers** (MEDIUM PRIORITY)

**Problem**: 3 CSI drivers (ceph-rbd, ceph-cephfs, nfs-csi) with similar patterns

**Solution**: ApplicationSet with List generator

**Benefits**:
- Centralized CSI driver management
- Easier version updates
- Consistent configuration

### 3. 🗄️ **ApplicationSets for Database Operators** (MEDIUM PRIORITY)

**Problem**: Multiple operator patterns (Dragonfly operator + cluster, CNPG operator + cluster)

**Solution**: ApplicationSet with Matrix generator (combining operators + instances)

**Benefits**:
- Clear operator → instance relationship
- Easier to add new database instances
- Consistent sync wave ordering

### 4. 🔔 **Enable ArgoCD Notifications** (MEDIUM PRIORITY)

**Current State**: `notifications.enabled: false`

**Recommendation**: Enable notifications with Pushover integration (you already use it for Alertmanager)

**Benefits**:
- Get notified on sync failures
- Track deployment status
- Integration with existing Pushover setup

**Configuration needed**:
```yaml
notifications:
  enabled: true
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
```

### 5. 📊 **Progressive Sync with Waves** (LOW PRIORITY)

**Current State**: Sync waves used but could be more granular

**Recommendation**: Standardize wave numbers across all namespaces:
- Wave 0: Namespaces
- Wave 1: Secrets, ConfigMaps, RBAC
- Wave 2: Operators, CRDs
- Wave 3: Operator instances (clusters, etc.)
- Wave 4: Applications depending on wave 3 services

**Benefits**:
- Predictable deployment order
- Easier troubleshooting
- Better dependency management

### 6. 🔐 **RBAC Improvements** (LOW PRIORITY)

**Current State**: Projects use wildcards in some places

**Recommendation**: Tighten RBAC where possible:
- Review `sourceRepos: ['*']` in database project
- Consider separate projects for operators vs instances
- Add `orphanedResources` configuration

### 7. 📁 **Repository Structure Optimization** (LOW PRIORITY)

**Current Pattern**:
```
kubernetes/argocd/applications/
  media/
    bazarr.yaml
    bazarr-resources.yaml
    bazarr/
      (resources)
```

**Proposed Pattern** (with ApplicationSets):
```
kubernetes/argocd/applications/
  media/
    media-apps.applicationset.yaml
    apps/
      bazarr/
        application.yaml
        resources/
          (resources)
```

**Benefits**:
- Clearer structure
- Easier to find app-specific configs
- Better separation of concerns

---

## Implementation Priority

### Phase 1: Quick Wins (Week 1)
1. ✅ Enable ArgoCD notifications
2. ✅ Standardize sync waves across all namespaces
3. ✅ Add orphanedResources configuration to projects

### Phase 2: ApplicationSets (Week 2-3)
1. 🎯 Media apps ApplicationSet (highest impact)
2. 📦 Storage CSI drivers ApplicationSet
3. 🗄️ Database operators ApplicationSet

### Phase 3: Structure Refinement (Week 4)
1. 📁 Reorganize repository structure
2. 🔐 Tighten RBAC policies
3. 📚 Documentation updates

---

## Detailed Implementation: Media ApplicationSet

### Example ApplicationSet Structure

**File**: `kubernetes/argocd/applications/media/media-apps.applicationset.yaml`

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: media-apps
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
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
      annotations:
        argocd.argoproj.io/sync-wave: "2"
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: media
      sources:
        # Helm chart
        - repoURL: https://bjw-s-labs.github.io/helm-charts
          targetRevision: '{{.app.chartVersion | default "4.4.0"}}'
          chart: app-template
          helm:
            valuesObject: '{{.app.values | toJson}}'
        # Resources from git
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

**Per-app config file**: `kubernetes/argocd/applications/media/apps/sonarr/config.yaml`

```yaml
app:
  name: sonarr
  chartVersion: "4.4.0"
  values:
    controllers:
      sonarr:
        annotations:
          reloader.stakater.com/auto: "true"
        containers:
          app:
            image:
              repository: ghcr.io/home-operations/sonarr-develop
              tag: 4.0.11.2680@sha256:...
            env:
              TZ: Europe/Helsinki
              SONARR__APP__INSTANCENAME: Sonarr
            # ... rest of values
```

---

## Additional Functional Improvements

### 8. 🔄 **Automated Image Updates** (OPTIONAL)

**Current State**: Image tags are hardcoded with SHA digests

**Recommendation**: Consider ArgoCD Image Updater for automated image updates

**Benefits**:
- Automatic updates for latest tags
- GitOps workflow maintained
- Reduced manual maintenance

**Trade-offs**:
- Adds complexity
- May want manual control for homelab

### 9. 🎛️ **Resource Tracking Labels** (LOW PRIORITY)

**Recommendation**: Add consistent labels to all resources:

```yaml
metadata:
  labels:
    app.kubernetes.io/name: sonarr
    app.kubernetes.io/instance: sonarr
    app.kubernetes.io/component: media
    app.kubernetes.io/managed-by: argocd
```

**Benefits**:
- Better resource tracking
- Easier querying with kubectl
- Improved observability

### 10. 🧪 **Sync Windows** (OPTIONAL)

**Use Case**: Prevent syncs during specific times (e.g., when watching media)

```yaml
spec:
  syncPolicy:
    syncOptions:
      - CreateNamespace=false
    syncWindows:
      - kind: allow
        schedule: '0 2-6 * * *'  # Only sync 2-6 AM
        duration: 4h
        applications:
          - media-*
```

---

## Metrics and Monitoring Improvements

### 11. 📈 **ArgoCD Metrics Dashboard**

**Recommendation**: Create Grafana dashboard for ArgoCD metrics

**Metrics to track**:
- Application sync status
- Sync duration
- Out-of-sync applications
- Failed syncs
- Resource health

**Implementation**: ArgoCD already exposes Prometheus metrics, just need dashboard

### 12. 🚨 **Health Check Improvements**

**Current State**: Custom health check for Flux HelmRelease

**Recommendation**: Add health checks for:
- Dragonfly clusters
- CloudNative-PG clusters
- VolSync ReplicationSource/Destination
- Traefik IngressRoute/HTTPRoute

**Example**:

```yaml
resource.customizations.health.dragonflydb.io_Dragonfly: |
  hs = {}
  if obj.status ~= nil then
    if obj.status.phase == "ready" then
      hs.status = "Healthy"
      return hs
    end
  end
  hs.status = "Progressing"
  return hs
```

---

## Security Improvements

### 13. ✅ **SOPS Cleanup** (COMPLETED)

**Status**: SOPS has been fully replaced with ExternalSecrets and SealedSecrets

**Completed Actions**:
- Migrated all secrets to ExternalSecrets (Bitwarden backend)
- Removed SOPS files from network namespace
- Removed unused VolSync components (mayastor, nfs-csi, s3, local)
- Migrated ceph-rbd VolSync to ExternalSecret
- Reorganized cluster-secrets to dedicated component directory
- Removed sops and sops-flux-only directories

**No further action needed** - SOPS is fully deprecated

### 14. 🛡️ **AppProject Security Hardening**

**Recommendations**:

1. **Limit cluster resources** where possible:
   ```yaml
   clusterResourceWhitelist:
     - group: ''
       kind: Namespace
     # Only allow specific CRDs, not all
   ```

2. **Add resource quotas** to projects:
   ```yaml
   namespaceResourceBlacklist:
     - group: ''
       kind: ResourceQuota
     - group: ''
       kind: LimitRange
   ```

3. **Enable orphaned resources monitoring**:
   ```yaml
   orphanedResources:
     warn: true
   ```

---

## Documentation Improvements

### 15. 📚 **Add README files**

**Recommendation**: Add README.md to each namespace directory explaining:
- Purpose of applications
- Dependencies
- Sync wave ordering
- Special considerations

**Example**: `kubernetes/argocd/applications/media/README.md`

```markdown
# Media Applications

## Overview
Media automation stack using *arr applications.

## Applications
- Sonarr: TV show management
- Radarr: Movie management
- Prowlarr: Indexer management
- ...

## Dependencies
- Database: PostgreSQL (192.168.7.30)
- Cache: Dragonfly (192.168.7.20)
- Storage: Ceph RBD (ceph-rbd StorageClass)

## Sync Waves
- Wave 0: Namespace
- Wave 1: Secrets, ConfigMaps, HTTPRoutes
- Wave 2: Applications
```

---

## Summary of Recommendations

### High Priority (Do First)
1. ✅ **Media ApplicationSet** - Biggest impact, reduces 26 files to 1
2. ✅ **Enable Notifications** - Immediate operational benefit
3. ✅ **Standardize Sync Waves** - Better reliability

### Medium Priority (Do Next)
4. 📦 **Storage ApplicationSet** - Good reduction in repetition
5. 🗄️ **Database ApplicationSet** - Clearer operator management
6. 📈 **ArgoCD Metrics Dashboard** - Better observability
7. 🚨 **Additional Health Checks** - Better status visibility

### Low Priority (Nice to Have)
8. 📁 **Repository Restructure** - Cleaner organization
9. 🔐 **RBAC Hardening** - Better security
10. 🎛️ **Resource Labels** - Better tracking
11. 📚 **Documentation** - Better maintainability

### Optional (Consider Later)
12. 🔄 **Image Updater** - Automation vs control trade-off
13. 🧪 **Sync Windows** - Only if needed
14. 🔒 **SOPS Plugin** - Current setup works fine

---

## Next Steps

1. **Review this proposal** and prioritize based on your needs
2. **Start with Phase 1** (quick wins) to get immediate benefits
3. **Implement Media ApplicationSet** as proof of concept
4. **Iterate and expand** to other namespaces
5. **Document patterns** for future applications

Would you like me to implement any of these improvements?


