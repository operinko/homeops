# ArgoCD Manifest Install - TLS Fix

## You Already Have

✅ ArgoCD installed via manifest:
```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

## What You Need to Add

You need to configure ArgoCD to use insecure mode internally and apply the HTTPRoute + middleware.

---

## Step 1: Configure ArgoCD for Insecure Mode

Edit the ArgoCD server deployment to add the `--insecure` flag:

```bash
kubectl patch deployment argocd-server -n argocd -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-server","args":["--insecure"]}]}}}}'
```

Or manually edit:

```bash
kubectl edit deployment argocd-server -n argocd
```

Find the `args:` section and add `--insecure`:

```yaml
containers:
  - name: argocd-server
    args:
      - /usr/local/bin/argocd-server
      - --insecure  # ← Add this line
```

### Also Configure Repo Server

```bash
kubectl patch deployment argocd-repo-server -n argocd -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-repo-server","args":["--insecure"]}]}}}}'
```

Or manually edit:

```bash
kubectl edit deployment argocd-repo-server -n argocd
```

Add `--insecure` to the args.

---

## Step 2: Configure ArgoCD ConfigMap

Edit the ArgoCD ConfigMap to set the public URL:

```bash
kubectl edit configmap argocd-cmd-params-cm -n argocd
```

Add these settings:

```yaml
data:
  server.insecure: "false"
  server.basehref: /
  server.rootpath: /
  server.disable.auth: "false"
  url: https://argocd.vaderrp.com
```

---

## Step 3: Apply Middleware and HTTPRoute

Apply the files you already have:

```bash
# Apply middleware
kubectl apply -f kubernetes/argocd/middleware-authentik-forward.yaml

# Apply HTTPRoute
kubectl apply -f kubernetes/argocd/argocd-server-httproute.yaml
```

---

## Step 4: Verify

```bash
# Check deployments restarted
kubectl get pods -n argocd

# Check HTTPRoute is accepted
kubectl describe httproute argocd-server -n argocd
# Should show: Accepted: True, Programmed: True

# Check logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server -f
```

---

## Step 5: Test Access

```bash
# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Access ArgoCD
curl -k https://argocd.vaderrp.com
# Should redirect to Authentik login
```

---

## Quick Commands

```bash
# 1. Add --insecure to server
kubectl patch deployment argocd-server -n argocd -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-server","args":["--insecure"]}]}}}}'

# 2. Add --insecure to repo-server
kubectl patch deployment argocd-repo-server -n argocd -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-repo-server","args":["--insecure"]}]}}}}'

# 3. Apply middleware and HTTPRoute
kubectl apply -f kubernetes/argocd/middleware-authentik-forward.yaml
kubectl apply -f kubernetes/argocd/argocd-server-httproute.yaml

# 4. Verify
kubectl get pods -n argocd
kubectl describe httproute argocd-server -n argocd
```

---

## Why This Works

1. **`--insecure` flag** - Disables TLS between Traefik and ArgoCD
2. **No certificate mismatch** - ArgoCD doesn't validate pod IP
3. **Gateway terminates TLS** - Uses `vaderrp-com-production-tls`
4. **Secure end-to-end** - Client to Gateway is HTTPS

---

## Summary

✅ **ArgoCD already installed**
✅ **Add --insecure flag to deployments**
✅ **Configure ConfigMap with public URL**
✅ **Apply middleware and HTTPRoute**
✅ **Test access**

**Next Step:** Run the patch commands above to add `--insecure` flag.


