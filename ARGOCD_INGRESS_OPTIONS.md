# ArgoCD Ingress Options: Gateway API vs Ingress vs IngressRoute

## Your Question
> "Do we need to do changes to our current HTTPRoutes? It doesn't look like ArgoCD uses GatewayAPI, but prefers Ingress (and Traefik IngressRoute)"

## Short Answer: You Have Options ✅

ArgoCD supports **all three approaches**:
1. **Gateway API (HTTPRoute)** - What you're using now ✅ Works great
2. **Kubernetes Ingress** - Standard approach
3. **Traefik IngressRoute** - Traefik-specific

**You don't need to change your HTTPRoutes.** ArgoCD works perfectly with Gateway API.

---

## Your Current Setup

Your cluster uses **Gateway API with Traefik**:

```yaml
# kubernetes/apps/tools/headlamp/app/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: headlamp
spec:
  parentRefs:
    - name: gateway-public
      namespace: network
  hostnames: ["headlamp.vaderrp.com"]
  rules:
    - backendRefs:
        - name: headlamp
          port: 80
```

**Traefik Configuration** (supports Gateway API):
```yaml
# kubernetes/apps/network/gateway/traefik/helmrelease.yaml
providers:
  kubernetesGateway:
    enabled: true
    controllerName: traefik.io/gateway-controller
```

---

## ArgoCD Ingress Options

### Option 1: Gateway API (HTTPRoute) ⭐ RECOMMENDED FOR YOUR SETUP

**Pros:**
- ✅ Consistent with your existing apps
- ✅ Uses same gateway infrastructure
- ✅ Supports Authentik and CrowdSec middleware
- ✅ Future-proof (standard Kubernetes API)
- ✅ No changes needed to your HTTPRoute pattern

**Cons:**
- Requires Traefik to support Gateway API (you have this)

**Implementation:**
```yaml
# kubernetes/argocd/argocd-server-httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
  labels:
    route.scope: internal
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

---

### Option 2: Kubernetes Ingress

**Pros:**
- ✅ Standard Kubernetes API
- ✅ Works with any ingress controller
- ✅ Simpler than Gateway API

**Cons:**
- ❌ Less powerful than Gateway API
- ❌ Inconsistent with your existing apps
- ❌ Harder to apply middleware (Authentik, CrowdSec)

**Implementation:**
```yaml
# kubernetes/argocd/argocd-server-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
    traefik.ingress.kubernetes.io/router.middlewares: network-authentik-forward@kubernetescrd,network-crowdsec-bouncer@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - argocd.vaderrp.com
      secretName: argocd-tls
  rules:
    - host: argocd.vaderrp.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
```

---

### Option 3: Traefik IngressRoute

**Pros:**
- ✅ Traefik-native, full feature support
- ✅ Easy middleware integration
- ✅ Powerful routing options

**Cons:**
- ❌ Traefik-specific (not portable)
- ❌ Inconsistent with your existing apps
- ❌ Not standard Kubernetes API

**Implementation:**
```yaml
# kubernetes/argocd/argocd-server-ingressroute.yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  entryPoints:
    - websecure
  hosts:
    - argocd.vaderrp.com
  tls:
    secretName: vaderrp-com-production-tls
  routes:
    - match: Host(`argocd.vaderrp.com`)
      kind: Rule
      middlewares:
        - name: authentik-forward
          namespace: network
        - name: crowdsec-bouncer
          namespace: network
      services:
        - name: argocd-server
          port: 443
          scheme: https
```

---

## Comparison Table

| Feature | HTTPRoute | Ingress | IngressRoute |
|---------|-----------|---------|--------------|
| **Standard API** | ✅ Yes | ✅ Yes | ❌ No |
| **Middleware Support** | ✅ Yes | ⚠️ Annotations | ✅ Yes |
| **Consistent with Your Setup** | ✅ Yes | ❌ No | ❌ No |
| **Future-Proof** | ✅ Yes | ✅ Yes | ❌ No |
| **Complexity** | Medium | Low | Medium |
| **Traefik Support** | ✅ Yes | ✅ Yes | ✅ Yes |

---

## Recommendation: Use HTTPRoute ⭐

**Use Gateway API (HTTPRoute) because:**

1. **Consistency** - All your apps use HTTPRoute
2. **Middleware** - Easy to apply Authentik and CrowdSec
3. **Future-proof** - Standard Kubernetes API
4. **No changes needed** - Your existing pattern works perfectly

---

## Implementation Steps

### Step 1: Create HTTPRoute for ArgoCD Server
```bash
# kubernetes/argocd/argocd-server-httproute.yaml
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
  labels:
    route.scope: internal
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
          scheme: HTTPS
EOF
```

### Step 2: Verify HTTPRoute Created
```bash
kubectl get httproute -n argocd
# Expected: argocd-server

kubectl describe httproute argocd-server -n argocd
# Should show: Accepted: True, Programmed: True
```

### Step 3: Test Access
```bash
# From internal network
curl -k https://argocd.vaderrp.com

# Should redirect to Authentik login
```

---

## Important Notes

### HTTPS/TLS
ArgoCD server runs on port 443 (HTTPS). Make sure:
```yaml
backendRefs:
  - name: argocd-server
    port: 443
    scheme: HTTPS  # ← Important!
```

### Authentik Integration
ArgoCD works with Authentik for SSO. The HTTPRoute middleware will:
1. Intercept requests to `argocd.vaderrp.com`
2. Forward to Authentik for authentication
3. Pass authenticated requests to ArgoCD

### CrowdSec Protection
The CrowdSec middleware will:
1. Check requests against CrowdSec rules
2. Block malicious traffic
3. Allow legitimate requests through

---

## Summary

✅ **No changes needed to your HTTPRoute pattern**
✅ **Use Gateway API (HTTPRoute) for ArgoCD**
✅ **Consistent with your existing apps**
✅ **Supports Authentik and CrowdSec**
✅ **Future-proof and standard**

**Next Step**: When you install ArgoCD, create the HTTPRoute using the pattern above. It will work exactly like your other apps.


