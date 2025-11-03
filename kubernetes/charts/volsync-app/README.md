# VolSync App Chart

Reusable Helm chart for adding VolSync backup and restore capabilities to any application.

## Usage

Add this chart as a dependency in your application's `helmrelease.yaml` or include it directly in your kustomization.

### Example HelmRelease

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: myapp-volsync
spec:
  chart:
    spec:
      chart: volsync-app
      sourceRef:
        kind: HelmRepository
        name: homeops-charts
        namespace: flux-system
  values:
    appName: myapp
    capacity: 10Gi
    vaultwardenSecretId: cf4b996c-1bff-4d1a-b95d-9de3995ddc71
```

### Example Kustomization

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml

helmCharts:
  - name: volsync-app
    repo: https://github.com/operinko/homeops
    version: 1.0.0
    releaseName: myapp-volsync
    namespace: default
    valuesInline:
      appName: myapp
      capacity: 10Gi
      vaultwardenSecretId: cf4b996c-1bff-4d1a-b95d-9de3995ddc71
```

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `appName` | Application name (used for resource naming) | `""` |
| `capacity` | PVC capacity | `10Gi` |
| `storageClass` | Storage class for PVC and snapshots | `ceph-rbd` |
| `snapshotClass` | Volume snapshot class | `csi-rbd-snapclass` |
| `cacheCapacity` | Cache capacity for VolSync operations | `5Gi` |
| `vaultwardenSecretId` | Vaultwarden secret ID containing restic credentials | `""` |

## Vaultwarden Secret Setup

Create a secret in Vaultwarden with the following fields:

- `restic_repository`: Full S3 path with trailing slash (e.g., `s3:https://minio.vaderrp.com:9000/volsync/`)
- `restic_password`: Restic repository password
- `aws_access_key_id`: MinIO access key
- `aws_secret_access_key`: MinIO secret key
- `aws_default_region`: AWS region (e.g., `us-east-1`)

The app name will be automatically appended to the `restic_repository` path.

## Resources Created

- `PersistentVolumeClaim`: For application data
- `ReplicationSource`: Hourly backups to MinIO
- `ReplicationDestination`: Restore point for backups
- `ExternalSecret`: Pulls credentials from Vaultwarden

