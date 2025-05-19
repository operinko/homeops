# VolSync Backup Configuration

This directory contains the configuration for VolSync, which is used to create backups of persistent volumes in the cluster.

## Overview

VolSync is used to create backups of important PVCs in the cluster. These backups are stored on the NFS server (using the nfs-csi storage class) and can be used to restore data in case of a cluster rebuild or disaster recovery scenario.

## How It Works

1. A PVC named `volsync-nfs-destination` is created using the `nfs-csi` storage class. This is where the actual backup data will be stored.
2. A ReplicationDestination named `nfs-destination` is created, which uses the `volsync-nfs-destination` PVC as its repository.
3. ReplicationSources in various namespaces reference this destination to store their backups.
4. Mayastor storage is used for temporary cache volumes during the backup process for better performance.

## Components

1. **ReplicationDestination**: Defines where backups are stored (NFS server)
2. **ReplicationSources**: Define which PVCs to back up and how often

## Configured Backups

The following applications have backup configurations:

- **Sonarr**: Daily backups of configuration and cache
- **Radarr**: Daily backups of configuration and cache
- **PostgreSQL**: Daily backups with pre/post hooks for database consistency

## Encryption

Backups can be encrypted using a secret. To enable encryption:

1. Generate a secure password
2. Create a secret using the template in `secret.sops.yaml.template`
3. Encrypt the secret using SOPS
4. Uncomment the `encryptionKeySecret` sections in the ReplicationSource configurations

## Restoring from Backup

To restore data from a backup:

1. Create a ReplicationDestination in the target namespace
2. Configure it to use the same repository as the original backup
3. Set the trigger to manual
4. Trigger the restore process

Example restore configuration:

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: sonarr-restore
  namespace: media
spec:
  trigger:
    manual: restore-trigger-1
  restic:
    repository: s3-repo
    copyMethod: Snapshot
    volumeSnapshotClassName: csi-democratic-snapshotclass
    storageClassName: freenas-api-iscsi
    accessModes:
      - ReadWriteOnce
    # If using encryption
    # encryptionKeySecret:
    #   name: volsync-restic-secret
    #   namespace: storage
```

## Adding New Backups

To add a new application to the backup schedule:

1. Create a ReplicationSource configuration in the application's directory
2. Update the application's kustomization.yaml to include the ReplicationSource
3. Configure the backup schedule and retention policy as needed

## Monitoring

Check the status of backups using:

```bash
kubectl get replicationsources -A
kubectl get replicationdestinations -A
```

For detailed information about a specific backup:

```bash
kubectl describe replicationsource <name> -n <namespace>
```
