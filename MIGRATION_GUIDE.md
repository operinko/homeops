# Automated NFS-CSI Migration Guide

This guide provides automated scripts to migrate applications from democratic-csi to NFS-CSI storage, based on the successful manual migration pattern used for Sonarr, Radarr, SABnzbd, and Prowlarr.

## 📋 Overview

The migration process includes:
1. **Automated discovery** of applications using democratic-csi storage
2. **Backup creation** before migration
3. **Suspension** of applications and VolSync
4. **Kustomization updates** to use NFS-CSI components
5. **Data migration** via ReplicationDestination
6. **PVC recreation** with NFS-CSI storage class
7. **Application resumption** and health verification
8. **Rollback capability** if issues occur

## 🎯 Target Applications

### Media Namespace (5 remaining)
- `bazarr` (Subtitles)
- `recyclarr` (Quality profiles)
- `huntarr` (Hunting/monitoring)
- `spotarr` (Spotify integration)
- `wizarr` (User management)

### Other Namespaces (8 applications)
- `default/atuin` (Shell history)
- `security/vaultwarden` (Password manager)
- `database/dragonfly` (Redis alternative)
- `network/technitium` (DNS server)
- `tools/headlamp` (Kubernetes dashboard)
- `observability/gatus` (Status page)
- `observability/loki` (Log aggregation)
- `observability/prometheus-kube-prometheus-stack` (Monitoring)

## 🚀 Quick Start

### 1. Run Migration Script

```bash
# Make scripts executable (in WSL)
chmod +x migrate-to-nfs-csi.sh validate-migration.sh

# Test the script logic (optional)
./test-migration-script.sh

# Dry run first (recommended)
DRY_RUN=true ./migrate-to-nfs-csi.sh

# Run actual migration
./migrate-to-nfs-csi.sh

# Skip confirmations (for automation)
SKIP_CONFIRMATION=true ./migrate-to-nfs-csi.sh
```

### 2. Validate Results

```bash
# Check application health
./validate-migration.sh check

# Check storage usage
./validate-migration.sh storage

# Check VolSync status
./validate-migration.sh volsync

# Generate full report
./validate-migration.sh report

# Run all checks
./validate-migration.sh all
```

## 📁 Script Files

### `migrate-to-nfs-csi.sh`
Main migration script with features:
- ✅ Automatic application discovery
- ✅ Backup creation before migration
- ✅ Error handling and rollback capability
- ✅ Progress logging with timestamps
- ✅ Dry run mode for testing
- ✅ Interactive confirmations
- ✅ Git integration for kustomization updates

### `validate-migration.sh`
Validation script with features:
- ✅ Application health checks
- ✅ Storage class verification
- ✅ VolSync status monitoring
- ✅ Comprehensive reporting
- ✅ Multiple check modes

## 🔧 Configuration Options

### Environment Variables

```bash
# Enable dry run mode (no changes made)
export DRY_RUN=true

# Skip interactive confirmations
export SKIP_CONFIRMATION=true
```

### Script Behavior

The migration script will:
1. **Scan** for applications using democratic-csi storage
2. **Prompt** for confirmation before proceeding
3. **Create backups** in `./backups/` directory
4. **Process each application** sequentially
5. **Log everything** to timestamped log files
6. **Offer rollback** if errors occur

## 📊 Expected Results

### Before Migration
```
NAME                       STORAGE_CLASS            STATUS
bazarr                     democratic-volsync-nfs   Bound
recyclarr                  democratic-volsync-nfs   Bound
atuin                      democratic-volsync-nfs   Bound
vaultwarden                democratic-volsync-nfs   Bound
```

### After Migration
```
NAME                       STORAGE_CLASS            STATUS
bazarr                     nfs-csi                  Bound
recyclarr                  nfs-csi                  Bound
atuin                      nfs-csi                  Bound
vaultwarden                nfs-csi                  Bound
```

## 🛡️ Safety Features

### Automatic Backups
- **PVC definitions** saved before changes
- **VolSync resources** backed up
- **HelmRelease configurations** preserved
- **Timestamped backup directories**

### Error Handling
- **Rollback prompts** on failures
- **Resource restoration** from backups
- **Detailed error logging**
- **Graceful failure handling**

### Validation
- **Health checks** after migration
- **Storage class verification**
- **VolSync status monitoring**
- **Application responsiveness tests**

## 📝 Migration Process Details

### Step-by-Step Process

1. **Discovery Phase**
   ```bash
   # Scan for democratic-csi PVCs
   kubectl get pvc --all-namespaces | grep democratic
   ```

2. **Backup Phase**
   ```bash
   # Create timestamped backups
   mkdir -p backups/namespace-app-timestamp/
   kubectl get pvc,replicationsource,helmrelease -o yaml > backup/
   ```

3. **Suspension Phase**
   ```bash
   # Suspend Flux resources
   flux suspend helmrelease app -n namespace
   flux suspend source replicationsource app -n namespace
   ```

4. **Update Phase**
   ```bash
   # Update kustomization files
   sed -i 's/democratic-csi-nfs/csi-driver-nfs/g' ks.yaml
   sed -i 's|volsync$|volsync/nfs-csi|g' ks.yaml
   git commit && git push
   ```

5. **Migration Phase**
   ```bash
   # Create ReplicationDestination for data migration
   kubectl apply -f migration-destination.yaml
   # Wait for completion
   ```

6. **Recreation Phase**
   ```bash
   # Delete old PVCs and create new NFS-CSI ones
   kubectl delete pvc app -n namespace
   kubectl apply -f new-nfs-csi-pvc.yaml
   ```

7. **Resume Phase**
   ```bash
   # Resume Flux resources
   flux resume helmrelease app -n namespace
   flux resume source replicationsource app -n namespace
   ```

8. **Validation Phase**
   ```bash
   # Verify application health
   kubectl get pods -n namespace
   kubectl exec pod -- wget -q -O - http://localhost/ping
   ```

## 🔍 Troubleshooting

### Common Issues

1. **Stuck PVCs**
   ```bash
   # Force remove finalizers
   kubectl patch pvc pvc-name -n namespace --type merge -p '{"metadata":{"finalizers":[]}}'
   ```

2. **Failed Migration**
   ```bash
   # Check logs
   tail -f migration-*.log

   # Restore from backup
   kubectl apply -f backups/namespace-app-timestamp/
   ```

3. **Application Won't Start**
   ```bash
   # Check pod logs
   kubectl logs -n namespace pod-name

   # Check PVC status
   kubectl describe pvc app -n namespace
   ```

### Validation Commands

```bash
# Check all PVCs using democratic-csi
kubectl get pvc --all-namespaces | grep democratic

# Check all PVCs using nfs-csi
kubectl get pvc --all-namespaces | grep nfs-csi

# Check VolSync status
kubectl get replicationsource --all-namespaces

# Check application pods
kubectl get pods --all-namespaces | grep -E "(bazarr|recyclarr|atuin|vaultwarden)"
```

## 📈 Success Metrics

### Migration Success Indicators
- ✅ All PVCs using `nfs-csi` storage class
- ✅ All applications running and healthy
- ✅ VolSync backups working with NFS-CSI
- ✅ No democratic-csi PVCs remaining
- ✅ Application data integrity preserved

### Performance Expectations
- **Migration time**: ~5-10 minutes per application
- **Downtime**: ~2-5 minutes per application
- **Data integrity**: 100% preservation expected
- **Rollback time**: ~2-3 minutes if needed

## 🎉 Post-Migration

### Verification Steps
1. Run `./validate-migration.sh all`
2. Check application functionality manually
3. Verify backup schedules are working
4. Monitor for 24-48 hours

### Cleanup (Optional)
After confirming stability:
```bash
# Remove old democratic-csi resources
kubectl get pv | grep democratic-csi
# Manually clean up if needed

# Remove backup files (after verification)
rm -rf backups/
```

## 📞 Support

If issues occur:
1. Check the generated log files
2. Review backup directories
3. Use validation script for diagnostics
4. Rollback using backup files if needed

The scripts are based on the proven migration pattern used successfully for Sonarr, Radarr, SABnzbd, and Prowlarr! 🚀
