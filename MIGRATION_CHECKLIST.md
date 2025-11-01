# FluxCD to ArgoCD Migration Checklist

## Pre-Migration Phase

### Week 1: Planning & Preparation

- [ ] **Review migration plan** with team
- [ ] **Backup cluster state**
  - [ ] Full etcd backup
  - [ ] Trigger VolSync backups for all apps
  - [ ] Verify backup completion
  - [ ] Document backup locations

- [ ] **Audit current Flux setup**
  - [ ] List all Kustomizations: `flux get ks -A`
  - [ ] List all HelmReleases: `flux get hr -A`
  - [ ] Document dependency chains
  - [ ] Identify patch strategies used
  - [ ] Document substitution patterns

- [ ] **Inventory VolSync applications**
  - [ ] List all apps with VolSync components
  - [ ] Verify backup schedules
  - [ ] Test restore procedures
  - [ ] Document storage classes used

- [ ] **Prepare SOPS integration**
  - [ ] Verify age key availability
  - [ ] Export age key for ArgoCD
  - [ ] Test SOPS decryption locally
  - [ ] Document key management process

- [ ] **Design ArgoCD structure**
  - [ ] Plan Application/ApplicationSet layout
  - [ ] Map Kustomize components to ArgoCD
  - [ ] Design sync policies
  - [ ] Plan notification strategy

---

## Installation Phase

### Week 2: ArgoCD Setup

- [ ] **Install ArgoCD**
  - [ ] Create argocd namespace
  - [ ] Deploy ArgoCD manifests
  - [ ] Verify all pods running
  - [ ] Access ArgoCD UI (port-forward or ingress)

- [ ] **Configure SOPS integration**
  - [ ] Create sops-age Secret in argocd namespace
  - [ ] Mount age key in argocd-repo-server
  - [ ] Create SOPS plugin ConfigMap
  - [ ] Restart argocd-repo-server
  - [ ] Test secret decryption

- [ ] **Add Git repository**
  - [ ] Add GitHub repo to ArgoCD
  - [ ] Configure SSH or HTTPS auth
  - [ ] Set branch to main
  - [ ] Configure webhook (optional)
  - [ ] Test repository connection

- [ ] **Deploy infrastructure layer**
  - [ ] Create Application: snapshot-controller
  - [ ] Create Application: ceph-csi
  - [ ] Verify storage classes available
  - [ ] Test PVC creation

---

## VolSync Migration Phase

### Week 2-3: VolSync Mutators

- [ ] **Prepare VolSync manifests**
  - [ ] Verify mutatingadmissionpolicy.yaml format
  - [ ] Ensure no Flux-specific patches
  - [ ] Review CEL expressions
  - [ ] Document mutator behavior

- [ ] **Deploy VolSync via ArgoCD**
  - [ ] Create Application: volsync
  - [ ] Deploy VolSync Helm chart
  - [ ] Verify VolSync pods running
  - [ ] Check mutators deployed

- [ ] **Verify mutator functionality**
  - [ ] Check MutatingAdmissionPolicies exist
  - [ ] Create test VolSync job
  - [ ] Verify jitter init container injected
  - [ ] Verify NFS repository volume mounted
  - [ ] Delete test job

- [ ] **Test backup/restore cycle**
  - [ ] Trigger manual backup for test app
  - [ ] Monitor backup job completion
  - [ ] Verify backup in MinIO
  - [ ] Test restore procedure
  - [ ] Verify data integrity

---

## Application Migration Phase

### Week 3-4: Gradual Cutover

#### Wave 1: Storage & Infrastructure (Day 1)
- [ ] External-DNS
- [ ] Verify DNS records created

#### Wave 2: System Components (Day 2)
- [ ] Cert-manager
- [ ] Ingress-nginx
- [ ] Traefik
- [ ] Verify ingresses working

#### Wave 3: Non-Critical Apps (Days 3-4)
- [ ] Homepage
- [ ] Atuin
- [ ] Echo
- [ ] Audiobookshelf (with VolSync)
- [ ] Headlamp

#### Wave 4: Media Stack (Days 5-6)
- [ ] Sonarr
- [ ] Radarr
- [ ] Prowlarr
- [ ] Tautulli
- [ ] Sabnzbd
- [ ] Bazarr
- [ ] Huntarr (with VolSync)
- [ ] Verify all media apps syncing

#### Wave 5: Critical Services (Days 7-8)
- [ ] Database (CloudNative-PG)
- [ ] Dragonfly
- [ ] Authentik
- [ ] Technitium (coordinate downtime)

**For each application:**
- [ ] Create ArgoCD Application manifest
- [ ] Deploy alongside Flux version
- [ ] Verify both in sync
- [ ] Monitor for 24 hours
- [ ] Disable Flux Kustomization
- [ ] Monitor for 24 hours
- [ ] Delete Flux resources

---

## Validation Phase

### Week 4-5: Testing & Verification

- [ ] **Application health checks**
  - [ ] All pods running: `kubectl get pods -A`
  - [ ] All ingresses accessible
  - [ ] All services responding
  - [ ] Check application logs for errors

- [ ] **VolSync validation**
  - [ ] All ReplicationSources present
  - [ ] All ReplicationDestinations present
  - [ ] Trigger backup for each app
  - [ ] Verify backup completion
  - [ ] Test restore on non-critical app
  - [ ] Verify data integrity

- [ ] **Monitoring & logging**
  - [ ] Prometheus scraping targets
  - [ ] Grafana dashboards loading
  - [ ] Application logs accessible
  - [ ] No error spikes in logs

- [ ] **ArgoCD health**
  - [ ] All Applications synced
  - [ ] No sync errors
  - [ ] Webhook working (if configured)
  - [ ] Notifications working (if configured)

- [ ] **Performance testing**
  - [ ] Backup job duration normal
  - [ ] No resource spikes
  - [ ] Network throughput acceptable
  - [ ] Storage I/O normal

---

## Cutover Phase

### Week 5: Final Cutover

- [ ] **Disable all Flux Kustomizations**
  - [ ] Suspend cluster-meta
  - [ ] Suspend cluster-apps
  - [ ] Verify no Flux reconciliation

- [ ] **Verify ArgoCD is sole controller**
  - [ ] All Applications synced
  - [ ] No Flux resources active
  - [ ] All workloads running

- [ ] **Final backup**
  - [ ] Trigger full VolSync backup
  - [ ] Verify backup completion
  - [ ] Document backup location

- [ ] **Communicate status**
  - [ ] Notify team of cutover
  - [ ] Document any issues
  - [ ] Update runbooks

---

## Decommissioning Phase

### Week 5-6: Cleanup

- [ ] **Remove Flux components**
  - [ ] Delete flux-system namespace
  - [ ] Verify no Flux resources remain
  - [ ] Check for orphaned resources

- [ ] **Clean up Git repository**
  - [ ] Remove kubernetes/flux/ directory
  - [ ] Remove Flux-specific files
  - [ ] Update .gitignore
  - [ ] Commit changes
  - [ ] Push to main

- [ ] **Archive documentation**
  - [ ] Document lessons learned
  - [ ] Update runbooks for ArgoCD
  - [ ] Create ArgoCD troubleshooting guide
  - [ ] Archive Flux documentation

- [ ] **Final verification**
  - [ ] All applications running
  - [ ] All backups working
  - [ ] No errors in logs
  - [ ] Performance acceptable

---

## Rollback Plan

If critical issues occur:

- [ ] **Immediate actions**
  - [ ] Pause ArgoCD sync
  - [ ] Restore from backup
  - [ ] Investigate issue

- [ ] **Rollback procedure**
  - [ ] Re-enable Flux Kustomizations
  - [ ] Verify Flux reconciliation
  - [ ] Monitor for 24 hours
  - [ ] Document issue

- [ ] **Post-rollback**
  - [ ] Fix identified issues
  - [ ] Plan retry
  - [ ] Update migration plan

---

## Sign-Off

- [ ] **Technical review**: _______________  Date: _______
- [ ] **User acceptance**: _______________  Date: _______
- [ ] **Migration complete**: _______________  Date: _______

---

## Notes & Issues

```
[Document any issues, blockers, or lessons learned here]
```


