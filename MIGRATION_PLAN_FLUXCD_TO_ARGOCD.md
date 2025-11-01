# FluxCD to ArgoCD Migration Plan

## Executive Summary

This document outlines a comprehensive strategy to migrate your homeops cluster from FluxCD v2.7.3 to ArgoCD while preserving all VolSync backup functionality and ensuring zero data loss.

**Key Considerations:**
- Your cluster uses Kustomize with SOPS encryption (age-based)
- VolSync uses MutatingAdmissionPolicies for job mutation (jitter + NFS repository injection)
- Multiple storage backends: Ceph RBD (primary), NFS-CSI, and S3 (MinIO)
- Complex dependency chains between applications and storage components
- Critical services (Technitium DNS) require minimal downtime

---

## Current Architecture Analysis

### FluxCD Structure
```
kubernetes/flux/cluster/
├── gotk-sync.yaml          # GitRepository + root Kustomization
├── gotk-components.yaml    # Flux controllers
└── ks.yaml                 # cluster-meta & cluster-apps Kustomizations

kubernetes/apps/
├── flux-system/            # Flux operator & instance
├── storage/volsync/        # VolSync with mutators
├── network/                # Technitium, gateways, external-dns
├── media/                  # Sonarr, Radarr, etc. (VolSync-enabled)
├── database/               # CloudNative-PG, Dragonfly
└── [other namespaces]
```

### VolSync Mutators (Critical)
Two MutatingAdmissionPolicies in `kubernetes/apps/storage/volsync/app/mutatingadmissionpolicy.yaml`:

1. **volsync-mover-jitter**: Adds random sleep (0-90s) to VolSync source jobs
   - Prevents thundering herd during hourly backups
   - Targets: `volsync-src-*` jobs

2. **volsync-mover-nfs**: Injects NFS repository volume into VolSync jobs
   - Mounts TrueNAS NFS at `/repository` for backup staging
   - Server: `192.168.0.221:/mnt/Nakkiallas/Nodepool/Volsync`
   - Targets: All VolSync jobs without existing repository volume

**Critical**: These mutators MUST be preserved during migration.

---

## Migration Strategy

### Phase 1: Pre-Migration Analysis & Preparation

**Objectives:**
- Document all Flux resources and their dependencies
- Identify applications with VolSync enabled
- Plan ArgoCD ApplicationSet structure
- Prepare SOPS integration

**Tasks:**
1. Audit all Kustomizations and HelmReleases
   - Map dependency chains
   - Identify patch strategies
   - Document substitution patterns

2. Inventory VolSync-enabled applications
   - Current: technitium, huntarr, audiobookshelf, and others
   - Verify backup schedules and retention policies
   - Test restore procedures

3. Design ArgoCD structure
   - Use ApplicationSets for namespace-based deployments
   - Mirror Kustomize component structure
   - Plan plugin architecture for VolSync mutators

4. Prepare SOPS integration
   - Verify age key availability
   - Test SOPS decryption in ArgoCD context
   - Plan secret management strategy

**Estimated Duration:** 2-3 days

---

### Phase 2: ArgoCD Installation & Configuration

**Objectives:**
- Install ArgoCD in parallel with FluxCD
- Configure SOPS integration
- Set up initial ApplicationSets

**Tasks:**
1. Install ArgoCD
   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f argocd-install.yaml
   ```

2. Configure SOPS integration
   - Create ArgoCD SOPS plugin ConfigMap
   - Mount age key in argocd-repo-server
   - Test secret decryption

3. Create initial Git source
   - Add GitHub repository to ArgoCD
   - Configure branch tracking (main)
   - Set up webhook for auto-sync

4. Deploy infrastructure ApplicationSets
   - Start with storage layer (Ceph, snapshot-controller)
   - Deploy VolSync with mutators
   - Deploy system components (cert-manager, ingress-nginx)

**Estimated Duration:** 1-2 days

---

### Phase 3: VolSync Mutator Implementation in ArgoCD

**CRITICAL SECTION - Data Loss Prevention**

**Challenge:** ArgoCD doesn't have native Flux-style patches. Solutions:

**Option A: Direct Kubernetes Resources (Recommended)**
- Deploy MutatingAdmissionPolicies as standard Kubernetes manifests
- No ArgoCD-specific handling needed
- Mutators work at cluster level, independent of GitOps tool

**Option B: ArgoCD Plugins**
- Create custom plugin for VolSync resource generation
- More complex but allows dynamic configuration
- Useful if you need environment-specific mutations

**Recommended Approach: Option A**

1. Move mutators to standard manifests
   ```
   kubernetes/apps/storage/volsync/app/
   ├── helmrelease.yaml
   ├── mutatingadmissionpolicy.yaml  # Keep as-is
   ├── prometheusrule.yaml
   └── volsync-cronjob.yaml
   ```

2. Create ArgoCD Application
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
       path: kubernetes/apps/storage/volsync
     destination:
       server: https://kubernetes.default.svc
       namespace: storage
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
   ```

3. Verify mutators work
   - Create test VolSync job
   - Confirm jitter init container injected
   - Confirm NFS repository volume mounted

**Estimated Duration:** 1 day

---

### Phase 4: Gradual Application Migration

**Strategy:** Migrate in waves, starting with non-critical applications

**Wave 1: Storage & Infrastructure (Day 1)**
- Ceph CSI, snapshot-controller
- VolSync with mutators
- External-DNS

**Wave 2: System Components (Day 2)**
- Cert-manager, ingress-nginx
- Traefik, Cilium (if managed by Flux)
- Kyverno, descheduler

**Wave 3: Non-Critical Apps (Days 3-4)**
- Homepage, Atuin, Echo
- Audiobookshelf (has VolSync)
- Headlamp, other tools

**Wave 4: Media Stack (Days 5-6)**
- Sonarr, Radarr, Prowlarr
- Tautulli, Sabnzbd, Bazarr
- All with VolSync enabled

**Wave 5: Critical Services (Days 7-8)**
- Technitium DNS (requires careful coordination)
- Database (CloudNative-PG, Dragonfly)
- Authentik

**For each application:**
1. Create ArgoCD Application manifest
2. Deploy alongside Flux version
3. Verify both are in sync
4. Disable Flux Kustomization
5. Monitor ArgoCD for 24 hours
6. Delete Flux resources

**Estimated Duration:** 1 week

---

### Phase 5: Validation & Cutover

**Objectives:**
- Verify all applications running correctly
- Test VolSync backup/restore cycle
- Confirm no data loss

**Tasks:**
1. Application health checks
   - All pods running
   - All ingresses accessible
   - All services responding

2. VolSync validation
   - Trigger manual backup for each app
   - Verify backup completion
   - Test restore procedure on non-critical app
   - Verify data integrity

3. Monitoring & logging
   - Verify Prometheus scraping
   - Check Grafana dashboards
   - Review application logs

4. Final cutover
   - Disable all Flux Kustomizations
   - Verify ArgoCD is sole GitOps controller
   - Document any issues

**Estimated Duration:** 2-3 days

---

### Phase 6: FluxCD Decommissioning

**Tasks:**
1. Remove Flux resources
   ```bash
   kubectl delete namespace flux-system
   ```

2. Clean up Git repository
   - Remove `kubernetes/flux/` directory
   - Remove Flux-specific files
   - Commit changes

3. Archive documentation
   - Document lessons learned
   - Update runbooks for ArgoCD
   - Create ArgoCD troubleshooting guide

**Estimated Duration:** 1 day

---

## Risk Mitigation

### Data Loss Prevention
- **Backup before migration**: Full cluster backup via VolSync
- **Parallel running**: Run both Flux and ArgoCD for 1 week
- **Gradual cutover**: Migrate non-critical apps first
- **Mutator verification**: Test mutators before production apps

### Downtime Minimization
- **Technitium DNS**: Migrate last, coordinate with user
- **Database**: Use CloudNative-PG WAL archiving for safety
- **Media apps**: Can tolerate brief downtime

### Rollback Plan
- Keep Flux running for 2 weeks post-migration
- If critical issues: revert to Flux, investigate, retry
- Maintain Git history for easy rollback

---

## Timeline

| Phase | Duration | Start | End |
|-------|----------|-------|-----|
| Analysis & Prep | 2-3 days | Day 1 | Day 3 |
| ArgoCD Install | 1-2 days | Day 4 | Day 5 |
| VolSync Mutators | 1 day | Day 6 | Day 6 |
| App Migration | 1 week | Day 7 | Day 13 |
| Validation | 2-3 days | Day 14 | Day 16 |
| Decommission | 1 day | Day 17 | Day 17 |
| **Total** | **~3 weeks** | | |

---

## Next Steps

1. **Review this plan** with your team
2. **Prepare test environment** (optional but recommended)
3. **Schedule migration window** (recommend off-peak hours)
4. **Create ArgoCD manifests** based on current Flux structure
5. **Test SOPS integration** in ArgoCD
6. **Begin Phase 1** when ready

---

## Questions & Considerations

- Do you want to keep Flux running in parallel during migration?
- Should we test in a staging cluster first?
- Any applications that cannot tolerate downtime?
- Preferred ArgoCD sync strategy (auto vs manual)?
- Should we implement ArgoCD notifications/webhooks?


