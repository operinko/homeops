# Radarr PostgreSQL Migration Guide

## Overview
Migrating Radarr from SQLite to PostgreSQL to improve performance on networked storage (Ceph).

## Current Status: Phase 1 - Database Creation

### What We Just Did
1. ✅ Updated `external-secret.yaml` to pull PostgreSQL credentials from Bitwarden
2. ✅ Added init container to `values.yaml` to create databases

### Prerequisites - ACTION REQUIRED

Before deploying, you MUST update Bitwarden:

#### 1. Update Bitwarden Item `826f35db-baaa-41ce-b2ce-23e4e5874bc5` (radarr-secret)

Add these fields:
- **Username**: `radarr`
- **Password**: `<generate-strong-password>` (use Bitwarden generator)
- **Custom Field** `init_postgres_host`: `postgres17-rw.database.svc.cluster.local`

#### 2. Verify Bitwarden Item `c1b5bc1c-2635-4be4-9bfa-ad755db3daa0` (cloudnative-pg)

Ensure it has:
- **Username**: (CloudNative-PG superuser, likely `postgres`)
- **Password**: (CloudNative-PG superuser password)

### Deployment Steps

1. **Update Bitwarden** (see above)

2. **Commit changes to Git**:
   ```bash
   git add kubernetes/argocd/applications/media/apps/radarr/
   git commit -m "feat(radarr): add PostgreSQL database initialization"
   git push
   ```

3. **Wait for ArgoCD to sync** (or manually sync the radarr application)

4. **Verify databases were created**:
   ```bash
   # Check init container logs
   kubectl logs -n media -l app.kubernetes.io/name=radarr -c init-db
   
   # Should see:
   # ✓ Database initialization complete!
   #   - radarr-main: ready
   #   - radarr-logs: ready
   #   - User: radarr
   ```

5. **Verify databases in PostgreSQL**:
   ```bash
   kubectl exec -n database postgres17-1 -- psql -U postgres -c "\l" | grep radarr
   
   # Should show:
   # radarr-main
   # radarr-logs
   ```

### What Happens Now

- ✅ Init container creates two empty PostgreSQL databases
- ✅ Radarr user is created with access to both databases
- ⚠️ **Radarr continues using SQLite** (no config.xml changes yet)
- ⚠️ PostgreSQL databases remain empty

### Next Steps (Phase 2 - Migration)

After verifying Phase 1 works:

1. Suspend ArgoCD Application (in Git)
2. Scale Radarr to 0 replicas (in Git)
3. Manually edit config.xml to add PostgreSQL configuration
4. Scale to 1 to create schema
5. Scale to 0 again
6. Run pgloader migration job
7. Scale to 1 and verify
8. Resume ArgoCD sync

## Troubleshooting

### Init container fails with "connection refused"
- Check that postgres17 cluster is healthy: `kubectl get cluster -n database`
- Verify INIT_POSTGRES_HOST is correct in Bitwarden

### Init container fails with "authentication failed"
- Verify CloudNative-PG superuser credentials in Bitwarden item `c1b5bc1c-2635-4be4-9bfa-ad755db3daa0`
- Check the cloudnative-pg-secret: `kubectl get secret -n database cloudnative-pg-secret`

### Databases not created
- Check init container logs: `kubectl logs -n media <radarr-pod> -c init-db`
- Verify ExternalSecret synced: `kubectl get externalsecret -n media radarr-secret`
- Check secret contents: `kubectl get secret -n media radarr-secret -o yaml`

## Rollback

If something goes wrong, simply revert the Git commits:
```bash
git revert HEAD
git push
```

ArgoCD will remove the init container and Radarr will continue using SQLite.

