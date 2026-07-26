# MinIO → Google Drive backup sync — design

Date: 2026-07-27
Status: approved (pending implementation)

## Purpose

Give the cluster's MinIO backup buckets an offsite 3-2-1 copy in Google Drive.
TrueNAS Cloud Sync cannot reach them (`/mnt/.ix-apps` is outside the pool
mountpoint), so a CronJob in the cluster syncs them over the S3 API instead.

## Scope

Buckets (explicit list, not auto-discovered):

```
cloudnative-pg  mariadb  kopia  volsync  parsedmarc  n8n  stalwart
```

`harbor` is excluded — it holds the mirror cache of public images plus
custom images/OCI artifacts, but the custom ones are built and pushed from
GitHub, so everything in it can be rebuilt. Empty buckets
(`loki`, `elasticsearch-snapshots`, `opensearch-snapshots`, `falco-forensics`)
are excluded deliberately: auto-discovery would silently start pushing
high-churn chunk data if e.g. Loki ever begins writing to its bucket.
Adding a bucket later is a one-line edit.

## Architecture

New app at `kubernetes/apps/storage/minio-gdrive-sync/` (standard ks.yaml +
`app/` layout, modeled on parsedmarc):

| File | Purpose |
|---|---|
| `ks.yaml` | Flux Kustomization |
| `app/cronjob.yaml` | CronJob, `rclone/rclone` image, daily 05:00, `concurrencyPolicy: Forbid` |
| `app/external-secret.yaml` | Pulls all secrets into one K8s Secret |
| `app/configmap.yaml` | Entrypoint script (see below) |
| `app/kustomization.yaml` | Wires the above |

Schedule rationale: TrueNAS Cloud Sync tasks run 00:00–03:00; nightly
VolSync/CNPG backups earlier. 05:00 syncs a quiet repo.

## Secrets (ExternalSecret, ClusterSecretStore `bitwarden-fields`)

| K8s key | Vaultwarden item | property |
|---|---|---|
| `ENCRYPTION_PASSWORD` | `980055b1-e67e-43b3-8634-87545f4cce16` | `encryption_password` |
| `ENCRYPTION_SALT` | `980055b1-e67e-43b3-8634-87545f4cce16` | `encryption_salt` |
| `GDRIVE_TOKEN` | `980055b1-e67e-43b3-8634-87545f4cce16` | `gdrive_token` |
| `MINIO_ACCESS_KEY` | `ed32aa71-d74b-43bc-a467-aaa2569f532f` | `aws-access-key-id` |
| `MINIO_SECRET_KEY` | `ed32aa71-d74b-43bc-a467-aaa2569f532f` | `aws-secret-access-key` |

`gdrive_token` is the full JSON printed by `rclone authorize "drive"`
(rclone's built-in OAuth client; no client id/secret of our own).
The MinIO key is the same `ncpg-access` key CNPG/MariaDB use (verified
identical in-cluster 2026-07-27).

## Entrypoint script

rclone crypt requires *obscured* passwords in config, so the script builds
`rclone.conf` at runtime:

1. `rclone obscure` on `ENCRYPTION_PASSWORD` and `ENCRYPTION_SALT`
2. Write config with three remotes:
   - `minio`: type s3, provider Minio, endpoint `https://minio.vaderrp.com:9000`
   - `gdrive`: type drive, `token = $GDRIVE_TOKEN`
   - `crypt`: wraps `gdrive:TrueNAS/MinIO`, `filename_encryption = off`,
     `directory_name_encryption = false` (matches the TrueNAS Cloud Sync
     task style — contents encrypted, names readable)
3. For each bucket: `rclone sync minio:<bucket> crypt:<bucket> --fast-list`
4. Exit non-zero if any bucket sync failed (so the Job shows Failed)

Deletion semantics: `sync` (mirror). Source buckets are self-pruning backup
repos (kopia/volsync maintenance, CNPG retention); `copy` would grow
unboundedly. Drive-side size ≈ live MinIO data (~172 GB currently).

## Error handling / visibility

- `failedJobsHistoryLimit: 3`, `restartPolicy: OnFailure` (bounded via `backoffLimit`)
- Existing kube-prometheus-stack failed-Job alerting covers notification;
  no custom alerts.

## Restore path

`rclone sync crypt:<bucket> minio:<bucket>` with the same config, or any
rclone with the crypt password+salt from Vaultwarden. Filenames are
plaintext in Drive; contents are unrecoverable without password+salt.

## Risks / open items

- **MinIO policy**: `ncpg-access` must have read+list on all seven buckets.
  Verify on first run; AccessDenied on non-DB buckets ⇒ widen policy or
  create a dedicated read-only key.
- Google Drive uploads cap at ~750 GB/day/account — initial ~172 GB plus the
  TrueNAS tasks fits, but the very first run may be slow.
- rclone refreshes the Drive access token in-memory only (config is from a
  Secret); the stored refresh token does not rotate, so this is fine.
