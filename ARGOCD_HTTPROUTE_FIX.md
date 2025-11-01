# ArgoCD HTTPRoute Fix: Removing Invalid `scheme` Field

## The Issue

When you tried to apply the HTTPRoute, you got this error:

```
.spec.rules[0].backendRefs[0].scheme: field not declared in schema
```

This happened because the `scheme` field is **not valid** in HTTPRoute `backendRefs`.

---

## The Root Cause

I made an error in the documentation. The HTTPRoute spec does not support a `scheme` field in `backendRefs`. This is a Kubernetes Gateway API limitation.

**What I incorrectly suggested:**
```yaml
backendRefs:
  - name: argocd-server
    port: 443
    scheme: HTTPS  # ❌ NOT VALID
```

---

## The Solution

**Remove the `scheme` field entirely.** Traefik automatically uses HTTPS when you specify `port: 443`.

**Correct HTTPRoute:**
```yaml
backendRefs:
  - name: argocd-server
    port: 443  # ✅ Traefik uses HTTPS automatically
```

---

## How Traefik Knows to Use HTTPS

Traefik uses the **port number** to determine the protocol:

| Port | Protocol | Traefik Behavior |
|------|----------|------------------|
| 80 | HTTP | Uses HTTP to backend |
| 443 | HTTPS | Uses HTTPS to backend |
| Other | Depends | Uses HTTP by default |

Since ArgoCD server runs on port 443, Traefik automatically uses HTTPS.

---

## Verification

Your HTTPRoute file at `kubernetes/argocd/argocd-server-httproute.yaml` is now correct:

```yaml
---
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

---

## Next Steps

1. **Apply the corrected HTTPRoute:**
   ```bash
   kubectl apply -f kubernetes/argocd/argocd-server-httproute.yaml
   ```

2. **Verify it's accepted:**
   ```bash
   kubectl get httproute -n argocd
   kubectl describe httproute argocd-server -n argocd
   # Should show: Accepted: True, Programmed: True
   ```

3. **Test access:**
   ```bash
   curl -k https://argocd.vaderrp.com
   # Should redirect to Authentik login
   ```

---

## Why This Works

Looking at your existing HTTPRoute resources (headlamp, grafana, etc.), **none of them use a `scheme` field**. They all just specify the port:

```yaml
# kubernetes/apps/tools/headlamp/app/httproute.yaml
backendRefs:
  - name: headlamp
    port: 80

# kubernetes/apps/observability/grafana/app/httproute.yaml
backendRefs:
  - name: grafana
    port: 80
```

Traefik handles the protocol selection automatically based on the port. This is the standard pattern in your cluster.

---

## Updated Documentation

I've updated all the documentation files to remove the invalid `scheme` field:

- ✅ `kubernetes/argocd/argocd-server-httproute.yaml` - Fixed
- ✅ `ARGOCD_INGRESS_QUICK_ANSWER.md` - Updated
- ✅ `ARGOCD_INGRESS_OPTIONS.md` - Updated
- ✅ `ARGOCD_HTTPROUTE_IMPLEMENTATION.md` - Updated

---

## Summary

✅ **The `scheme` field is not valid in HTTPRoute**
✅ **Traefik automatically uses HTTPS for port 443**
✅ **Your HTTPRoute file is now correct**
✅ **Ready to apply to your cluster**

Sorry for the confusion! The corrected file is ready to use.


