# Spotarr PostgreSQL Support (PR #100)

## Overview

This directory contains configuration to deploy Spotarr with PostgreSQL support from [PR #100](https://github.com/Spottarr/Spottarr/pull/100) before it's officially merged and released.

## Analysis Summary

**Good News:** Your current `postgres17` CNPG cluster is fully compatible! ✅

The PR uses PostgreSQL's **built-in** full-text search (`tsvector` type with GIN indexes), **NOT** the pgvector extension. No special extensions or cluster modifications needed.

### What the PR Uses:
- ✅ `tsvector` - Built-in PostgreSQL type (since PostgreSQL 8.3)
- ✅ GIN indexes - Standard PostgreSQL feature
- ✅ Integer arrays - Standard data types
- ✅ Standard PostgreSQL features only

## Deployment Steps

### 1. Build Custom Image

Run the GitHub Actions workflow to build the image from PR #100:

```bash
# Go to: https://github.com/operinko/homeops/actions/workflows/build-spotarr-pr.yaml
# Click "Run workflow"
# Use default tag: pr100-postgres
```

This builds from the `external-database` branch and publishes to `ghcr.io/operinko/spotarr:pr100-postgres`.

### 2. Add PostgreSQL Credentials to Bitwarden

Add a new custom field to your PostgreSQL Bitwarden secret (`0e9e9d3f-e4e8-4c8a-b8f8-c58c03f5246f`):

```
Field name: spotarr_connection_string
Value: Host=postgres17-rw.database.svc.cluster.local;Port=5432;Database=spotarr;Username=spotarr;Password=<spotarr-password>
```

### 3. Deploy with PostgreSQL Support

Replace the current Spotarr values and external-secret:

```bash
# Backup current config
cp kubernetes/argocd/applications/media/apps/spotarr/values.yaml kubernetes/argocd/applications/media/apps/spotarr/values-sqlite-backup.yaml
cp kubernetes/argocd/applications/media/apps/spotarr/external-secret.yaml kubernetes/argocd/applications/media/apps/spotarr/external-secret-sqlite-backup.yaml

# Deploy PR #100 version
cp kubernetes/argocd/applications/media/apps/spotarr/values-pr100.yaml kubernetes/argocd/applications/media/apps/spotarr/values.yaml
cp kubernetes/argocd/applications/media/apps/spotarr/external-secret-pr100.yaml kubernetes/argocd/applications/media/apps/spotarr/external-secret.yaml

# Commit and push
git add kubernetes/argocd/applications/media/apps/spotarr/
git commit -m "Deploy Spotarr PR #100 with PostgreSQL support"
git push
```

### 4. Monitor Deployment

```bash
# Watch pod startup
kubectl get pods -n media -l app.kubernetes.io/name=spotarr -w

# Check init container logs (database creation)
kubectl logs -n media -l app.kubernetes.io/name=spotarr -c init-db

# Check application logs
kubectl logs -n media -l app.kubernetes.io/name=spotarr -c app -f

# Verify database was created
kubectl exec -n database postgres17-1 -- psql -U postgres -c "\l spotarr"
```

### 5. Rollback (if needed)

```bash
# Restore SQLite version
cp kubernetes/argocd/applications/media/apps/spotarr/values-sqlite-backup.yaml kubernetes/argocd/applications/media/apps/spotarr/values.yaml
cp kubernetes/argocd/applications/media/apps/spotarr/external-secret-sqlite-backup.yaml kubernetes/argocd/applications/media/apps/spotarr/external-secret.yaml

git add kubernetes/argocd/applications/media/apps/spotarr/
git commit -m "Rollback Spotarr to SQLite"
git push
```

## Configuration Details

### Environment Variables

**PostgreSQL Mode:**
- `DATABASE__PROVIDER: Postgres` - Enables PostgreSQL support
- `DATABASE__CONNECTIONSTRING` - Full connection string from Bitwarden

**SQLite Mode (original):**
- No `DATABASE__PROVIDER` set (defaults to SQLite)
- Data stored in PVC at `/data`

### Database Schema

Single database: `spotarr`
- Uses PostgreSQL full-text search with Dutch language configuration
- Automatic migrations on startup
- No manual schema setup required

## Migration from SQLite

If you want to migrate existing data from SQLite to PostgreSQL, you'll need to:

1. Export data from SQLite
2. Transform to PostgreSQL format
3. Import to PostgreSQL

**Note:** Since Spotarr is not critical in your setup, starting fresh with PostgreSQL is recommended.

## When PR #100 is Merged

Once the PR is merged and an official release is published:

1. Update `values.yaml` to use official image:
   ```yaml
   image:
     repository: ghcr.io/spottarr/spottarr
     tag: <new-version>  # e.g., 1.11.0
   ```

2. Keep the PostgreSQL configuration (DATABASE__PROVIDER, etc.)

3. Remove the custom build workflow (`.github/workflows/build-spotarr-pr.yaml`)

## Files

- `values-pr100.yaml` - Helm values with PostgreSQL support and custom image
- `external-secret-pr100.yaml` - ExternalSecret with PostgreSQL credentials
- `values-sqlite-backup.yaml` - Backup of original SQLite configuration (after deployment)
- `external-secret-sqlite-backup.yaml` - Backup of original ExternalSecret (after deployment)

