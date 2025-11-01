# ArgoCD Cross-Namespace Middleware: ReferenceGrant Solution

## The Problem

When you tried to apply the HTTPRoute, you got this error:

```
middleware "argocd-authentik-forward@kubernetescrd" does not exist
```

This happened because:
1. The middleware (`authentik-forward`, `crowdsec-bouncer`) are defined in the `network` namespace
2. Your HTTPRoute is in the `argocd` namespace
3. By default, HTTPRoute can only reference resources in the same namespace

---

## The Solution: ReferenceGrant

**ReferenceGrant** is a Kubernetes Gateway API resource that allows secure cross-namespace references. It's like a permission slip that says: "HTTPRoutes in the `argocd` namespace are allowed to reference Middleware in the `network` namespace."

---

## Implementation

### Step 1: Create ReferenceGrant

Create `kubernetes/argocd/referencegrant-middleware.yaml`:

```yaml
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-argocd-middleware
  namespace: network  # ← Created in network namespace
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: argocd  # ← Allows HTTPRoutes from argocd namespace
  to:
    - group: traefik.io
      kind: Middleware
      name: authentik-forward  # ← To reference this middleware
    - group: traefik.io
      kind: Middleware
      name: crowdsec-bouncer  # ← And this middleware
```

**Key Points:**
- ReferenceGrant is created in the `network` namespace (where the middleware lives)
- It allows HTTPRoutes from the `argocd` namespace to reference the middleware
- It explicitly lists which middleware can be referenced

### Step 2: Update HTTPRoute

Your HTTPRoute references the middleware **without namespace prefix**:

```yaml
filters:
  - type: ExtensionRef
    extensionRef:
      group: traefik.io
      kind: Middleware
      name: authentik-forward  # ← No namespace field
  - type: ExtensionRef
    extensionRef:
      group: traefik.io
      kind: Middleware
      name: crowdsec-bouncer  # ← No namespace field
```

The ReferenceGrant allows Traefik to find these middleware in the `network` namespace.

### Step 3: Apply Both Resources

```bash
# Apply the ReferenceGrant first
kubectl apply -f kubernetes/argocd/referencegrant-middleware.yaml

# Then apply the HTTPRoute
kubectl apply -f kubernetes/argocd/argocd-server-httproute.yaml

# Verify both are created
kubectl get referencegrant -n network
kubectl get httproute -n argocd
```

---

## How Your Existing Apps Do This

Looking at your cluster, apps in the `media` namespace use the same pattern:

**ReferenceGrant in network namespace:**
```yaml
# kubernetes/apps/network/gateway/resources/referencegrant-forwardauth.yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-forwardauth-cross-namespace
  namespace: network
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: media  # ← Allows media namespace
  to:
    - group: traefik.io
      kind: Middleware
      name: authentik-forward
```

**HTTPRoute in media namespace:**
```yaml
# kubernetes/apps/media/huntarr/app/httproute.yaml
filters:
  - type: ExtensionRef
    extensionRef:
      group: traefik.io
      kind: Middleware
      name: authentik-forward  # ← References without namespace
```

---

## Why This Works

1. **ReferenceGrant is in the network namespace** - Where the middleware lives
2. **It explicitly allows argocd namespace** - To reference the middleware
3. **HTTPRoute references by name only** - Traefik uses the ReferenceGrant to find it
4. **Secure by default** - Without ReferenceGrant, cross-namespace references are blocked

---

## File Structure

```
kubernetes/
├── argocd/
│   ├── argocd-server-httproute.yaml      # HTTPRoute (references middleware)
│   ├── referencegrant-middleware.yaml    # ReferenceGrant (allows access)
│   └── kustomization.yaml
```

---

## Verification

```bash
# Check ReferenceGrant is created
kubectl get referencegrant -n network
# Expected: allow-argocd-middleware

# Check HTTPRoute is accepted
kubectl get httproute -n argocd
kubectl describe httproute argocd-server -n argocd
# Should show: Accepted: True, Programmed: True

# Check Traefik picked it up
kubectl logs -n network -l app.kubernetes.io/name=traefik | grep argocd

# Test access
curl -k https://argocd.vaderrp.com
# Should redirect to Authentik login
```

---

## Summary

✅ **ReferenceGrant allows cross-namespace middleware access**
✅ **Created in the network namespace (where middleware lives)**
✅ **Explicitly allows argocd namespace to reference middleware**
✅ **HTTPRoute references middleware by name only**
✅ **Same pattern as your existing media apps**

**Next Steps:**
1. Apply the ReferenceGrant
2. Apply the HTTPRoute
3. Verify both are created
4. Test access to https://argocd.vaderrp.com


