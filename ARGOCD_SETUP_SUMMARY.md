# ArgoCD Setup Summary

## Files Created

You now have three files in `kubernetes/argocd/`:

### 1. `argocd-server-httproute.yaml`
Exposes ArgoCD server via Gateway API (HTTPRoute) on the internal gateway.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: gateway-internal
      namespace: network
  hostnames:
    - argocd.vaderrp.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: authentik-forward
      backendRefs:
        - name: argocd-server
          port: 443
```

**Key Points:**
- Uses `gateway-internal` (192.168.7.4) for internal-only access
- Applies Authentik forward auth middleware
- Routes to ArgoCD server on port 443 (HTTPS)

### 2. `middleware-authentik-forward.yaml`
Authentik forward auth middleware for the argocd namespace.

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authentik-forward
  namespace: argocd
spec:
  plugin:
    authentik-forward:
      address: http://authentik-server.security.svc.cluster.local
      cacheDuration: "1m"
      skippedPaths:
        # Health checks, metrics, API endpoints, etc.
```

**Key Points:**
- Created in `argocd` namespace (local, not cross-namespace)
- Skips authentication for health checks, metrics, and ArgoCD API endpoints
- Points to Authentik server in security namespace

### 3. `referencegrant-middleware.yaml` (DELETED)
You deleted this file - no longer needed since middleware is now local to argocd namespace.

---

## Next Steps

### 1. Install ArgoCD
```bash
# Create namespace
kubectl create namespace argocd

# Install ArgoCD (using Helm or manifests)
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd
```

### 2. Apply the Middleware and HTTPRoute
```bash
# Apply middleware first
kubectl apply -f kubernetes/argocd/middleware-authentik-forward.yaml

# Apply HTTPRoute
kubectl apply -f kubernetes/argocd/argocd-server-httproute.yaml

# Verify both are created
kubectl get middleware -n argocd
kubectl get httproute -n argocd
```

### 3. Verify HTTPRoute is Accepted
```bash
kubectl describe httproute argocd-server -n argocd
# Should show: Accepted: True, Programmed: True
```

### 4. Test Access
```bash
# From internal network
curl -k https://argocd.vaderrp.com

# Should redirect to Authentik login
# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Client (internal network)                               │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
        ┌────────────────────────────┐
        │ Gateway (gateway-internal) │
        │ 192.168.7.4:443            │
        └────────────┬───────────────┘
                     │
                     ▼
        ┌────────────────────────────┐
        │ HTTPRoute (argocd-server)  │
        │ argocd.vaderrp.com         │
        └────────────┬───────────────┘
                     │
                     ▼
        ┌────────────────────────────┐
        │ Middleware (authentik-fwd) │
        │ Checks Authentik auth      │
        └────────────┬───────────────┘
                     │
                     ▼
        ┌────────────────────────────┐
        │ ArgoCD Server              │
        │ argocd-server:443          │
        └────────────────────────────┘
```

---

## Why This Approach

1. **Local Middleware** - Authentik middleware is in the argocd namespace, so no ReferenceGrant needed
2. **No CrowdSec** - You can add it later when needed
3. **Consistent Pattern** - Same HTTPRoute pattern as your other apps
4. **Authentik Protected** - All traffic goes through Authentik forward auth
5. **Internal Only** - Uses gateway-internal for internal-only access

---

## File Structure

```
kubernetes/
├── argocd/
│   ├── argocd-server-httproute.yaml      # HTTPRoute
│   ├── middleware-authentik-forward.yaml # Authentik middleware
│   └── kustomization.yaml                # (create if needed)
```

---

## Summary

✅ **HTTPRoute created for ArgoCD**
✅ **Authentik middleware created in argocd namespace**
✅ **No cross-namespace references needed**
✅ **No CrowdSec (can add later)**
✅ **Ready to apply to cluster**

**Next Step:** Apply the middleware and HTTPRoute files to your cluster.


