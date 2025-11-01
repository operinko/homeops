# ArgoCD Ingress: Quick Answer

## Your Question
> "Do we need to do changes to our current HTTPRoutes? It doesn't look like ArgoCD uses GatewayAPI, but prefers Ingress (and Traefik IngressRoute)"

## The Answer: NO CHANGES NEEDED ✅

**ArgoCD works perfectly with Gateway API (HTTPRoute).** You don't need to change anything. Use the same HTTPRoute pattern you use for all your other apps.

---

## Why HTTPRoute is Perfect for Your Setup

Your cluster uses:
- ✅ **Traefik** as ingress controller
- ✅ **Gateway API** with HTTPRoute
- ✅ **Authentik** for authentication
- ✅ **CrowdSec** for protection

**ArgoCD supports all of these.** No changes needed.

---

## What ArgoCD Actually Supports

ArgoCD can be exposed via:

| Method | Your Setup | Recommendation |
|--------|-----------|-----------------|
| **HTTPRoute (Gateway API)** | ✅ You use this | ⭐ **USE THIS** |
| **Kubernetes Ingress** | ❌ You don't use this | Not needed |
| **Traefik IngressRoute** | ❌ You don't use this | Not needed |

---

## Implementation: Copy Your Existing Pattern

Your apps use this pattern:

```yaml
# kubernetes/apps/tools/headlamp/app/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: headlamp
  labels:
    route.scope: external
spec:
  parentRefs:
    - name: gateway-public
      namespace: network
  hostnames: ["headlamp.vaderrp.com"]
  rules:
    - filters:
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: authentik-forward
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: crowdsec-bouncer
      backendRefs:
        - name: headlamp
          port: 80
```

**For ArgoCD, use the same pattern:**

```yaml
# kubernetes/argocd/argocd-server-httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
  labels:
    route.scope: internal
  annotations:
    external-dns.alpha.kubernetes.io/public: "false"
spec:
  parentRefs:
    - name: gateway-internal
      namespace: network
  hostnames: ["argocd.vaderrp.com"]
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
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: crowdsec-bouncer
      backendRefs:
        - name: argocd-server
          port: 443
```

**Key differences:**
- `port: 443` - ArgoCD runs on HTTPS (not 80)
- `gateway-internal` - Internal-only access (like Grafana)
- Traefik automatically uses HTTPS when port 443 is specified

---

## Why This Works

1. **Traefik supports Gateway API** - Your Traefik config has it enabled:
   ```yaml
   providers:
     kubernetesGateway:
       enabled: true
       controllerName: traefik.io/gateway-controller
   ```

2. **HTTPRoute is standard** - Works with any controller that supports Gateway API

3. **Middleware integration** - Authentik and CrowdSec work with HTTPRoute

4. **Consistent** - All your apps use the same pattern

---

## What About Ingress and IngressRoute?

### Kubernetes Ingress
- ✅ Standard Kubernetes API
- ❌ Less powerful than HTTPRoute
- ❌ Inconsistent with your setup
- ❌ Harder to apply middleware

### Traefik IngressRoute
- ✅ Traefik-native
- ❌ Not portable (Traefik-specific)
- ❌ Inconsistent with your setup
- ❌ Not standard Kubernetes API

**Recommendation**: Stick with HTTPRoute. It's what you're already using.

---

## Implementation Steps

### 1. Create HTTPRoute File
```bash
# kubernetes/argocd/argocd-server-httproute.yaml
# Copy the YAML above
```

### 2. Apply It
```bash
kubectl apply -f kubernetes/argocd/argocd-server-httproute.yaml
```

### 3. Verify
```bash
kubectl get httproute -n argocd
# Should show: argocd-server

kubectl describe httproute argocd-server -n argocd
# Should show: Accepted: True, Programmed: True
```

### 4. Test
```bash
curl -k https://argocd.vaderrp.com
# Should redirect to Authentik login
```

---

## Summary

✅ **No changes needed to your HTTPRoute pattern**
✅ **ArgoCD works perfectly with Gateway API**
✅ **Use the same pattern as your other apps**
✅ **Supports Authentik and CrowdSec**
✅ **Consistent and future-proof**

**Next Step**: When you install ArgoCD, create the HTTPRoute using the pattern above. It will work exactly like your other apps.

---

## Detailed Documentation

For more information:
- **ARGOCD_INGRESS_OPTIONS.md** - Detailed comparison of all options
- **ARGOCD_HTTPROUTE_IMPLEMENTATION.md** - Step-by-step implementation guide


