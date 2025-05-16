## CloudNative PG

### Populate Secrets for new App

1. Create a secret for the app `secret.sops.yaml`, name it `${APP}-secret`.
2. Add any secrets required by the app normally.
3. Make sure to add `POSTGRES_PASSWORD` and `POSTGRES_USER` to the secret.
4. Create a new secret for the app `initdb-secret.sops.yaml`, name it `${APP}-initdb-secret`.
5. Add the following values to the secret:
   1. INIT_POSTGRES_DBNAME: ${APP}
   2. INIT_POSTGRES_HOST: ${CNPG_NAME:=postgres17}-rw.database.svc.cluster.local
   3. INIT_POSTGRES_USER (same as in secret.sops.yaml)
   4. INIT_POSTGRES_PASS (same as in secret.sops.yaml)
   5. INIT_POSTGRES_SUPER_PASS (from `cloudnative-pg-secret`)
