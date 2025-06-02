# CSI-Driver-NFS Migration Guide

## Phase 1: Preparation & Testing

### Prerequisites
1. Ensure your Kubernetes cluster is accessible
2. Verify FluxCD is operational
3. Confirm TrueNAS server (192.168.0.221) is accessible

### Step 1: Deploy CSI-Driver-NFS

The CSI-Driver-NFS configuration is already prepared. Deploy it:

```bash
# Commit the new configurations to git
git add kubernetes/apps/storage/csi-driver-nfs/
git commit -m "feat(storage): add csi-driver-nfs with snapshot support"
git push

# Wait for FluxCD to reconcile (or force reconcile)
flux reconcile source git flux-system
flux reconcile kustomization csi-driver-nfs -n flux-system
```

### Step 2: Verify CSI-Driver-NFS Deployment

```bash
# Check if CSI-Driver-NFS is deployed
kubectl get pods -n kube-system -l app=csi-nfs-controller
kubectl get pods -n kube-system -l app=csi-nfs-node

# Verify storage class is created
kubectl get storageclass nfs-csi

# Verify VolumeSnapshotClass is created
kubectl get volumesnapshotclass csi-nfs-snapclass
```

### Step 3: Test Basic Functionality

```bash
# Deploy test resources
kubectl apply -f test-csi-driver-nfs.yaml

# Check if PVC is bound
kubectl get pvc -n storage-test

# Check if pod is running and can write to the volume
kubectl logs test-nfs-pod -n storage-test
kubectl exec test-nfs-pod -n storage-test -- ls -la /data
kubectl exec test-nfs-pod -n storage-test -- cat /data/test.log
```

### Step 4: Test Volume Snapshots

```bash
# Create a test snapshot
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: test-snapshot
  namespace: storage-test
spec:
  volumeSnapshotClassName: csi-nfs-snapclass
  source:
    persistentVolumeClaimName: test-nfs-pvc
EOF

# Check snapshot status
kubectl get volumesnapshot -n storage-test
kubectl describe volumesnapshot test-snapshot -n storage-test
```

## Phase 2: VolSync Integration Testing

### Step 1: Test VolSync with CSI-Driver-NFS

Choose a non-critical application for testing. For example, if you have a test app:

```bash
# Create VolSync resources using the new templates
# Copy the app's existing volsync secret and update storage classes

# Example for a test application:
export APP=test-app
export NAMESPACE=storage-test

# Apply the new VolSync configuration
envsubst < kubernetes/components/volsync/nfs-csi/replicationsource.yaml | kubectl apply -f -

# Trigger a backup
kubectl patch replicationsource $APP -n $NAMESPACE --type=merge -p '{"spec":{"trigger":{"manual":"test-backup"}}}'

# Monitor backup progress
kubectl get replicationsource $APP -n $NAMESPACE -w
```

### Step 2: Test Restore Process

```bash
# Create a ReplicationDestination for restore testing
envsubst < kubernetes/components/volsync/nfs-csi/replicationdestination.yaml | kubectl apply -f -

# Trigger restore
kubectl patch replicationdestination ${APP}-dst -n $NAMESPACE --type=merge -p '{"spec":{"trigger":{"manual":"test-restore"}}}'

# Monitor restore progress
kubectl get replicationdestination ${APP}-dst -n $NAMESPACE -w
```

## Phase 3: Production Migration

### Migration Strategy

**IMPORTANT**: Migrate applications one by one, starting with least critical ones.

### Step 1: Prepare for Migration

```bash
# Ensure all current VolSync backups are up to date
kubectl get replicationsource --all-namespaces

# Document current PVCs and their storage classes
kubectl get pvc --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STORAGECLASS:.spec.storageClassName,SIZE:.spec.resources.requests.storage
```

### Step 2: Migrate Individual Applications

Use the migration script for each application:

```powershell
# Example: Migrate a media application
.\migrate-app-to-csi-driver-nfs.ps1 -Namespace media -App sonarr -DryRun

# If dry run looks good, execute the migration
.\migrate-app-to-csi-driver-nfs.ps1 -Namespace media -App sonarr
```

### Step 3: Update Application Configurations

For each migrated application, update its kustomization to use the new VolSync templates:

```yaml
# In the app's kustomization.yaml, change:
components:
  - ../../../components/volsync/local  # OLD

# To:
components:
  - ../../../components/volsync/nfs-csi  # NEW
```

### Step 4: Verify Each Migration

After each application migration:

```bash
# Check application is running
kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app>

# Verify PVC is using new storage class
kubectl get pvc <app> -n <namespace> -o yaml | grep storageClassName

# Test application functionality
# Access the application and verify data is intact

# Trigger a backup to test VolSync
kubectl patch replicationsource <app> -n <namespace> --type=merge -p '{"spec":{"trigger":{"manual":"post-migration-test"}}}'
```

## Phase 4: Cleanup

### Step 1: Remove Democratic-CSI (After All Apps Migrated)

```bash
# Suspend democratic-csi
flux suspend kustomization democratic-csi-nfs -n flux-system

# Remove from git
git rm -r kubernetes/apps/storage/democratic-csi/
git commit -m "feat(storage): remove democratic-csi after migration to csi-driver-nfs"
git push
```

### Step 2: Update Default Storage Classes

```bash
# Remove default annotation from democratic storage classes (if any remain)
kubectl patch storageclass democratic-csi-nfs -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

# Set nfs-csi as default if desired
kubectl patch storageclass nfs-csi -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### Step 3: Clean Up Test Resources

```bash
# Remove test namespace and resources
kubectl delete namespace storage-test
rm test-csi-driver-nfs.yaml
```

## Troubleshooting

### Common Issues

1. **PVC Stuck in Pending**: Check if NFS server is accessible and share exists
2. **Snapshot Creation Fails**: Verify VolumeSnapshotClass and snapshot controller are working
3. **VolSync Backup Fails**: Check storage class references in ReplicationSource

### Useful Commands

```bash
# Check CSI driver logs
kubectl logs -n kube-system -l app=csi-nfs-controller
kubectl logs -n kube-system -l app=csi-nfs-node

# Check storage class details
kubectl describe storageclass nfs-csi

# Check VolumeSnapshotClass
kubectl describe volumesnapshotclass csi-nfs-snapclass

# Monitor VolSync operations
kubectl get replicationsource --all-namespaces
kubectl get replicationdestination --all-namespaces
```

## Success Metrics

Track these metrics to measure migration success:

- **Volume Creation Success Rate**: Should be >99% (vs current ~85%)
- **Provisioning Time**: Should be <30 seconds consistently
- **VolSync Backup Success**: Maintain >95% success rate
- **Application Startup Time**: No degradation from baseline

## Rollback Plan

If issues occur during migration:

1. **Suspend problematic application**: `flux suspend kustomization <app>`
2. **Restore from backup**: Use existing democratic-csi VolSync backup
3. **Revert storage class**: Change back to democratic-csi storage classes
4. **Resume application**: `flux resume kustomization <app>`

The beauty of this migration is that both storage systems can coexist, allowing for safe rollback at any point.
