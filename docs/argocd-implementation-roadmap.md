# ArgoCD Improvements - Implementation Roadmap

This document provides a week-by-week implementation plan for all ArgoCD improvements.

---

## Week 1: Foundation & Quick Wins

### Day 1: Enable Notifications (15 minutes)
**Goal**: Get operational visibility

- [ ] Create Pushover secret in argocd namespace
- [ ] Update argocd.yaml to enable notifications
- [ ] Configure Pushover notifier
- [ ] Add subscriptions for sync-failed and health-degraded
- [ ] Test by triggering a sync failure
- [ ] Commit and push changes

**Files changed**: 1 (`kubernetes/argocd/applications/argocd/argocd.yaml`)

### Day 2: Standardize Sync Waves (2 hours)
**Goal**: Predictable deployment order

- [ ] Document current sync waves across all namespaces
- [ ] Define standard wave numbers (0-4)
- [ ] Update database namespace (wave 0-3)
- [ ] Update storage namespace (wave 0-2)
- [ ] Update network namespace (wave 0-4)
- [ ] Update observability namespace (wave 0-4)
- [ ] Update media namespace (wave 0-2)
- [ ] Update remaining namespaces
- [ ] Commit and push changes

**Files changed**: ~30 (all namespace Application manifests)

### Day 3: Add Orphaned Resources Monitoring (1 hour)
**Goal**: Detect configuration drift

- [ ] Update all 13 AppProject files
- [ ] Add orphanedResources.warn: true
- [ ] Add common ignore patterns (kube-root-ca.crt, helm releases)
- [ ] Commit and push changes
- [ ] Check ArgoCD UI for orphaned resources warnings

**Files changed**: 13 (`kubernetes/argocd/applications/projects/*.yaml`)

### Day 4: Add Custom Health Checks (1 hour)
**Goal**: Better status visibility

- [ ] Add Dragonfly health check to argocd.yaml
- [ ] Add CloudNative-PG health check
- [ ] Add VolSync ReplicationSource health check
- [ ] Add Traefik HTTPRoute health check
- [ ] Commit and push changes
- [ ] Verify health status in ArgoCD UI

**Files changed**: 1 (`kubernetes/argocd/applications/argocd/argocd.yaml`)

### Day 5: Documentation & Review
**Goal**: Document changes and verify

- [ ] Create README.md for each namespace directory
- [ ] Document sync wave strategy
- [ ] Document notification setup
- [ ] Review all changes from Week 1
- [ ] Test rollback procedure
- [ ] Commit documentation

**Files changed**: 13 (README files)

**Week 1 Total**: ~5 hours, ~60 files changed

---

## Week 2: Media ApplicationSet (Proof of Concept)

### Day 1: Planning & Preparation (2 hours)
**Goal**: Understand current structure

- [ ] Analyze all 13 media applications
- [ ] Identify common patterns
- [ ] Identify differences/exceptions
- [ ] Design ApplicationSet structure
- [ ] Create migration plan
- [ ] Document rollback strategy

### Day 2: Create ApplicationSet Template (2 hours)
**Goal**: Build the ApplicationSet

- [ ] Create `media-apps.applicationset.yaml`
- [ ] Configure Git Files generator
- [ ] Define template with sources (Helm + Git)
- [ ] Add sync policy and options
- [ ] Test template syntax
- [ ] Document template parameters

**Files created**: 1 (`kubernetes/argocd/applications/media/media-apps.applicationset.yaml`)

### Day 3: Migrate First App (Sonarr) (2 hours)
**Goal**: Prove the concept

- [ ] Create `apps/sonarr/` directory structure
- [ ] Create `apps/sonarr/config.yaml` with values
- [ ] Move resources to `apps/sonarr/resources/`
- [ ] Keep old sonarr.yaml temporarily (for rollback)
- [ ] Commit and push
- [ ] Verify ApplicationSet creates sonarr Application
- [ ] Verify sync works correctly
- [ ] Monitor for 24 hours

**Files created**: 4 (config.yaml + 3 resources)

### Day 4: Migrate 3 More Apps (3 hours)
**Goal**: Validate pattern

- [ ] Migrate radarr (similar to sonarr)
- [ ] Migrate bazarr (similar to sonarr)
- [ ] Migrate prowlarr (indexer, slightly different)
- [ ] Verify all 4 apps sync correctly
- [ ] Compare with old Applications
- [ ] Monitor for issues

**Files created**: 12 (3 apps × 4 files)

### Day 5: Migrate Remaining Apps (3 hours)
**Goal**: Complete migration

- [ ] Migrate remaining 9 apps
- [ ] Verify all 13 apps managed by ApplicationSet
- [ ] Remove old Application manifests
- [ ] Update kustomization.yaml
- [ ] Commit and push
- [ ] Monitor for 24 hours
- [ ] Document any issues/learnings

**Files removed**: 26 (old Application manifests)
**Files created**: 36 (9 apps × 4 files)

**Week 2 Total**: ~12 hours, ~80 files changed

---

## Week 3: Storage & Database ApplicationSets

### Day 1-2: Storage ApplicationSet (4 hours)
**Goal**: Simplify CSI driver management

- [ ] Analyze 3 CSI drivers (ceph-rbd, ceph-cephfs, nfs-csi)
- [ ] Create `storage-csi-drivers.applicationset.yaml`
- [ ] Use List generator with inline elements
- [ ] Migrate ceph-rbd
- [ ] Migrate ceph-cephfs
- [ ] Migrate nfs-csi
- [ ] Remove old Application manifests
- [ ] Update kustomization.yaml
- [ ] Verify and monitor

**Files changed**: ~10

### Day 3-4: Database ApplicationSet (4 hours)
**Goal**: Clearer operator management

- [ ] Analyze Dragonfly operator + cluster pattern
- [ ] Analyze CloudNative-PG operator + cluster pattern
- [ ] Create `database-operators.applicationset.yaml`
- [ ] Use Matrix generator (operators × types)
- [ ] Migrate Dragonfly operator
- [ ] Migrate Dragonfly cluster
- [ ] Migrate CNPG operator
- [ ] Migrate CNPG cluster
- [ ] Remove old Application manifests
- [ ] Verify and monitor

**Files changed**: ~15

### Day 5: Review & Documentation
**Goal**: Document ApplicationSet patterns

- [ ] Document ApplicationSet patterns used
- [ ] Create troubleshooting guide
- [ ] Update README files
- [ ] Review all ApplicationSets
- [ ] Performance check
- [ ] Commit documentation

**Week 3 Total**: ~10 hours, ~30 files changed

---

## Week 4: Polish & Production Readiness

### Day 1: ArgoCD Metrics Dashboard (3 hours)
**Goal**: Better observability

- [ ] Create Grafana dashboard for ArgoCD
- [ ] Add panels for sync status
- [ ] Add panels for sync duration
- [ ] Add panels for out-of-sync apps
- [ ] Add panels for failed syncs
- [ ] Add panels for resource health
- [ ] Import dashboard to Grafana
- [ ] Add to homepage

### Day 2: RBAC Hardening (2 hours)
**Goal**: Better security

- [ ] Review all AppProject sourceRepos
- [ ] Tighten wildcards where possible
- [ ] Review clusterResourceWhitelist
- [ ] Add specific CRDs instead of wildcards
- [ ] Test RBAC changes
- [ ] Document RBAC policies

### Day 3: Repository Structure Refinement (2 hours)
**Goal**: Cleaner organization

- [ ] Review overall structure
- [ ] Reorganize if needed
- [ ] Update documentation
- [ ] Ensure consistency
- [ ] Clean up archive directory

### Day 4: Resource Labels (2 hours)
**Goal**: Better tracking

- [ ] Define standard label schema
- [ ] Add labels to ApplicationSet templates
- [ ] Verify labels applied to resources
- [ ] Update monitoring to use labels
- [ ] Document label schema

### Day 5: Final Review & Documentation (2 hours)
**Goal**: Production ready

- [ ] Review all changes from 4 weeks
- [ ] Update all documentation
- [ ] Create runbook for common tasks
- [ ] Test disaster recovery
- [ ] Celebrate! 🎉

**Week 4 Total**: ~11 hours, ~40 files changed

---

## Summary

### Total Time Investment
- **Week 1**: 5 hours (Quick wins)
- **Week 2**: 12 hours (Media ApplicationSet)
- **Week 3**: 10 hours (Storage & Database ApplicationSets)
- **Week 4**: 11 hours (Polish)
- **Total**: ~38 hours over 4 weeks

### Total Impact
- **Files reduced**: ~60 → ~35 (42% reduction)
- **Repetition**: High → Low
- **Maintenance**: High → Low
- **Visibility**: None → High (notifications, metrics)
- **Reliability**: Medium → High (sync waves, health checks)

### Risk Mitigation
- All changes are GitOps-based (easy rollback)
- Incremental migration (one namespace at a time)
- Keep old files during migration
- Test each change before proceeding
- Monitor for 24 hours after major changes

---

## Checkpoints

### After Week 1
- ✅ Notifications working
- ✅ Sync waves standardized
- ✅ Orphaned resources monitored
- ✅ Health checks added
- ✅ Documentation updated

### After Week 2
- ✅ Media ApplicationSet working
- ✅ 13 apps managed by 1 ApplicationSet
- ✅ 26 files reduced to 1
- ✅ Pattern validated

### After Week 3
- ✅ Storage ApplicationSet working
- ✅ Database ApplicationSet working
- ✅ All major namespaces using ApplicationSets

### After Week 4
- ✅ Metrics dashboard created
- ✅ RBAC hardened
- ✅ Structure refined
- ✅ Production ready

---

## Success Metrics

Track these metrics throughout implementation:

1. **Sync success rate** - Should remain >95%
2. **Sync duration** - Should not increase significantly
3. **Out-of-sync applications** - Should decrease
4. **Failed syncs** - Should decrease with better health checks
5. **Time to deploy new app** - Should decrease significantly
6. **Time to update chart version** - Should decrease from hours to minutes

---

## Rollback Procedures

If anything goes wrong:

1. **Immediate rollback**: `git revert HEAD && git push`
2. **Partial rollback**: Revert specific commits
3. **Emergency**: Restore from backup (keep old files during migration)
4. **ArgoCD UI**: Force sync to previous state

---

## Next Steps

1. **Review this roadmap** with your team
2. **Adjust timeline** based on availability
3. **Start Week 1** when ready
4. **Track progress** using checkboxes
5. **Document learnings** as you go

Good luck! 🚀

