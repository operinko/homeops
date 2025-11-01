# FluxCD to ArgoCD Migration - Documentation Index

## 📋 Quick Navigation

This migration plan consists of 6 comprehensive documents. Start here to understand the full scope.

---

## 📄 Document Overview

### 1. **KEY_FINDINGS.md** ⭐ START HERE
**Purpose**: Executive summary of analysis and key insights
**Read Time**: 10 minutes
**Contains**:
- Critical findings about VolSync mutators
- Risk assessment
- Recommendations
- Timeline estimate

**Key Takeaway**: Migration is highly feasible with minimal risk to data integrity.

---

### 2. **MIGRATION_SUMMARY.md**
**Purpose**: High-level overview for decision makers
**Read Time**: 15 minutes
**Contains**:
- Current state analysis
- Feasibility assessment
- VolSync preservation strategy
- Data loss prevention layers
- Timeline & effort estimate

**Key Takeaway**: Well-organized cluster with robust backup strategy makes migration straightforward.

---

### 3. **MIGRATION_PLAN_FLUXCD_TO_ARGOCD.md**
**Purpose**: Detailed 6-phase migration strategy
**Read Time**: 30 minutes
**Contains**:
- Phase 1: Pre-Migration Analysis & Preparation
- Phase 2: ArgoCD Installation & Configuration
- Phase 3: VolSync Mutator Implementation
- Phase 4: Gradual Application Migration
- Phase 5: Validation & Cutover
- Phase 6: FluxCD Decommissioning
- Risk mitigation strategies
- Rollback plan

**Key Takeaway**: Structured approach to minimize risk and ensure data safety.

---

### 4. **VOLSYNC_MUTATOR_ARGOCD_GUIDE.md**
**Purpose**: Technical deep-dive on VolSync mutator preservation
**Read Time**: 25 minutes
**Contains**:
- Current mutator architecture
- Why they're critical
- Implementation steps
- SOPS integration
- Backup & restore verification
- Troubleshooting guide

**Key Takeaway**: Mutators are cluster-level resources that work identically under ArgoCD.

---

### 5. **VOLSYNC_COMPONENTS_IN_ARGOCD.md** ⭐ CRITICAL
**Purpose**: Detailed explanation of how VolSync components work in ArgoCD
**Read Time**: 20 minutes
**Contains**:
- Current Flux component approach
- How ArgoCD handles Kustomize components
- Variable substitution comparison (Flux vs ArgoCD)
- Recommended migration strategy
- Complete example for Sonarr
- Migration checklist for VolSync components

**Key Takeaway**: Your component-based approach is fully compatible with ArgoCD - no changes to component files needed.

---

### 6. **ARGOCD_VOLSYNC_IMPLEMENTATION.md** ⭐ IMPLEMENTATION GUIDE
**Purpose**: Step-by-step implementation guide for VolSync in ArgoCD
**Read Time**: 25 minutes (reference during implementation)
**Contains**:
- Step 1: Understand current variable usage
- Step 2: Update app kustomization files (with examples)
- Step 3: Create ArgoCD Applications
- Step 4: Verify variable substitution
- Step 5: Deploy via ArgoCD (manual or ApplicationSet)
- Step 6: Verify VolSync resources
- Step 7: Test backup/restore
- Troubleshooting guide

**Key Takeaway**: Practical implementation steps with concrete examples for each app.

---

### 7. **ARGOCD_MANIFESTS_EXAMPLES.md**
**Purpose**: Concrete YAML examples for implementation
**Read Time**: 20 minutes
**Contains**:
- Basic Application examples
- VolSync-enabled applications
- Helm releases with SOPS
- ApplicationSets for multiple apps
- Infrastructure layer examples
- SOPS plugin configuration
- Directory structure
- Migration script template

**Key Takeaway**: Ready-to-use manifests for quick implementation.

---

### 8. **ARGOCD_FLUX_COEXISTENCE.md** ⭐ CRITICAL FOR YOUR SITUATION
**Purpose**: Complete guide to running ArgoCD and Flux side-by-side
**Read Time**: 20 minutes
**Contains**:
- Why coexistence is safe (no conflicts)
- Your current Flux setup analysis
- Potential issues and how to avoid them
- Migration strategy with parallel running
- Monitoring during coexistence
- Best practices
- Troubleshooting guide

**Key Takeaway**: Running both on the same cluster is completely safe and standard practice.

### 9. **ARGOCD_FLUX_PARALLEL_MIGRATION.md** ⭐ WEEK-BY-WEEK PLAN
**Purpose**: Practical week-by-week migration plan for your cluster
**Read Time**: 25 minutes (reference during migration)
**Contains**:
- Week 1: Install ArgoCD (parallel with Flux)
- Week 2: Migrate non-critical apps
- Week 3: Migrate critical apps
- Week 4: Decommission Flux
- Daily and weekly monitoring checks
- Rollback plan

**Key Takeaway**: Concrete steps for your specific situation.

### 10. **ARGOCD_INGRESS_OPTIONS.md** ⭐ INGRESS STRATEGY
**Purpose**: Compare ingress options for ArgoCD (HTTPRoute vs Ingress vs IngressRoute)
**Read Time**: 15 minutes
**Contains**:
- Why HTTPRoute is recommended for your setup
- Comparison of all three options
- Implementation examples for each
- Middleware integration (Authentik, CrowdSec)
- Consistency with existing apps

**Key Takeaway**: Use HTTPRoute (Gateway API) - same pattern as your other apps.

### 11. **ARGOCD_HTTPROUTE_IMPLEMENTATION.md** ⭐ STEP-BY-STEP GUIDE
**Purpose**: Practical guide to expose ArgoCD via HTTPRoute
**Read Time**: 20 minutes (reference during setup)
**Contains**:
- Step-by-step HTTPRoute creation
- Traefik verification
- HTTPS configuration
- Authentik SSO setup
- Troubleshooting guide
- File structure

**Key Takeaway**: Follow these steps to expose ArgoCD exactly like your other apps.

### 12. **MIGRATION_CHECKLIST.md**
**Purpose**: Step-by-step checklist for execution
**Read Time**: 15 minutes (reference during migration)
**Contains**:
- Pre-migration phase checklist
- Installation phase checklist
- VolSync migration checklist
- Application migration checklist (5 waves)
- Validation phase checklist
- Cutover phase checklist
- Decommissioning phase checklist
- Rollback procedures

**Key Takeaway**: Use this during actual migration to track progress.

---

## 🎯 Reading Paths

### For Decision Makers (30 minutes)
1. KEY_FINDINGS.md
2. MIGRATION_SUMMARY.md
3. MIGRATION_PLAN_FLUXCD_TO_ARGOCD.md (skim phases)

### For Technical Leads (90 minutes)
1. KEY_FINDINGS.md
2. MIGRATION_PLAN_FLUXCD_TO_ARGOCD.md (full read)
3. VOLSYNC_COMPONENTS_IN_ARGOCD.md (critical for understanding components)
4. VOLSYNC_MUTATOR_ARGOCD_GUIDE.md
5. ARGOCD_MANIFESTS_EXAMPLES.md

### For Implementation Team (ongoing)
1. **ARGOCD_FLUX_COEXISTENCE.md** (understand why it's safe)
2. **ARGOCD_FLUX_PARALLEL_MIGRATION.md** (week-by-week plan)
3. **ARGOCD_INGRESS_OPTIONS.md** (HTTPRoute vs Ingress vs IngressRoute)
4. **ARGOCD_HTTPROUTE_IMPLEMENTATION.md** (step-by-step HTTPRoute setup)
5. VOLSYNC_COMPONENTS_IN_ARGOCD.md (understand component approach)
6. ARGOCD_VOLSYNC_IMPLEMENTATION.md (primary reference for VolSync apps)
7. MIGRATION_CHECKLIST.md (overall migration tracking)
8. ARGOCD_MANIFESTS_EXAMPLES.md (for code examples)
9. VOLSYNC_MUTATOR_ARGOCD_GUIDE.md (for troubleshooting)

---

## 🔑 Key Concepts

### VolSync Mutators
**What**: Kubernetes MutatingAdmissionPolicies that modify VolSync jobs
**Why**: Prevent backup thundering herd (jitter) and inject NFS staging (repository)
**Migration**: Work identically under ArgoCD - no changes needed

### Kustomize Components
**What**: Reusable Kustomize configurations for volsync, gatus, networking
**Why**: Modular, composable, reduces duplication
**Migration**: Fully supported by ArgoCD - no changes needed

### SOPS Secrets
**What**: Age-encrypted secrets stored in Git
**Why**: Secure, version-controlled, auditable
**Migration**: ArgoCD plugins support SOPS - straightforward integration

### Gradual Cutover
**What**: Migrate applications in waves, starting with non-critical
**Why**: Reduces risk, allows testing, enables rollback
**Migration**: 5 waves over 1 week, 24-hour monitoring between waves

---

## 📊 Migration Timeline

```
Week 1: Preparation (2-3 days)
├── Backup cluster
├── Audit Flux setup
├── Inventory VolSync apps
└── Prepare SOPS integration

Week 2: Installation (1-2 days)
├── Install ArgoCD
├── Configure SOPS
├── Add Git repository
└── Deploy infrastructure

Week 2-3: VolSync Setup (1 day)
├── Deploy VolSync
├── Verify mutators
└── Test backup/restore

Week 3-4: App Migration (1 week)
├── Wave 1: Storage & infrastructure
├── Wave 2: System components
├── Wave 3: Non-critical apps
├── Wave 4: Media stack
└── Wave 5: Critical services

Week 4-5: Validation (2-3 days)
├── Health checks
├── VolSync testing
├── Monitoring verification
└── Final cutover

Week 5: Cleanup (1 day)
├── Remove Flux
├── Clean Git repo
└── Archive documentation

Total: ~3 weeks
```

---

## ✅ Success Criteria

- [ ] All MutatingAdmissionPolicies present and active
- [ ] Jitter init container injected into VolSync jobs
- [ ] NFS repository volume mounted in VolSync jobs
- [ ] Backup jobs complete successfully
- [ ] Restore test passes with data integrity verified
- [ ] All VolSync-enabled apps running under ArgoCD
- [ ] No data loss during migration
- [ ] All applications synced and healthy
- [ ] Monitoring and logging working
- [ ] Rollback capability verified

---

## 🚨 Critical Reminders

1. **Backup before starting**: Full etcd backup + VolSync backups
2. **Test VolSync mutators**: Verify jitter and NFS injection
3. **Run parallel**: Keep Flux running for 1 week during migration
4. **Gradual cutover**: Migrate non-critical apps first
5. **Monitor closely**: Watch for issues during each wave
6. **Keep rollback ready**: Be prepared to revert if needed
7. **Document everything**: Update runbooks for ArgoCD

---

## 🆘 Troubleshooting Quick Links

**How do VolSync components work in ArgoCD?**
→ See VOLSYNC_COMPONENTS_IN_ARGOCD.md - Complete explanation

**Variables not substituted in VolSync resources?**
→ See ARGOCD_VOLSYNC_IMPLEMENTATION.md - Step 4: Verify Variable Substitution

**ReplicationSource not created?**
→ See ARGOCD_VOLSYNC_IMPLEMENTATION.md - Troubleshooting section

**VolSync mutators not injecting?**
→ See VOLSYNC_MUTATOR_ARGOCD_GUIDE.md - Troubleshooting section

**SOPS decryption failing?**
→ See ARGOCD_VOLSYNC_IMPLEMENTATION.md - Troubleshooting: SOPS Decryption Failing

**Application not syncing?**
→ See ARGOCD_MANIFESTS_EXAMPLES.md - Application examples

**Backup/restore issues?**
→ See VOLSYNC_MUTATOR_ARGOCD_GUIDE.md - Backup & Restore Verification

**Need to rollback?**
→ See MIGRATION_CHECKLIST.md - Rollback Plan section

---

## 📞 Questions?

Refer to the appropriate document:
- **"Is this feasible?"** → KEY_FINDINGS.md
- **"What's the plan?"** → MIGRATION_PLAN_FLUXCD_TO_ARGOCD.md
- **"How do I preserve VolSync?"** → VOLSYNC_MUTATOR_ARGOCD_GUIDE.md
- **"What do I need to do?"** → MIGRATION_CHECKLIST.md
- **"Show me examples"** → ARGOCD_MANIFESTS_EXAMPLES.md
- **"What could go wrong?"** → MIGRATION_SUMMARY.md - Risk Assessment

---

## 📝 Document Versions

- **Created**: 2025-11-01
- **Status**: Ready for implementation
- **Confidence Level**: 90%
- **Last Updated**: 2025-11-01

---

## 🎓 Learning Resources

### ArgoCD Documentation
- https://argo-cd.readthedocs.io/
- https://argo-cd.readthedocs.io/en/stable/user-guide/kustomize/

### VolSync Documentation
- https://backube.github.io/volsync/

### Kustomize Documentation
- https://kustomize.io/

### SOPS Documentation
- https://github.com/getsops/sops

---

## ✨ Next Steps

1. **Read KEY_FINDINGS.md** (10 minutes)
2. **Review MIGRATION_PLAN_FLUXCD_TO_ARGOCD.md** (30 minutes)
3. **Discuss with team** - timeline, resources, risks
4. **Schedule migration window** - off-peak hours recommended
5. **Begin Phase 1** - use MIGRATION_CHECKLIST.md
6. **Reference other docs** as needed during implementation

---

**Good luck with your migration! 🚀**


